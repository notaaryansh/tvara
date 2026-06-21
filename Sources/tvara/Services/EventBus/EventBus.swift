import Foundation
import SQLite3

private let SQLITE_TRANSIENT_EB = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent SQLite-backed event queue for the push-based indexing pipeline.
///
/// Producers call `enqueue(...)` when they detect new content. Workers call
/// `claim(type:limit:)` to atomically flip pending rows to processing; on
/// success they call `complete(id:)`, on failure `fail(id:error:)` (which
/// either schedules an exponential backoff retry or finalises as `failed`
/// once `attempts >= maxAttempts`).
///
/// Crash safety: any `processing` row whose `claimed_at` is older than
/// `staleClaimTimeout` is reverted to `pending` on lazy open. That covers
/// the "app died mid-index" case.
actor EventBus {

    /// After this many failed attempts an event is marked `failed` and
    /// stops being retried.
    static let maxAttempts = 5

    /// Rows stuck in `processing` longer than this are reverted to
    /// `pending` at startup.
    static let staleClaimTimeout: TimeInterval = 5 * 60

    private let dbPath: String
    private var db: OpaquePointer?
    private var ready = false

    /// Default path: `~/Library/Application Support/tvara/events.db`.
    /// Tests pass a temp file so they don't touch the user's real queue.
    init(dbPath: String? = nil) {
        if let dbPath {
            self.dbPath = dbPath
        } else {
            let supportDir = NSHomeDirectory() + "/Library/Application Support/tvara"
            try? FileManager.default.createDirectory(
                atPath: supportDir, withIntermediateDirectories: true
            )
            self.dbPath = supportDir + "/events.db"
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Lazy open + schema

    private func ensureOpen() {
        if ready { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            dbPath, &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            NSLog("EventBus: failed to open db at %@", dbPath)
            if handle != nil { sqlite3_close(handle) }
            return
        }

        let bootstrap: [String] = [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            """
            CREATE TABLE IF NOT EXISTS events (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                type        TEXT NOT NULL,
                source      TEXT NOT NULL,
                payload     TEXT NOT NULL,
                status      TEXT NOT NULL DEFAULT 'pending',
                attempts    INTEGER NOT NULL DEFAULT 0,
                error       TEXT,
                enqueued_at REAL NOT NULL,
                claimed_at  REAL,
                not_before  REAL NOT NULL DEFAULT 0,
                dedupe_key  TEXT UNIQUE
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_events_status_type ON events(status, type, not_before)",
        ]
        for s in bootstrap {
            if sqlite3_exec(handle, s, nil, nil, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(handle))
                NSLog("EventBus: bootstrap stmt failed: %@ (%@)", s, msg)
                sqlite3_close(handle)
                return
            }
        }

        self.db = handle
        recoverStaleClaims()
        self.ready = true
    }

    private func recoverStaleClaims() {
        guard let db else { return }
        let cutoff = Date().timeIntervalSince1970 - Self.staleClaimTimeout
        let sql = """
        UPDATE events
        SET status = 'pending', claimed_at = NULL
        WHERE status = 'processing' AND claimed_at < ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
    }

    // MARK: - Producer API

    /// Enqueue an event. Duplicate `dedupeKey`s are silently ignored — that's
    /// how producers stay idempotent without remembering what they pushed.
    /// Returns the new row id, `nil` if the insert was a dedupe no-op, or
    /// throws on a real persistence failure so producers can decline to
    /// advance their watermark.
    @discardableResult
    func enqueue(
        type: String,
        source: String,
        payload: String,
        dedupeKey: String? = nil
    ) throws -> Int64? {
        ensureOpen()
        guard let db else { throw EventBusError.notReady }

        let sql = """
        INSERT OR IGNORE INTO events (type, source, payload, enqueued_at, dedupe_key)
        VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventBusError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, type, -1, SQLITE_TRANSIENT_EB)
        sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT_EB)
        sqlite3_bind_text(stmt, 3, payload, -1, SQLITE_TRANSIENT_EB)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        if let key = dedupeKey {
            sqlite3_bind_text(stmt, 5, key, -1, SQLITE_TRANSIENT_EB)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventBusError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_changes(db) > 0 ? sqlite3_last_insert_rowid(db) : nil
    }

    // MARK: - Consumer API

    /// Atomically claim up to `limit` pending events of `type`. Skips events
    /// whose backoff window hasn't expired (`not_before > now`).
    func claim(type: String, limit: Int) -> [Event] {
        ensureOpen()
        guard let db, limit > 0 else { return [] }
        let now = Date().timeIntervalSince1970

        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

        let pick = """
        SELECT id, type, source, payload, attempts, enqueued_at
        FROM events
        WHERE status = 'pending' AND type = ? AND not_before <= ?
        ORDER BY id ASC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, pick, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, type, -1, SQLITE_TRANSIENT_EB)
        sqlite3_bind_double(stmt, 2, now)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var events: [Event] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            events.append(Event(
                id: sqlite3_column_int64(stmt, 0),
                type: String(cString: sqlite3_column_text(stmt, 1)),
                source: String(cString: sqlite3_column_text(stmt, 2)),
                payload: String(cString: sqlite3_column_text(stmt, 3)),
                attempts: Int(sqlite3_column_int(stmt, 4)),
                enqueuedAt: sqlite3_column_double(stmt, 5)
            ))
        }
        sqlite3_finalize(stmt)
        guard !events.isEmpty else { return [] }

        // Only return events whose UPDATE actually flipped status to
        // processing. A failed step here means the row wasn't claimed and
        // surfacing it would let two workers race the same id.
        let claim = "UPDATE events SET status='processing', claimed_at=? WHERE id=? AND status='pending'"
        var claimed: [Event] = []
        claimed.reserveCapacity(events.count)
        var cStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, claim, -1, &cStmt, nil) == SQLITE_OK {
            for e in events {
                sqlite3_bind_double(cStmt, 1, now)
                sqlite3_bind_int64(cStmt, 2, e.id)
                let step = sqlite3_step(cStmt)
                sqlite3_reset(cStmt)
                if step == SQLITE_DONE && sqlite3_changes(db) > 0 {
                    claimed.append(e)
                }
            }
            sqlite3_finalize(cStmt)
        }
        return claimed
    }

    /// Mark a claimed event done.
    func complete(id: Int64) {
        ensureOpen()
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db, "UPDATE events SET status='done' WHERE id=?", -1, &stmt, nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    /// Record a failed attempt. Below `maxAttempts` the event goes back to
    /// `pending` with an exponential backoff (`not_before = now + 2^attempts`,
    /// capped at 5 min). At or above `maxAttempts` it's finalised as `failed`.
    func fail(id: Int64, error: String) {
        ensureOpen()
        guard let db else { return }

        var attempts = 0
        var rs: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT attempts FROM events WHERE id=?", -1, &rs, nil) == SQLITE_OK {
            sqlite3_bind_int64(rs, 1, id)
            if sqlite3_step(rs) == SQLITE_ROW {
                attempts = Int(sqlite3_column_int(rs, 0))
            }
        }
        sqlite3_finalize(rs)

        let next = attempts + 1
        if next >= Self.maxAttempts {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(
                db,
                "UPDATE events SET status='failed', attempts=?, error=? WHERE id=?",
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(next))
            sqlite3_bind_text(stmt, 2, error, -1, SQLITE_TRANSIENT_EB)
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        } else {
            let delay = min(pow(2.0, Double(next)), 300.0)
            let notBefore = Date().timeIntervalSince1970 + delay
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(
                db,
                """
                UPDATE events
                SET status='pending', attempts=?, error=?, claimed_at=NULL, not_before=?
                WHERE id=?
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(next))
            sqlite3_bind_text(stmt, 2, error, -1, SQLITE_TRANSIENT_EB)
            sqlite3_bind_double(stmt, 3, notBefore)
            sqlite3_bind_int64(stmt, 4, id)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Observability

    /// Counts grouped by status. Used at startup to log queue depth.
    func depthByStatus() -> [String: Int] {
        ensureOpen()
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db, "SELECT status, COUNT(*) FROM events GROUP BY status", -1, &stmt, nil
        ) == SQLITE_OK else { return [:] }
        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = String(cString: sqlite3_column_text(stmt, 0))
            out[s] = Int(sqlite3_column_int(stmt, 1))
        }
        return out
    }

    /// Most recent failed events for debug surfacing.
    func recentFailures(limit: Int = 20) -> [Event] {
        ensureOpen()
        guard let db else { return [] }
        let sql = """
        SELECT id, type, source, payload, attempts, enqueued_at
        FROM events WHERE status='failed'
        ORDER BY id DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [Event] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Event(
                id: sqlite3_column_int64(stmt, 0),
                type: String(cString: sqlite3_column_text(stmt, 1)),
                source: String(cString: sqlite3_column_text(stmt, 2)),
                payload: String(cString: sqlite3_column_text(stmt, 3)),
                attempts: Int(sqlite3_column_int(stmt, 4)),
                enqueuedAt: sqlite3_column_double(stmt, 5)
            ))
        }
        return out
    }

    // MARK: - Test hooks

    /// Test-only: zeros `not_before` so the next claim doesn't wait for backoff.
    func _testClearBackoff() {
        ensureOpen()
        guard let db else { return }
        sqlite3_exec(db, "UPDATE events SET not_before=0 WHERE status='pending'", nil, nil, nil)
    }

    /// Test-only: how many times the row with this dedupe key has been
    /// failed. Used to wait for `bus.fail` to have actually run before
    /// the test clears backoff — checking status alone is racy because
    /// `pending` is also the initial state.
    func _testAttempts(dedupeKey: String) -> Int {
        ensureOpen()
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db, "SELECT attempts FROM events WHERE dedupe_key = ?",
            -1, &stmt, nil
        ) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, dedupeKey, -1, SQLITE_TRANSIENT_EB)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Test-only: subtract `seconds` from all `claimed_at` timestamps so
    /// the stale-claim recovery path can be exercised without sleeping.
    func _testAgeProcessingClaims(by seconds: TimeInterval) {
        ensureOpen()
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "UPDATE events SET claimed_at = claimed_at - ? WHERE status='processing'",
            -1, &stmt, nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, seconds)
        sqlite3_step(stmt)
    }
}

/// One row returned from `EventBus.claim`. Workers decode `payload` based
/// on `type`.
struct Event {
    let id: Int64
    let type: String
    let source: String
    let payload: String
    let attempts: Int
    let enqueuedAt: TimeInterval
}

enum EventBusError: Error, CustomStringConvertible {
    case notReady
    case sqlite(String)
    case encodeFailure

    var description: String {
        switch self {
        case .notReady:         return "EventBus: db not open"
        case .sqlite(let s):    return "EventBus sqlite: \(s)"
        case .encodeFailure:    return "EventBus: payload encode failed"
        }
    }
}
