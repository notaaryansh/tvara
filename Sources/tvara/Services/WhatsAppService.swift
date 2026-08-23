import Foundation
import SQLite3

private let SQLITE_TRANSIENT_WA = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Two SQLite files under one actor:
///   • upstream: `ChatStorage.sqlite` inside WhatsApp's group container.
///     Read-only; we snapshot to /tmp on each upstream read so a live
///     write from WhatsApp can't corrupt our reader.
///   • mirror:   `whatsapp_mirror.sqlite` under our Application Support
///     dir. Write-mostly; carries an FTS5 index over message text plus a
///     `chats` table sufficient to render contact rows. Search reads from
///     the mirror once it's bootstrapped — pre-bootstrap searches fall
///     back to a fresh upstream snapshot so users never see an empty
///     WhatsApp section.
///
/// The push-based ingestion pipeline (WhatsAppProducer + MessageIndexWorker)
/// drives mirror writes on a 5s cadence and bootstraps existing messages
/// in one batched pass on first launch.
actor WhatsAppService {
    private let upstreamPath: String
    private let mirrorPath: String
    private var mirrorDb: OpaquePointer?
    private let profilePicDir: String

    init() {
        let groupContainer = NSHomeDirectory()
            + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
        self.upstreamPath = groupContainer + "/ChatStorage.sqlite"
        self.profilePicDir = groupContainer + "/Media/Profile"

        let supportDir = NSHomeDirectory() + "/Library/Application Support/tvara"
        try? FileManager.default.createDirectory(
            atPath: supportDir, withIntermediateDirectories: true
        )
        self.mirrorPath = supportDir + "/whatsapp_mirror.sqlite"
    }

    deinit {
        if let mirrorDb { sqlite3_close(mirrorDb) }
    }

    // MARK: - Public surface

    /// Touch the WhatsApp ChatStorage path so macOS shows the Full Disk
    /// Access prompt on launch instead of on first search. Cheap — just a
    /// stat/open call; the file is read-only mapped and immediately closed.
    /// Also opens the mirror DB and runs schema bootstrap so the producer
    /// + worker have a destination ready.
    func warmCache() async {
        _ = try? Data(contentsOf: URL(fileURLWithPath: upstreamPath), options: [.mappedIfSafe])
        ensureMirrorOpen()
    }

    func search(query: String, limit: Int = 30) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        guard FileManager.default.fileExists(atPath: upstreamPath) else { return [] }

        ensureMirrorOpen()
        // While the mirror is empty (first launch, bootstrap not finished
        // yet), serve searches from a fresh upstream snapshot so the user
        // doesn't see an empty WhatsApp section. Once the worker has
        // indexed at least one batch the mirror becomes authoritative.
        if mirrorMessageCount() == 0 {
            return searchUpstreamSnapshot(query: trimmed, limit: limit)
        }
        return searchMirror(query: trimmed, limit: limit)
    }

    // MARK: - Producer support

    /// Largest `ZWAMESSAGE.Z_PK` we've already indexed into the mirror.
    /// The producer seeds its in-memory watermark from this on startup so
    /// crash recovery is automatic.
    func currentMessageWatermark() -> Int64 {
        ensureMirrorOpen()
        guard let db = mirrorDb else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(zpk), 0) FROM messages",
                                 -1, &stmt, nil) == SQLITE_OK else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Query upstream for Z_PKs greater than `since`. Cheap — index scan
    /// on Z_PK PK column. Snapshots ChatStorage to /tmp first.
    func fetchNewZPKs(since: Int64, limit: Int = 500) async -> [Int64] {
        guard FileManager.default.fileExists(atPath: upstreamPath),
              let tmp = copyUpstreamSnapshot() else { return [] }
        defer { Self.cleanupTempDb(tmp) }
        return await Task.detached(priority: .utility) {
            Self.selectNewZPKs(dbPath: tmp, since: since, limit: limit)
        }.value
    }

    // MARK: - Worker entry

    /// Decode + persist the given Z_PKs into the mirror. Single upstream
    /// snapshot serves the whole batch. Idempotent via INSERT OR REPLACE.
    /// Throws on transient copy/open failures so the bus can retry.
    func indexZPKs(_ zpks: [Int64]) async throws {
        ensureMirrorOpen()
        let unique = Array(Set(zpks))
        guard !unique.isEmpty, let db = mirrorDb else { return }

        guard FileManager.default.fileExists(atPath: upstreamPath) else { return }
        guard let tmp = copyUpstreamSnapshot() else {
            throw WhatsAppMirrorError.copyFailed
        }
        defer { Self.cleanupTempDb(tmp) }

        let upstream = upstreamPath
        let rows: (messages: [DecodedMessage], chats: [DecodedChat]) =
            await Task.detached(priority: .utility) {
                let m = Self.collectMessages(dbPath: tmp, zpks: unique)
                let c = Self.collectChats(dbPath: tmp, jids: Set(m.map(\.chatJid)))
                return (m, c)
            }.value
        _ = upstream  // silence unused-capture warning

        guard !rows.messages.isEmpty || !rows.chats.isEmpty else { return }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        upsertChats(rows.chats, db: db)
        upsertMessages(rows.messages, db: db)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - Mirror schema / open

    private func ensureMirrorOpen() {
        if mirrorDb != nil { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            mirrorPath, &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil
        ) == SQLITE_OK else {
            NSLog("WhatsAppService: failed to open mirror at %@", mirrorPath)
            if handle != nil { sqlite3_close(handle) }
            return
        }
        mirrorDb = handle
        let bootstrap: [String] = [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            """
            CREATE TABLE IF NOT EXISTS chats (
              jid          TEXT PRIMARY KEY,
              partner_name TEXT,
              session_type INTEGER NOT NULL DEFAULT 0,
              last_msg_ts  REAL NOT NULL DEFAULT 0,
              removed      INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS messages (
              zpk          INTEGER PRIMARY KEY,
              chat_jid     TEXT,
              text         TEXT,
              ts           REAL NOT NULL DEFAULT 0,
              is_from_me   INTEGER NOT NULL DEFAULT 0
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_msg_ts ON messages(ts DESC)",
            "CREATE INDEX IF NOT EXISTS idx_msg_chat ON messages(chat_jid)",
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
              text,
              content='messages',
              content_rowid='zpk',
              tokenize='porter unicode61'
            )
            """,
            """
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
              INSERT INTO messages_fts(rowid, text) VALUES (new.zpk, new.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, text) VALUES('delete', old.zpk, old.text);
              INSERT INTO messages_fts(rowid, text) VALUES (new.zpk, new.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, text) VALUES('delete', old.zpk, old.text);
            END
            """,
        ]
        for sql in bootstrap {
            if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
                NSLog("WhatsAppService: mirror bootstrap failed for: %@", sql)
            }
        }
    }

    private func mirrorMessageCount() -> Int {
        guard let db = mirrorDb else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages",
                                 -1, &stmt, nil) == SQLITE_OK else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Upstream snapshot helpers

    private func copyUpstreamSnapshot() -> String? {
        let tmp = NSTemporaryDirectory()
            + "spotlight_wa_snap_\(UUID().uuidString).sqlite"
        do {
            try FileManager.default.copyItem(atPath: upstreamPath, toPath: tmp)
        } catch {
            return nil
        }
        if FileManager.default.fileExists(atPath: upstreamPath + "-wal") {
            try? FileManager.default.copyItem(
                atPath: upstreamPath + "-wal", toPath: tmp + "-wal"
            )
        }
        if FileManager.default.fileExists(atPath: upstreamPath + "-shm") {
            try? FileManager.default.copyItem(
                atPath: upstreamPath + "-shm", toPath: tmp + "-shm"
            )
        }
        return tmp
    }

    nonisolated private static func cleanupTempDb(_ path: String) {
        for s in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + s)
        }
    }

    // MARK: - Upstream queries (nonisolated, run off the actor)

    nonisolated private static func selectNewZPKs(
        dbPath: String, since: Int64, limit: Int
    ) -> [Int64] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT Z_PK FROM ZWAMESSAGE
            WHERE Z_PK > ?
              AND ZTEXT IS NOT NULL
              AND ZTEXT != ''
            ORDER BY Z_PK ASC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_int64(stmt, 0))
        }
        return out
    }

    private struct DecodedMessage {
        let zpk: Int64
        let chatJid: String
        let text: String
        let ts: Double
        let isFromMe: Int
    }
    private struct DecodedChat {
        let jid: String
        let partnerName: String
        let sessionType: Int
        let lastMsgTs: Double
        let removed: Int
    }

    nonisolated private static func collectMessages(
        dbPath: String, zpks: [Int64]
    ) -> [DecodedMessage] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }
        // SQLite IN-list capped at 500 to stay below SQLITE_MAX_VARIABLE_NUMBER
        // even on stripped builds. Caller batches via worker batchSize.
        let placeholders = zpks.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT m.Z_PK, c.ZCONTACTJID, m.ZTEXT, m.ZMESSAGEDATE, m.ZISFROMME
            FROM ZWAMESSAGE m
            LEFT JOIN ZWACHATSESSION c ON c.Z_PK = m.ZCHATSESSION
            WHERE m.Z_PK IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, z) in zpks.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), z)
        }
        var out: [DecodedMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let zpk  = sqlite3_column_int64(stmt, 0)
            let jid  = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let ts   = sqlite3_column_double(stmt, 3)
            let from = Int(sqlite3_column_int(stmt, 4))
            if text.isEmpty { continue }
            if jid.hasPrefix("0@") { continue }   // WhatsApp system chats
            out.append(DecodedMessage(zpk: zpk, chatJid: jid, text: text, ts: ts, isFromMe: from))
        }
        return out
    }

    nonisolated private static func collectChats(
        dbPath: String, jids: Set<String>
    ) -> [DecodedChat] {
        guard !jids.isEmpty else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }
        let placeholders = jids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT ZCONTACTJID, ZPARTNERNAME, ZSESSIONTYPE, ZLASTMESSAGEDATE, ZREMOVED
            FROM ZWACHATSESSION
            WHERE ZCONTACTJID IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, j) in jids.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), j, -1, SQLITE_TRANSIENT_WA)
        }
        var out: [DecodedChat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let jid     = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let partner = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let stype   = Int(sqlite3_column_int(stmt, 2))
            let lts     = sqlite3_column_double(stmt, 3)
            let removed = Int(sqlite3_column_int(stmt, 4))
            if jid.isEmpty { continue }
            out.append(DecodedChat(
                jid: jid, partnerName: partner, sessionType: stype,
                lastMsgTs: lts, removed: removed
            ))
        }
        return out
    }

    // MARK: - Mirror writes

    private func upsertMessages(_ rows: [DecodedMessage], db: OpaquePointer) {
        let sql = """
            INSERT INTO messages (zpk, chat_jid, text, ts, is_from_me)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(zpk) DO UPDATE SET
              chat_jid   = excluded.chat_jid,
              text       = excluded.text,
              ts         = excluded.ts,
              is_from_me = excluded.is_from_me
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        for r in rows {
            sqlite3_bind_int64(stmt, 1, r.zpk)
            sqlite3_bind_text(stmt, 2, r.chatJid, -1, SQLITE_TRANSIENT_WA)
            sqlite3_bind_text(stmt, 3, r.text, -1, SQLITE_TRANSIENT_WA)
            sqlite3_bind_double(stmt, 4, r.ts)
            sqlite3_bind_int(stmt, 5, Int32(r.isFromMe))
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    private func upsertChats(_ rows: [DecodedChat], db: OpaquePointer) {
        let sql = """
            INSERT INTO chats (jid, partner_name, session_type, last_msg_ts, removed)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(jid) DO UPDATE SET
              partner_name = excluded.partner_name,
              session_type = excluded.session_type,
              last_msg_ts  = excluded.last_msg_ts,
              removed      = excluded.removed
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        for r in rows {
            sqlite3_bind_text(stmt, 1, r.jid, -1, SQLITE_TRANSIENT_WA)
            sqlite3_bind_text(stmt, 2, r.partnerName, -1, SQLITE_TRANSIENT_WA)
            sqlite3_bind_int(stmt, 3, Int32(r.sessionType))
            sqlite3_bind_double(stmt, 4, r.lastMsgTs)
            sqlite3_bind_int(stmt, 5, Int32(r.removed))
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    // MARK: - Mirror search

    private func searchMirror(query: String, limit: Int) -> [SearchResult] {
        guard let db = mirrorDb else { return [] }
        let avatars = buildAvatarIndex()
        let contacts = mirrorContacts(db: db, query: query, avatarIndex: avatars)
        let messages = mirrorMessages(db: db, query: query, limit: limit, avatarIndex: avatars)
        return contacts + messages
    }

    private func mirrorContacts(
        db: OpaquePointer, query: String, avatarIndex: [String: String]
    ) -> [SearchResult] {
        let sql = """
            SELECT partner_name, jid, session_type, last_msg_ts
            FROM chats
            WHERE partner_name LIKE ? COLLATE NOCASE
              AND partner_name IS NOT NULL
              AND partner_name != ''
              AND removed = 0
              AND session_type IN (0, 1)
              AND jid NOT LIKE '%.status'
            ORDER BY last_msg_ts DESC
            LIMIT 8
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        let pattern = "%\(query)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT_WA)

        var out: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let jid  = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let lts  = sqlite3_column_double(stmt, 3)
            guard !name.isEmpty, !jid.isEmpty else { continue }
            if jid.hasPrefix("0@") { continue }

            let date = lts > 0 ? Date(timeIntervalSinceReferenceDate: lts) : nil
            let subtitle = jid.hasSuffix("@g.us")
                ? "Open WhatsApp group"
                : "Open WhatsApp chat"
            let avatar = Self.loadAvatar(forJid: jid, avatarIndex: avatarIndex)
            out.append(SearchResult(
                title: name,
                subtitle: subtitle,
                source: .whatsapp,
                date: date,
                badge: nil,
                openTarget: .whatsappChat(jid: jid, messageText: ""),
                rank: 1_000,
                iconData: avatar
            ))
        }
        return out
    }

    private func mirrorMessages(
        db: OpaquePointer, query: String, limit: Int, avatarIndex: [String: String]
    ) -> [SearchResult] {
        // FTS5 MATCH for fast token matching + BM25 ordering. Fall back to
        // LIKE if FTS5 rejects the query (rare, but `:` and a few other
        // chars are reserved tokens that would parse-error).
        let escaped = fts5Escape(query)
        let sql = """
            SELECT m.text, m.ts, m.is_from_me,
                   c.partner_name, c.jid, c.session_type
            FROM messages_fts ft
            JOIN messages m ON m.zpk = ft.rowid
            LEFT JOIN chats c ON c.jid = m.chat_jid
            WHERE messages_fts MATCH ?
            ORDER BY m.ts DESC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, escaped, -1, SQLITE_TRANSIENT_WA)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        let now = Date()
        var out: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text       = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let ts         = sqlite3_column_double(stmt, 1)
            let isFromMe   = sqlite3_column_int(stmt, 2) == 1
            let partner    = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let jid        = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let sessionTyp = Int(sqlite3_column_int(stmt, 5))
            guard !text.isEmpty else { continue }
            if jid.hasPrefix("0@") { continue }

            let date     = Date(timeIntervalSinceReferenceDate: ts)
            let chatName = displayName(partner: partner, jid: jid, sessionType: sessionTyp)
            let snippet  = collapseWhitespace(text)
            let days     = max(0, now.timeIntervalSince(date) / 86_400)
            let recency  = max(0, 80 - Int(days / 3))
            let rank     = 60 + recency
            let avatar   = Self.loadAvatar(forJid: jid, avatarIndex: avatarIndex)
            out.append(SearchResult(
                title: chatName,
                subtitle: snippet,
                source: .whatsapp,
                date: date,
                badge: isFromMe ? "you" : nil,
                openTarget: .whatsappChat(jid: jid, messageText: text),
                rank: rank,
                iconData: avatar
            ))
        }
        return out
    }

    /// Wrap each whitespace-separated token in double quotes so FTS5
    /// treats it as a literal phrase. Eats reserved characters that would
    /// otherwise raise a malformed-MATCH error from inside SQLite.
    private func fts5Escape(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
    }

    // MARK: - Upstream search (fallback, used until mirror bootstraps)

    private func searchUpstreamSnapshot(query: String, limit: Int) -> [SearchResult] {
        guard let tmp = copyUpstreamSnapshot() else { return [] }
        defer { Self.cleanupTempDb(tmp) }
        let avatars = buildAvatarIndex()
        let contacts = queryUpstreamContacts(path: tmp, query: query, avatarIndex: avatars)
        let messages = queryUpstreamMessages(path: tmp, query: query, limit: limit, avatarIndex: avatars)
        return contacts + messages
    }

    private func queryUpstreamContacts(
        path: String, query: String, avatarIndex: [String: String]
    ) -> [SearchResult] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT ZPARTNERNAME, ZCONTACTJID, ZSESSIONTYPE, ZLASTMESSAGEDATE
            FROM ZWACHATSESSION
            WHERE ZPARTNERNAME LIKE ? COLLATE NOCASE
              AND ZPARTNERNAME IS NOT NULL
              AND ZPARTNERNAME != ''
              AND ZREMOVED = 0
              AND ZSESSIONTYPE IN (0, 1)
              AND ZCONTACTJID NOT LIKE '%.status'
            ORDER BY ZLASTMESSAGEDATE DESC
            LIMIT 8
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        let pattern = "%\(query)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT_WA)
        var results: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let jid  = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let lts  = sqlite3_column_double(stmt, 3)
            guard !name.isEmpty, !jid.isEmpty else { continue }
            if jid.hasPrefix("0@") { continue }
            let avatar = Self.loadAvatar(forJid: jid, avatarIndex: avatarIndex)
            let date = lts > 0 ? Date(timeIntervalSinceReferenceDate: lts) : nil
            let subtitle = jid.hasSuffix("@g.us")
                ? "Open WhatsApp group"
                : "Open WhatsApp chat"
            results.append(SearchResult(
                title: name, subtitle: subtitle,
                source: .whatsapp, date: date, badge: nil,
                openTarget: .whatsappChat(jid: jid, messageText: ""),
                rank: 1_000, iconData: avatar
            ))
        }
        return results
    }

    private func queryUpstreamMessages(
        path: String, query: String, limit: Int, avatarIndex: [String: String]
    ) -> [SearchResult] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT m.ZTEXT, m.ZMESSAGEDATE, m.ZISFROMME,
                   c.ZPARTNERNAME, c.ZCONTACTJID, c.ZSESSIONTYPE
            FROM ZWAMESSAGE m
            LEFT JOIN ZWACHATSESSION c ON c.Z_PK = m.ZCHATSESSION
            WHERE m.ZTEXT LIKE ?
              AND m.ZTEXT IS NOT NULL
              AND m.ZTEXT != ''
            ORDER BY m.ZMESSAGEDATE DESC
            LIMIT \(limit)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        let pattern = "%\(query)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT_WA)
        var results: [SearchResult] = []
        let now = Date()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text        = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let ts          = sqlite3_column_double(stmt, 1)
            let isFromMe    = sqlite3_column_int(stmt, 2) == 1
            let partner     = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let jid         = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let sessionType = Int(sqlite3_column_int(stmt, 5))
            guard !text.isEmpty else { continue }
            if jid.hasPrefix("0@") { continue }
            let date = Date(timeIntervalSinceReferenceDate: ts)
            let chatName = displayName(partner: partner, jid: jid, sessionType: sessionType)
            let snippet = collapseWhitespace(text)
            let days = max(0, now.timeIntervalSince(date) / 86_400)
            let recency = max(0, 80 - Int(days / 3))
            let rank = 60 + recency
            let avatar = Self.loadAvatar(forJid: jid, avatarIndex: avatarIndex)
            results.append(SearchResult(
                title: chatName, subtitle: snippet,
                source: .whatsapp, date: date,
                badge: isFromMe ? "you" : nil,
                openTarget: .whatsappChat(jid: jid, messageText: text),
                rank: rank, iconData: avatar
            ))
        }
        return results
    }

    // MARK: - Avatar / display name helpers

    private func buildAvatarIndex() -> [String: String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: profilePicDir) else {
            return [:]
        }
        var index: [String: (path: String, isFull: Bool)] = [:]
        for name in entries {
            let isThumb = name.hasSuffix(".thumb")
            let isJpg   = name.hasSuffix(".jpg")
            guard isThumb || isJpg else { continue }
            guard let dash = name.firstIndex(of: "-") else { continue }
            let localPart = String(name[..<dash])
            guard !localPart.isEmpty else { continue }
            let path = profilePicDir + "/" + name
            if let existing = index[localPart], existing.isFull, isThumb { continue }
            index[localPart] = (path, isJpg)
        }
        return index.mapValues { $0.path }
    }

    private func displayName(partner: String, jid: String, sessionType: Int) -> String {
        if !partner.isEmpty { return partner }
        if jid.hasSuffix("@g.us") { return "Group" }
        if let at = jid.firstIndex(of: "@") {
            let raw = String(jid[..<at])
            if raw.allSatisfy({ $0.isNumber }) { return "+" + raw }
            return raw
        }
        return jid.isEmpty ? "Unknown" : jid
    }

    private func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "  ", with: " ")
    }

    nonisolated private static func loadAvatar(
        forJid jid: String, avatarIndex: [String: String]
    ) -> Data? {
        guard let at = jid.firstIndex(of: "@") else { return nil }
        let localPart = String(jid[..<at])
        guard !localPart.isEmpty,
              let path = avatarIndex[localPart] else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}

enum WhatsAppMirrorError: Error {
    case copyFailed
}
