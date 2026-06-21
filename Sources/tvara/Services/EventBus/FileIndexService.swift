import Foundation
import SQLite3

private let SQLITE_TRANSIENT_FI = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Tiny SQLite-backed cache of file metadata populated by `FileIndexWorker`.
/// One row per absolute path; updates idempotently via INSERT OR REPLACE.
///
/// v1 keeps it intentionally minimal — basename, kind (extension), size,
/// mtime. Not yet wired into search; the legacy `mdfind` path remains
/// authoritative. This is the seed for future "recent files" / "files
/// added today" feeds.
actor FileIndexService {
    private let dbPath: String
    private var db: OpaquePointer?
    private var ready = false

    init(dbPath: String? = nil) {
        if let dbPath {
            self.dbPath = dbPath
        } else {
            let supportDir = NSHomeDirectory() + "/Library/Application Support/tvara"
            try? FileManager.default.createDirectory(
                atPath: supportDir, withIntermediateDirectories: true
            )
            self.dbPath = supportDir + "/files_recent.db"
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func ensureOpen() {
        if ready { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            dbPath, &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else { return }
        self.db = handle

        for s in [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            """
            CREATE TABLE IF NOT EXISTS files_recent (
                path     TEXT PRIMARY KEY,
                basename TEXT NOT NULL,
                kind     TEXT NOT NULL DEFAULT '',
                size     INTEGER NOT NULL DEFAULT 0,
                mtime    REAL NOT NULL DEFAULT 0,
                added_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_files_recent_added ON files_recent(added_at DESC)",
        ] { sqlite3_exec(handle, s, nil, nil, nil) }
        self.ready = true
    }

    /// Upsert one path. Returns false if the path doesn't exist (deleted
    /// between FSEvents firing and us touching it — common with downloads).
    @discardableResult
    func upsert(path: String) -> Bool {
        ensureOpen()
        guard let db else { return false }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let attrs else { return false }

        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let basename = (path as NSString).lastPathComponent
        let kind = (basename as NSString).pathExtension.lowercased()

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        INSERT INTO files_recent (path, basename, kind, size, mtime, added_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            basename = excluded.basename,
            kind = excluded.kind,
            size = excluded.size,
            mtime = excluded.mtime
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT_FI)
        sqlite3_bind_text(stmt, 2, basename, -1, SQLITE_TRANSIENT_FI)
        sqlite3_bind_text(stmt, 3, kind, -1, SQLITE_TRANSIENT_FI)
        sqlite3_bind_int64(stmt, 4, size)
        sqlite3_bind_double(stmt, 5, mtime)
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Total row count — used by tests.
    func count() -> Int {
        ensureOpen()
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db, "SELECT COUNT(*) FROM files_recent", -1, &stmt, nil
        ) == SQLITE_OK else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
