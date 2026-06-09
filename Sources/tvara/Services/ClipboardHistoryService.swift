import AppKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT_CB = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Polls `NSPasteboard.general.changeCount` on a background task; persists
/// captured strings to SQLite. Privacy filters: skips entries the source
/// app marked with `org.nspasteboard.ConcealedType` (the convention used
/// by password managers like 1Password / Bitwarden / etc), and caps entry
/// size at 100KB. Deduplicates against the immediately previous entry.
///
/// tvara already runs persistently (it owns the global hotkey), so
/// the polling loop has the right lifetime — runs whether or not the
/// search panel is visible.
actor ClipboardHistoryService {
    private let dbPath: String
    private var db: OpaquePointer?
    private var lastChangeCount: Int = -1
    private var pollTask: Task<Void, Never>?
    private var lastContentHash: Int = 0

    private static let maxEntrySize = 100_000
    private static let maxEntries   = 1_000
    private static let pollInterval: TimeInterval = 0.5

    init() {
        let supportDir = NSHomeDirectory()
            + "/Library/Application Support/tvara"
        try? FileManager.default.createDirectory(
            atPath: supportDir, withIntermediateDirectories: true
        )
        self.dbPath = supportDir + "/clipboard.db"
        self.db = Self.openAndPrepareSchema(path: dbPath)
    }

    deinit {
        pollTask?.cancel()
        if let db { sqlite3_close(db) }
    }

    /// Starts the polling loop. Idempotent — calling twice is a no-op.
    func start() {
        guard pollTask == nil else { return }
        // Initialize so we don't immediately record whatever happened to
        // be on the pasteboard at launch.
        lastChangeCount = NSPasteboard.general.changeCount

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    private func tick() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        if cc == lastChangeCount { return }
        lastChangeCount = cc

        // Skip when the source app tagged the entry as a secret
        // (1Password, KeyChain Access, Bitwarden all use this).
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if pb.types?.contains(concealed) == true { return }

        guard let content = pb.string(forType: .string),
              !content.isEmpty,
              content.count <= Self.maxEntrySize else { return }

        // Dedupe vs the immediately-previous entry to avoid recording the
        // same paste twice when an app's UI bumps changeCount redundantly.
        let h = content.hashValue
        if h == lastContentHash { return }
        lastContentHash = h

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
            ?? "Unknown"
        insert(content: content, sourceApp: sourceApp)
    }

    // MARK: - Search

    func search(query: String, limit: Int = 25) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let sql = """
            SELECT content, source_app, copied_at
            FROM clipboard
            WHERE content LIKE ? COLLATE NOCASE
            ORDER BY copied_at DESC
            LIMIT \(limit)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(trimmed)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT_CB)

        let now = Date()
        var out: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let content = String(cString: sqlite3_column_text(stmt, 0))
            let app     = String(cString: sqlite3_column_text(stmt, 1))
            let ts      = sqlite3_column_int64(stmt, 2)
            let date = Date(timeIntervalSince1970: TimeInterval(ts))

            let snippet = collapse(content)
            // Recency-weighted rank: today's entries score highest.
            let minutes = max(0, now.timeIntervalSince(date) / 60)
            let rank = max(40, 200 - Int(minutes / 60))

            out.append(SearchResult(
                title: title(for: snippet),
                subtitle: "Copied from \(app)",
                source: .clipboard,
                date: date,
                badge: nil,
                openTarget: .copyToClipboard(content),
                rank: rank
            ))
        }
        return out
    }

    /// Recent entries with no query — useful as a "history feed" starter.
    func recent(limit: Int = 25) async -> [SearchResult] {
        let sql = """
            SELECT content, source_app, copied_at
            FROM clipboard
            ORDER BY copied_at DESC
            LIMIT \(limit)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let now = Date()
        var out: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let content = String(cString: sqlite3_column_text(stmt, 0))
            let app     = String(cString: sqlite3_column_text(stmt, 1))
            let ts      = sqlite3_column_int64(stmt, 2)
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let snippet = collapse(content)
            let minutes = max(0, now.timeIntervalSince(date) / 60)
            let rank = max(40, 200 - Int(minutes / 60))
            out.append(SearchResult(
                title: title(for: snippet),
                subtitle: "Copied from \(app)",
                source: .clipboard,
                date: date,
                badge: nil,
                openTarget: .copyToClipboard(content),
                rank: rank
            ))
        }
        return out
    }

    // MARK: - Persistence

    private func insert(content: String, sourceApp: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            INSERT INTO clipboard(content, source_app, copied_at)
            VALUES(?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, content, -1, SQLITE_TRANSIENT_CB)
        sqlite3_bind_text(stmt, 2, sourceApp, -1, SQLITE_TRANSIENT_CB)
        sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
        sqlite3_step(stmt)

        // Trim to maxEntries so the db doesn't grow without bound.
        let trim = """
            DELETE FROM clipboard WHERE id IN (
                SELECT id FROM clipboard ORDER BY copied_at DESC LIMIT -1 OFFSET \(Self.maxEntries)
            )
        """
        sqlite3_exec(db, trim, nil, nil, nil)
    }

    nonisolated private static func openAndPrepareSchema(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else { return nil }
        for s in [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            """
            CREATE TABLE IF NOT EXISTS clipboard (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                source_app TEXT NOT NULL DEFAULT '',
                copied_at INTEGER NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_clipboard_copied ON clipboard(copied_at DESC)"
        ] {
            sqlite3_exec(db, s, nil, nil, nil)
        }
        return db
    }

    // MARK: - Helpers

    private func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ⏎ ")
         .replacingOccurrences(of: "  ", with: " ")
    }

    private func title(for snippet: String) -> String {
        // Use the first ~80 chars as the row title; the full content goes
        // back to the clipboard when the user activates the entry.
        let trimmed = snippet.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(80)) + "…"
    }
}
