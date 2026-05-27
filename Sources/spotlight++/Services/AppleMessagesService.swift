import Foundation
import SQLite3

private let SQLITE_TRANSIENT_IM = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor AppleMessagesService {
    private let chatDbPath: String
    private let indexDbPath: String
    private var indexDb: OpaquePointer?
    private var lastBuildCheck: Date?
    private var buildTask: Task<Void, Never>?
    private static let refreshLifetime: TimeInterval = 60

    init() {
        self.chatDbPath = NSHomeDirectory() + "/Library/Messages/chat.db"

        let supportDir = NSHomeDirectory()
            + "/Library/Application Support/spotlight++"
        try? FileManager.default.createDirectory(
            atPath: supportDir, withIntermediateDirectories: true
        )
        self.indexDbPath = supportDir + "/imessage_index.db"
        self.indexDb = Self.openIndex(path: indexDbPath)
    }

    deinit {
        if let indexDb { sqlite3_close(indexDb) }
    }

    func isPermissionDenied() -> Bool {
        guard FileManager.default.fileExists(atPath: chatDbPath) else { return false }
        return !FileManager.default.isReadableFile(atPath: chatDbPath)
    }

    func warmCache() async {
        await refreshIfNeeded()
    }

    func search(query: String, limit: Int = 30) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        guard FileManager.default.fileExists(atPath: chatDbPath) else { return [] }

        await refreshIfNeeded()

        // chat.db has -wal/-shm siblings; copy all three.
        let tmpDb  = NSTemporaryDirectory() + "spotlight_imsg_\(UUID().uuidString).db"
        let tmpWal = tmpDb + "-wal"
        let tmpShm = tmpDb + "-shm"

        do {
            try FileManager.default.copyItem(atPath: chatDbPath, toPath: tmpDb)
        } catch {
            return []   // TCC denied
        }
        if FileManager.default.fileExists(atPath: chatDbPath + "-wal") {
            try? FileManager.default.copyItem(atPath: chatDbPath + "-wal", toPath: tmpWal)
        }
        if FileManager.default.fileExists(atPath: chatDbPath + "-shm") {
            try? FileManager.default.copyItem(atPath: chatDbPath + "-shm", toPath: tmpShm)
        }
        defer {
            try? FileManager.default.removeItem(atPath: tmpDb)
            try? FileManager.default.removeItem(atPath: tmpWal)
            try? FileManager.default.removeItem(atPath: tmpShm)
        }

        let contacts = queryContactCards(chatDbPath: tmpDb, query: trimmed)
        let messages = querySQL(chatDbPath: tmpDb, query: trimmed, limit: limit)
        return contacts + messages
    }

    /// Top-ranked "Open iMessage chat" cards for any chat whose display
    /// name or handle (email address) matches the needle. Phone-only
    /// contacts won't surface here because chat.db doesn't carry the
    /// contact's name — that lives in Contacts.app (separate TCC). When
    /// we wire that in, this method gets the name-resolved path too.
    private func queryContactCards(chatDbPath: String, query: String) -> [SearchResult] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        // For each distinct contact, pick the best display name + the most
        // recent message timestamp so we can show "x days ago" on the card.
        // We dedupe by handle so the same person doesn't appear twice
        // (once via display_name match, once via handle match).
        let sql = """
            SELECT
                h.id AS handle,
                COALESCE(NULLIF(c.display_name, ''), h.id) AS chat_name,
                c.chat_identifier,
                MAX(m.date) AS last_msg_date
            FROM chat c
            LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            LEFT JOIN handle h ON h.ROWID = chj.handle_id
            LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            LEFT JOIN message m ON m.ROWID = cmj.message_id
            WHERE h.id LIKE ? COLLATE NOCASE
               OR c.display_name LIKE ? COLLATE NOCASE
               OR c.chat_identifier LIKE ? COLLATE NOCASE
            GROUP BY h.id
            ORDER BY last_msg_date DESC
            LIMIT 6
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(query)%"
        for i in 1...3 {
            sqlite3_bind_text(stmt, Int32(i), pattern, -1, SQLITE_TRANSIENT_IM)
        }

        var out: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let handle   = colTextOptional(stmt, 0) ?? ""
            let chatName = colTextOptional(stmt, 1) ?? ""
            let chatId   = colTextOptional(stmt, 2) ?? ""
            let lastDate = sqlite3_column_int64(stmt, 3)

            // Skip chats we can't deep-link into (no usable handle/identifier).
            let openHandle = !handle.isEmpty ? handle
                : (chatId.starts(with: "chat") ? "" : chatId)
            guard !openHandle.isEmpty else { continue }

            let title = displayName(chatName: chatName, chatIdentifier: chatId, handle: handle)
            let date  = lastDate > 0 ? Self.appleDateToDate(lastDate) : nil

            out.append(SearchResult(
                title: title,
                subtitle: "Open iMessage chat",
                source: .imessage,
                date: date,
                badge: nil,
                openTarget: .imessageChat(handle: openHandle, messageText: ""),
                rank: 1_000
            ))
        }
        return out
    }

    // MARK: - Refresh / build decoded-text cache

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
        let lastId = readLastMessageId()
        let chatPath = chatDbPath
        let dbCopyPath = NSTemporaryDirectory()
            + "spotlight_imsg_build_\(UUID().uuidString).db"

        // Copy chat.db for safe reading
        do {
            try FileManager.default.copyItem(atPath: chatPath, toPath: dbCopyPath)
        } catch {
            return
        }
        if FileManager.default.fileExists(atPath: chatPath + "-wal") {
            try? FileManager.default.copyItem(atPath: chatPath + "-wal", toPath: dbCopyPath + "-wal")
        }
        defer {
            try? FileManager.default.removeItem(atPath: dbCopyPath)
            try? FileManager.default.removeItem(atPath: dbCopyPath + "-wal")
            try? FileManager.default.removeItem(atPath: dbCopyPath + "-shm")
        }

        let rows = await Task.detached(priority: .userInitiated) {
            Self.collectAttributedBodyRows(dbPath: dbCopyPath, sinceId: lastId)
        }.value

        guard !rows.isEmpty else { return }
        ingest(rows)
    }

    private func ingest(_ rows: [DecodedRow]) {
        sqlite3_exec(indexDb, "BEGIN TRANSACTION", nil, nil, nil)

        var stmt: OpaquePointer?
        sqlite3_prepare_v2(indexDb,
            "INSERT OR REPLACE INTO decoded_text(message_id, text) VALUES(?,?)",
            -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }

        var maxId: Int64 = 0
        for r in rows {
            sqlite3_bind_int64(stmt, 1, r.messageId)
            sqlite3_bind_text(stmt, 2, r.text, -1, SQLITE_TRANSIENT_IM)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
            if r.messageId > maxId { maxId = r.messageId }
        }

        sqlite3_exec(indexDb, "COMMIT", nil, nil, nil)
        writeLastMessageId(maxId)
    }

    private func readLastMessageId() -> Int64 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(indexDb,
            "SELECT value FROM metadata WHERE key='last_message_id'",
            -1, &stmt, nil) == SQLITE_OK else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let p = sqlite3_column_text(stmt, 0) else { return 0 }
        return Int64(String(cString: p)) ?? 0
    }

    private func writeLastMessageId(_ id: Int64) {
        guard id > 0 else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(indexDb,
            "INSERT OR REPLACE INTO metadata(key, value) VALUES('last_message_id', ?)",
            -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, String(id), -1, SQLITE_TRANSIENT_IM)
        sqlite3_step(stmt)
    }

    // MARK: - Search SQL

    private func querySQL(chatDbPath: String, query: String, limit: Int) -> [SearchResult] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        // ATTACH our decoded-text index so we can join in one SQL query.
        let attachEsc = indexDbPath.replacingOccurrences(of: "'", with: "''")
        sqlite3_exec(db, "ATTACH DATABASE '\(attachEsc)' AS idx", nil, nil, nil)

        let sql = """
            SELECT
                m.ROWID,
                COALESCE(m.text, decoded.text) AS msg_text,
                m.date,
                m.is_from_me,
                h.id AS handle,
                (SELECT c.display_name FROM chat c
                  JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                  WHERE cmj.message_id = m.ROWID LIMIT 1) AS chat_name,
                (SELECT c.chat_identifier FROM chat c
                  JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                  WHERE cmj.message_id = m.ROWID LIMIT 1) AS chat_identifier
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN idx.decoded_text decoded ON decoded.message_id = m.ROWID
            WHERE COALESCE(m.text, decoded.text) IS NOT NULL
              AND COALESCE(m.text, decoded.text) LIKE ? COLLATE NOCASE
            ORDER BY m.date DESC
            LIMIT \(limit)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(query)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT_IM)

        let now = Date()
        var out: [SearchResult] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let text     = colText(stmt, 1)
            let rawDate  = sqlite3_column_int64(stmt, 2)
            let isFromMe = sqlite3_column_int(stmt, 3) == 1
            let handle   = colTextOptional(stmt, 4) ?? ""
            let chatName = colTextOptional(stmt, 5) ?? ""
            let chatId   = colTextOptional(stmt, 6) ?? ""

            guard !text.isEmpty else { continue }

            let date = Self.appleDateToDate(rawDate)
            let title = displayName(chatName: chatName, chatIdentifier: chatId, handle: handle)
            let openHandle = !handle.isEmpty ? handle
                : (chatId.starts(with: "chat") ? "" : chatId)

            let days = max(0, now.timeIntervalSince(date) / 86_400)
            let rank = 60 + max(0, 80 - Int(days / 3))

            out.append(SearchResult(
                title: title,
                subtitle: collapse(text),
                source: .imessage,
                date: date,
                badge: isFromMe ? "you" : nil,
                openTarget: .imessageChat(handle: openHandle, messageText: text),
                rank: rank
            ))
        }
        return out
    }

    // MARK: - SQLite index management

    nonisolated private static func openIndex(path: String) -> OpaquePointer? {
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
            CREATE TABLE IF NOT EXISTS decoded_text (
                message_id INTEGER PRIMARY KEY,
                text TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """
        ] {
            sqlite3_exec(db, s, nil, nil, nil)
        }
        return db
    }

    // MARK: - Background pass: decode attributedBody → text

    private struct DecodedRow: Sendable { let messageId: Int64; let text: String }

    nonisolated private static func collectAttributedBodyRows(
        dbPath: String, sinceId: Int64
    ) -> [DecodedRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT ROWID, attributedBody
            FROM message
            WHERE text IS NULL
              AND attributedBody IS NOT NULL
              AND ROWID > \(sinceId)
            ORDER BY ROWID ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [DecodedRow] = []
        rows.reserveCapacity(1024)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            guard let bytes = sqlite3_column_blob(stmt, 1) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 1))
            guard len > 0 else { continue }
            let blob = Data(bytes: bytes, count: len)
            if let text = decodeAttributedBody(blob), !text.isEmpty {
                rows.append(DecodedRow(messageId: id, text: text))
            }
        }
        return rows
    }

    /// The `attributedBody` column is an NSKeyedArchiver-encoded
    /// NSAttributedString. NSKeyedUnarchiver gives us the object; we just
    /// want `.string`. We disable secure-coding because the archive uses
    /// pre-secure types.
    nonisolated private static func decodeAttributedBody(_ data: Data) -> String? {
        // The archive starts with the typedstream signature for older
        // NSAttributedStrings or NSKeyedArchiver header for newer ones.
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            if let obj = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) {
                if let attr = obj as? NSAttributedString { return attr.string }
                if let s = obj as? String { return s }
            }
            // Some archives use top-level "root" key with NSAttributedString.
            unarchiver.finishDecoding()
        } catch {
            // Fall through to typedstream attempt below.
        }
        // Fallback: very old format uses Apple typedstream (binary plist
        // marker `streamtyped`). We can extract the text by finding the
        // NSString marker — but for v0, give up.
        return nil
    }

    // MARK: - Helpers

    private func displayName(chatName: String, chatIdentifier: String, handle: String) -> String {
        if !chatName.isEmpty { return chatName }
        if !handle.isEmpty   { return handle }
        if !chatIdentifier.isEmpty, !chatIdentifier.starts(with: "chat") {
            return chatIdentifier
        }
        return "Messages"
    }

    private func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "  ", with: " ")
    }

    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: p)
    }

    private func colTextOptional(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: p)
    }

    /// Apple Messages stores `date` as either seconds since 2001-01-01 or
    /// nanoseconds since 2001-01-01 (macOS 10.13+). Detect by magnitude.
    private static func appleDateToDate(_ raw: Int64) -> Date {
        guard raw > 0 else { return .distantPast }
        let coreDataTime: Double = raw > 10_000_000_000
            ? Double(raw) / 1_000_000_000
            : Double(raw)
        return Date(timeIntervalSinceReferenceDate: coreDataTime)
    }
}
