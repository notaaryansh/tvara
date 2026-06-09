import Foundation
import SQLite3

private let SQLITE_TRANSIENT_HIST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One entry per stable result id. `count` is the running net of
/// "selected" (+1) minus "shown alongside a winner and not chosen" (-1),
/// clamped to [0, maxCount]. `lastSelectedAt` is unix epoch seconds.
struct SelectionHistoryEntry: Equatable {
    let count: Int
    let lastSelectedAt: Int64
}

/// SQLite-backed counter for the frequency reranker.
///
/// **Update semantics** (per `recordSelection`):
///   - The chosen result's count is incremented (capped at `maxCount`)
///     and its `last_selected_at` is set to now.
///   - The other `visibleIds` (excluding the chosen) have their counts
///     decremented (floored at 0). Only rows that already exist are
///     touched — never-clicked results stay absent rather than being
///     created at -1-floored-to-0 (saves storage; correctness identical).
///
/// **Identity**: caller passes pre-computed `stableId` strings derived
/// from `SearchResult.stableId`. Blacklisted source types never get a
/// non-nil stable id, so they never participate.
///
/// **Threading**: actor; SQLite calls are serialised through the actor's
/// executor. The DB handle is opened lazily on first call to a public
/// method so initialisation never throws and a missing support directory
/// degrades gracefully (recordSelection / lookup just become no-ops).
actor SelectionHistoryStore {

    /// Maximum count any single result can accumulate. Locked at 3 by
    /// design — see docs/reranker-plan.md for rationale.
    static let maxCount = 3

    private let dbPath: String
    private var db: OpaquePointer?
    private var ready = false

    /// Default path: `~/Library/Application Support/spotlight++/selection_history.db`.
    /// Tests pass a custom path (typically an `NSTemporaryDirectory` file)
    /// so they don't pollute the user's real history.
    init(dbPath: String? = nil) {
        if let dbPath {
            self.dbPath = dbPath
        } else {
            let home = NSHomeDirectory()
            let supportDir = home + "/Library/Application Support/spotlight++"
            try? FileManager.default.createDirectory(
                atPath: supportDir, withIntermediateDirectories: true
            )
            self.dbPath = supportDir + "/selection_history.db"
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Lazy open

    private func ensureOpen() {
        if ready { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            dbPath, &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil
        ) == SQLITE_OK else {
            NSLog("SelectionHistoryStore: failed to open db at %@", dbPath)
            return
        }
        self.db = handle
        let schema = """
        CREATE TABLE IF NOT EXISTS selection_history (
            stable_id        TEXT PRIMARY KEY,
            count            INTEGER NOT NULL DEFAULT 0,
            last_selected_at INTEGER NOT NULL DEFAULT 0
        );
        """
        sqlite3_exec(handle, schema, nil, nil, nil)
        self.ready = true
    }

    // MARK: - Write path

    /// Record one selection. `chosenId` gets +1 (capped at `maxCount`);
    /// every other id in `visibleIds` gets -1 (floored at 0). Empty /
    /// nil cases are no-ops.
    func recordSelection(chosenId: String, visibleIds: [String]) {
        guard !chosenId.isEmpty else { return }
        ensureOpen()
        guard let db else { return }
        let now = Int64(Date().timeIntervalSince1970)

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        // Chosen +1, cap at maxCount, update timestamp.
        let upsert = """
        INSERT INTO selection_history (stable_id, count, last_selected_at)
        VALUES (?, 1, ?)
        ON CONFLICT(stable_id) DO UPDATE SET
            count = MIN(\(Self.maxCount), count + 1),
            last_selected_at = excluded.last_selected_at
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, upsert, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, chosenId, -1, SQLITE_TRANSIENT_HIST)
            sqlite3_bind_int64(stmt, 2, now)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        // Penalize the rest of the visible set. Skip chosen, dedupe,
        // and only touch rows that already exist (no row → no penalty).
        let penalised = Array(Set(visibleIds).subtracting([chosenId]))
        if !penalised.isEmpty {
            let placeholders = Array(repeating: "?", count: penalised.count).joined(separator: ",")
            let penalty = """
            UPDATE selection_history
            SET count = MAX(0, count - 1)
            WHERE stable_id IN (\(placeholders))
            """
            var pStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, penalty, -1, &pStmt, nil) == SQLITE_OK {
                for (i, id) in penalised.enumerated() {
                    sqlite3_bind_text(pStmt, Int32(i + 1), id, -1, SQLITE_TRANSIENT_HIST)
                }
                sqlite3_step(pStmt)
            }
            sqlite3_finalize(pStmt)
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - Read path

    /// Bulk lookup for the candidate set of a single search. Returns a
    /// map keyed by stable id — ids without an entry are simply absent.
    /// Empty input returns an empty map without touching the DB.
    func lookup(_ ids: [String]) -> [String: SelectionHistoryEntry] {
        guard !ids.isEmpty else { return [:] }
        ensureOpen()
        guard let db else { return [:] }

        let unique = Array(Set(ids))
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let sql = """
        SELECT stable_id, count, last_selected_at
        FROM selection_history
        WHERE stable_id IN (\(placeholders))
        """
        var out: [String: SelectionHistoryEntry] = [:]
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        for (i, id) in unique.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), id, -1, SQLITE_TRANSIENT_HIST)
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            let ts = sqlite3_column_int64(stmt, 2)
            out[id] = SelectionHistoryEntry(count: count, lastSelectedAt: ts)
        }
        return out
    }

    // MARK: - Privacy escape

    /// Drops every row. Wired to the "Clear search history" menu item.
    func clear() {
        ensureOpen()
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM selection_history", nil, nil, nil)
    }
}
