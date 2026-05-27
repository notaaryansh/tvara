import Foundation
import SQLite3

private let SQLITE_TRANSIENT_ML = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor AppleMailService {
    // MARK: - Configuration

    private let mailBase: String
    private let indexDbPath: String
    private var db: OpaquePointer?
    private var lastBuildCheck: Date?
    private var buildTask: Task<Void, Never>?
    private static let refreshLifetime: TimeInterval = 300   // re-scan at most every 5 min

    init() {
        // Both paths can exist on a single Mac:
        //   - ~/Library/Mail/V*           (legacy, used by Apple Mail
        //                                  outside its sandbox container —
        //                                  this is where data actually
        //                                  lives on most macOS 14 setups)
        //   - ~/Library/Containers/com.apple.mail/.../Mail  (sandbox husk,
        //                                  often present but empty)
        // We pick whichever has versioned subdirectories ("V10", "V11" …)
        // — those are the only ones that contain real mail data.
        let home = NSHomeDirectory()
        let candidates = [
            home + "/Library/Mail",
            home + "/Library/Containers/com.apple.mail/Data/Library/Mail",
        ]
        self.mailBase = candidates.first { path in
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                return false
            }
            return contents.contains { $0.hasPrefix("V") && $0.count <= 4 }
        } ?? candidates[0]

        let supportDir = home + "/Library/Application Support/spotlight++"
        try? FileManager.default.createDirectory(
            atPath: supportDir, withIntermediateDirectories: true
        )
        self.indexDbPath = supportDir + "/mail_index.db"
        self.db = Self.openAndPrepareSchema(path: indexDbPath)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    func isPermissionDenied() -> Bool {
        return !FileManager.default.isReadableFile(atPath: mailBase)
    }

    func warmCache() async {
        await refreshIfNeeded()
    }

    func search(query: String, limit: Int = 30) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        guard FileManager.default.fileExists(atPath: mailBase) else { return [] }

        await refreshIfNeeded()
        return queryFTS(query: trimmed, limit: limit)
    }

    // MARK: - FTS5 query

    private func queryFTS(query: String, limit: Int) -> [SearchResult] {
        // Build a safe FTS5 MATCH expression. Tokens are quoted to avoid
        // user input being interpreted as FTS5 operators (NEAR, AND, etc).
        // Each whitespace-separated word becomes a prefix-match term.
        let tokens = query
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { tok -> String in
                let safe = tok.replacingOccurrences(of: "\"", with: "")
                return "\"\(safe)\"*"
            }
        guard !tokens.isEmpty else { return [] }
        let matchExpr = tokens.joined(separator: " ")

        let sql = """
            SELECT message_id, subject, sender, body, date_received
            FROM mail_fts
            WHERE mail_fts MATCH ?
            ORDER BY rank
            LIMIT \(limit)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, matchExpr, -1, SQLITE_TRANSIENT_ML)

        var out: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId = colText(stmt, 0)
            let subject   = colText(stmt, 1)
            let sender    = colText(stmt, 2)
            let body      = colText(stmt, 3)
            let dateUnix  = sqlite3_column_int64(stmt, 4)

            guard !messageId.isEmpty else { continue }
            let date = dateUnix > 0
                ? Date(timeIntervalSince1970: TimeInterval(dateUnix))
                : nil

            // Choose snippet: if the body contains the matched text, prefer
            // a window around it; else fall back to subject + sender.
            let snippet = snippetFor(body: body, subject: subject, query: query)

            let encoded = "<\(messageId)>".addingPercentEncoding(
                withAllowedCharacters: .urlHostAllowed
            ) ?? messageId
            let openURL = "message://\(encoded)"

            // Sender display: parse "Name <addr@x>" → "Name" if name present
            let (displayName, addr) = parseSender(sender)

            out.append(SearchResult(
                title: subject.isEmpty ? "(no subject)" : subject,
                subtitle: snippet,
                source: .mail,
                date: date,
                badge: displayName.isEmpty ? addr : displayName,
                openTarget: .url(openURL),
                rank: 60   // FTS5 already ordered by relevance via rank
            ))
        }
        return out
    }

    private func snippetFor(body: String, subject: String, query: String) -> String {
        let q = query.lowercased()
        let bLower = body.lowercased()
        if let r = bLower.range(of: q) {
            let start = bLower.index(r.lowerBound, offsetBy: -60, limitedBy: bLower.startIndex)
                ?? bLower.startIndex
            let end = bLower.index(r.upperBound, offsetBy: 100, limitedBy: bLower.endIndex)
                ?? bLower.endIndex
            // Map back to the original-case body for display.
            let lowerStart = bLower.distance(from: bLower.startIndex, to: start)
            let lowerEnd   = bLower.distance(from: bLower.startIndex, to: end)
            let bStart = body.index(body.startIndex, offsetBy: lowerStart)
            let bEnd   = body.index(body.startIndex, offsetBy: lowerEnd)
            return "…\(body[bStart..<bEnd])…"
        }
        if !subject.isEmpty { return subject }
        if !body.isEmpty { return String(body.prefix(120)) }
        return ""
    }

    private func parseSender(_ s: String) -> (name: String, address: String) {
        // "Foo Bar <foo@bar.com>" → ("Foo Bar", "foo@bar.com")
        if let lt = s.firstIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let name = s[..<lt].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let addr = String(s[s.index(after: lt)..<gt])
            return (name, addr)
        }
        return ("", s)
    }

    // MARK: - Schema

    nonisolated private static func openAndPrepareSchema(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else { return nil }

        let stmts = [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            "PRAGMA temp_store=MEMORY",
            // FTS5 virtual table — `rank` column comes for free in FTS5.
            // We mark non-search columns UNINDEXED so they don't bloat the
            // FTS tokenization tables.
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS mail_fts USING fts5(
                message_id UNINDEXED,
                subject,
                sender,
                body,
                path UNINDEXED,
                date_received UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """,
            // Track file→message mapping so we can skip files we've already
            // ingested even when the FTS table contains them.
            """
            CREATE TABLE IF NOT EXISTS indexed_files (
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL
            )
            """
        ]
        for s in stmts { sqlite3_exec(db, s, nil, nil, nil) }
        return db
    }

    // MARK: - Refresh / build pipeline

    private func refreshIfNeeded() async {
        if let t = lastBuildCheck, Date().timeIntervalSince(t) < Self.refreshLifetime {
            return
        }
        if let existing = buildTask {
            await existing.value
            return
        }
        let task = Task { await self.runIncrementalBuild() }
        buildTask = task
        await task.value
        buildTask = nil
        lastBuildCheck = Date()
    }

    private func runIncrementalBuild() async {
        let alreadyIndexed = loadIndexedFiles()
        let mailBase = self.mailBase

        let parsed: [IndexedMailRow] = await Task.detached(priority: .userInitiated) {
            Self.walkEmlxFiles(under: mailBase, skip: alreadyIndexed)
        }.value

        guard !parsed.isEmpty else { return }
        ingestFTS(parsed)
    }

    /// Per-message ingest payload: parsed RFC822 fields plus filesystem
    /// metadata we need to track which files have been indexed.
    private struct IndexedMailRow: Sendable {
        let messageId: String
        let subject: String
        let from: String
        let body: String
        let date: Date?
        let path: String
        let mtime: Double
    }

    private func loadIndexedFiles() -> Set<String> {
        var out = Set<String>()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT path FROM indexed_files",
                                 -1, &stmt, nil) == SQLITE_OK else { return out }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = sqlite3_column_text(stmt, 0) {
                out.insert(String(cString: p))
            }
        }
        return out
    }

    private func ingestFTS(_ rows: [IndexedMailRow]) {
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        var ftsStmt: OpaquePointer?
        var idxStmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO mail_fts(message_id, subject, sender, body, path, date_received)
            VALUES(?,?,?,?,?,?)
        """, -1, &ftsStmt, nil)
        sqlite3_prepare_v2(db, """
            INSERT OR REPLACE INTO indexed_files(path, mtime) VALUES(?,?)
        """, -1, &idxStmt, nil)
        defer {
            sqlite3_finalize(ftsStmt)
            sqlite3_finalize(idxStmt)
        }

        for r in rows {
            sqlite3_bind_text(ftsStmt, 1, r.messageId, -1, SQLITE_TRANSIENT_ML)
            sqlite3_bind_text(ftsStmt, 2, r.subject,   -1, SQLITE_TRANSIENT_ML)
            sqlite3_bind_text(ftsStmt, 3, r.from,      -1, SQLITE_TRANSIENT_ML)
            sqlite3_bind_text(ftsStmt, 4, r.body,      -1, SQLITE_TRANSIENT_ML)
            sqlite3_bind_text(ftsStmt, 5, r.path,      -1, SQLITE_TRANSIENT_ML)
            sqlite3_bind_int64(ftsStmt, 6, Int64(r.date?.timeIntervalSince1970 ?? 0))
            sqlite3_step(ftsStmt); sqlite3_reset(ftsStmt)

            sqlite3_bind_text(idxStmt, 1, r.path, -1, SQLITE_TRANSIENT_ML)
            sqlite3_bind_double(idxStmt, 2, r.mtime)
            sqlite3_step(idxStmt); sqlite3_reset(idxStmt)
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - .emlx walker (heavy; runs detached)

    nonisolated private static func walkEmlxFiles(
        under base: String, skip: Set<String>
    ) -> [IndexedMailRow] {
        var out: [IndexedMailRow] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: base),
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "emlx" else { continue }
            let path = fileURL.path
            if skip.contains(path) { continue }

            let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true else { continue }

            guard let parsed = EmlxParser.parse(fileURL: fileURL) else { continue }

            out.append(IndexedMailRow(
                messageId: parsed.messageId,
                subject:   parsed.subject,
                from:      parsed.from,
                body:      parsed.body,
                date:      parsed.date,
                path:      path,
                mtime:     values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        return out
    }

    // MARK: - Helpers

    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: p)
    }
}
