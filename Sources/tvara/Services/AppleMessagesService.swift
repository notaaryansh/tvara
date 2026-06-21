import Foundation
import SQLite3

private let SQLITE_TRANSIENT_IM = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor AppleMessagesService {
    private let chatDbPath: String
    private let indexDbPath: String
    private var indexDb: OpaquePointer?
    private var lastBuildCheck: Date?
    private var buildTask: Task<Void, Never>?
    private let contactsResolver: ContactsResolver
    private static let refreshLifetime: TimeInterval = 60

    init(contactsResolver: ContactsResolver = ContactsResolver()) {
        self.chatDbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
        self.contactsResolver = contactsResolver

        let supportDir = NSHomeDirectory()
            + "/Library/Application Support/tvara"
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
        // Warm both the chat.db decoded-text cache AND the Contacts.app
        // resolver — that way every TCC prompt iMessage search depends on
        // (Full Disk Access + Contacts) fires at app launch instead of
        // staggered across the first few searches.
        async let chatWarm: Void = refreshIfNeeded()
        async let contactsWarm: Void = contactsResolver.warmCache()
        _ = await (chatWarm, contactsWarm)
    }

    func search(query: String, limit: Int = 30) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }

        await refreshIfNeeded()

        // chat.db copy (FDA-gated). On TCC denial we still want the
        // Contacts.app-derived cards to appear, so the rest of this
        // function treats chat.db data as optional.
        var chatDbContacts: [SearchResult] = []
        var messages: [SearchResult] = []
        if FileManager.default.fileExists(atPath: chatDbPath),
           let tmpDb = copyChatDb() {
            defer { Self.cleanupTempDb(tmpDb) }
            chatDbContacts = queryContactCards(chatDbPath: tmpDb, query: trimmed)
            messages = querySQL(chatDbPath: tmpDb, query: trimmed, limit: limit)
        }

        // Contacts.app cards run unconditionally — they need only the
        // Contacts permission, not Full Disk Access.
        let abContacts = await contactCardsFromAddressBook(
            query: trimmed,
            excluding: chatDbContacts
        )

        return chatDbContacts + abContacts + messages
    }

    /// Copy chat.db + WAL/SHM into a temp file for read-only querying.
    /// Returns nil if the primary copy fails (typically TCC denial).
    private func copyChatDb() -> String? {
        let tmpDb  = NSTemporaryDirectory() + "spotlight_imsg_\(UUID().uuidString).db"
        do {
            try FileManager.default.copyItem(atPath: chatDbPath, toPath: tmpDb)
        } catch {
            return nil
        }
        for suffix in ["-wal", "-shm"] {
            let src = chatDbPath + suffix
            if FileManager.default.fileExists(atPath: src) {
                try? FileManager.default.copyItem(atPath: src, toPath: tmpDb + suffix)
            }
        }
        return tmpDb
    }

    nonisolated private static func cleanupTempDb(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Address-book backed lookup: ask Contacts.app for anyone whose name
    /// matches the needle, then emit one card per contact using their
    /// first phone/email as the iMessage handle. Skips contacts whose
    /// handle is already represented in chatDb-derived cards (dedupes by
    /// normalized phone digits / lowercased email).
    private func contactCardsFromAddressBook(
        query: String, excluding existing: [SearchResult]
    ) async -> [SearchResult] {
        let seen: Set<String> = Set(existing.compactMap { r -> String? in
            if case .imessageChat(let h, _) = r.openTarget {
                return Self.normalizeHandle(h)
            }
            return nil
        })

        let matches = await contactsResolver.search(name: query)
        var out: [SearchResult] = []
        for c in matches {
            // Prefer phone over email — iMessage routes phones via SMS too,
            // and most people initiate iMessage chats with phone numbers.
            let handle = c.phoneNumbers.first ?? c.emails.first
            guard let handle, !handle.isEmpty else { continue }
            let norm = Self.normalizeHandle(handle)
            if seen.contains(norm) { continue }

            let title = c.displayName.isEmpty ? handle : c.displayName
            out.append(SearchResult(
                title: title,
                subtitle: "Open iMessage chat",
                source: .imessage,
                date: nil,
                badge: nil,
                openTarget: .imessageChat(handle: handle, messageText: ""),
                rank: 990,                     // just below chat.db cards (1000)
                iconData: c.imageData
            ))
        }
        return out
    }

    /// Normalize a handle for dedup: phones → digits only, emails → lowercase.
    /// Used so "+1 (415) 555-1234" and "4155551234" hash to the same key.
    nonisolated private static func normalizeHandle(_ h: String) -> String {
        if h.contains("@") {
            return h.lowercased()
        }
        return h.filter { $0.isNumber }
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
        // Migration safety net: the EventBus + IMessageProducer path now
        // delivers new chat.db ROWIDs as events. The legacy bulk path
        // remains as a fallback while the queue bakes — gate via
        // `EventBusConfig.legacyPullRefreshEnabled` so we can flip it off
        // once the queue is trusted.
        guard EventBusConfig.legacyPullRefreshEnabled else { return }

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

    /// Queue-driven entry point: decode + ingest a specific batch of
    /// chat.db ROWIDs. Idempotent (INSERT OR REPLACE) so re-processing a
    /// `message_added` event after a crash is safe. Throws on transient
    /// failures (chat.db copy / sqlite open) so the worker can retry;
    /// only bumps the `last_message_id` watermark after a successful pass.
    func indexRowIds(_ rowids: [Int64]) async throws {
        let unique = Array(Set(rowids))
        guard !unique.isEmpty else { return }

        let chatPath = chatDbPath
        let dbCopyPath = NSTemporaryDirectory()
            + "spotlight_imsg_queue_\(UUID().uuidString).db"
        try FileManager.default.copyItem(atPath: chatPath, toPath: dbCopyPath)
        if FileManager.default.fileExists(atPath: chatPath + "-wal") {
            try? FileManager.default.copyItem(
                atPath: chatPath + "-wal", toPath: dbCopyPath + "-wal"
            )
        }
        defer {
            for s in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbCopyPath + s)
            }
        }

        let rows = try await Task.detached(priority: .utility) {
            try Self.collectAttributedBodyRowsByIds(dbPath: dbCopyPath, rowids: unique)
        }.value

        if !rows.isEmpty { ingest(rows) }
        // Bump watermark to the requested max only on a clean pass —
        // throws above leave the watermark put so retries re-cover the
        // same range. A pass that ingested zero rows (all text-only) is
        // still a clean pass.
        let watermark = max(readLastMessageId(), unique.max() ?? 0)
        writeLastMessageId(watermark)
    }

    nonisolated private static func collectAttributedBodyRowsByIds(
        dbPath: String, rowids: [Int64]
    ) throws -> [DecodedRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(
                domain: "AppleMessagesService", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "sqlite_open failed for chat.db copy"]
            )
        }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: rowids.count).joined(separator: ",")
        let sql = """
            SELECT ROWID, attributedBody
            FROM message
            WHERE text IS NULL
              AND attributedBody IS NOT NULL
              AND ROWID IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "AppleMessagesService", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "sqlite_prepare failed"]
            )
        }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in rowids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), id)
        }

        var rows: [DecodedRow] = []
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

    /// Read the producer's chat.db ROWID ceiling for the queue path.
    /// Producers consult this so they don't re-emit events for rows the
    /// legacy refresh has already covered.
    func currentMessageWatermark() -> Int64 {
        readLastMessageId()
    }

    /// Producer-side: list chat.db ROWIDs strictly greater than `since`.
    /// Returns ROWID-only (no decoding). Caller batches them into events.
    func fetchNewRowIds(since: Int64, limit: Int = 500) async -> [Int64] {
        guard FileManager.default.fileExists(atPath: chatDbPath),
              let tmpDb = copyChatDb() else { return [] }
        defer { Self.cleanupTempDb(tmpDb) }
        return await Task.detached(priority: .utility) {
            Self.fetchRowIds(dbPath: tmpDb, since: since, limit: limit)
        }.value
    }

    nonisolated private static func fetchRowIds(
        dbPath: String, since: Int64, limit: Int
    ) -> [Int64] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT ROWID FROM message
            WHERE ROWID > ?
            ORDER BY ROWID ASC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
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
