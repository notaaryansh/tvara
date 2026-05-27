import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DC = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor DiscordService {
    // MARK: - Configuration

    private let cacheDir: String
    private let indexDbPath: String
    private static let indexLifetime: TimeInterval = 60   // re-check cache dir at most this often

    private var db: OpaquePointer?
    private var lastDirCheck: Date?
    private var buildTask: Task<Void, Never>?

    init() {
        self.cacheDir = NSHomeDirectory()
            + "/Library/Application Support/discord/Cache/Cache_Data"

        let supportDir = NSHomeDirectory()
            + "/Library/Application Support/spotlight++"
        try? FileManager.default.createDirectory(
            atPath: supportDir, withIntermediateDirectories: true
        )
        self.indexDbPath = supportDir + "/discord_index.db"
        self.db = Self.openAndPrepareSchema(path: indexDbPath)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    func warmCache() async {
        await refreshIfNeeded()
    }

    func search(query: String, limit: Int = 30) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        guard FileManager.default.fileExists(atPath: cacheDir) else { return [] }

        await refreshIfNeeded()
        let contacts = queryContacts(needle: trimmed)
        let messages = querySQL(needle: trimmed, limit: limit)
        return contacts + messages
    }

    /// Find every message involving a contact by resolving their username
    /// to a user_id and filtering on that — NOT on content text. Returns
    /// messages where the contact is the author or the channel recipient
    /// (i.e., a DM with them). The semantic reranker then orders this pool
    /// by similarity to the planner's search_term.
    ///
    /// Returns the contact-card rows too so the "Open chat with X" shortcut
    /// stays available alongside the message hits.
    func messagesInvolving(contactName: String, limit: Int = 200) async -> [SearchResult] {
        let trimmed = contactName.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        guard FileManager.default.fileExists(atPath: cacheDir) else { return [] }
        await refreshIfNeeded()

        let userIds = resolveUserIds(matching: trimmed)
        let contactCards = queryContacts(needle: trimmed)
        guard !userIds.isEmpty else { return contactCards }

        let messages = queryMessagesByUserIds(userIds, limit: limit)
        return contactCards + messages
    }

    /// Return every Discord message as a SearchResult, ordered by recency,
    /// for the semantic reranker to score. Used on no-contact "messages"
    /// queries — the rerank's similarity floor handles relevance, so the
    /// pool can safely be the whole index. Result-set is capped to keep
    /// the cosine pass bounded; the cap is high enough to cover any
    /// realistic personal-account index.
    func allMessagesForRerank(limit: Int = 10_000) async -> [SearchResult] {
        guard FileManager.default.fileExists(atPath: cacheDir) else { return [] }
        await refreshIfNeeded()
        let sql = """
            \(Self.messageSelectPrefix)
            ORDER BY m.timestamp DESC
            LIMIT \(limit)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        return drainMessageRows(stmt: stmt)
    }

    /// All user_ids whose username matches the needle (case-insensitive
    /// substring). Returns at most 5 to keep the IN-clause bounded.
    private func resolveUserIds(matching needle: String) -> [String] {
        var ids: [String] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id FROM users WHERE username LIKE ? COLLATE NOCASE LIMIT 5"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        let pattern = "%\(needle)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT_DC)
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(colText(stmt, 0))
        }
        return ids
    }

    /// Match against known Discord usernames + guild names. Top-ranked so
    /// they appear above message hits. For users we have a DM channel for,
    /// deep-link straight to the DM; otherwise open the user's profile.
    private func queryContacts(needle: String) -> [SearchResult] {
        var out: [SearchResult] = []
        let pattern = "%\(needle)%"

        // ---- Users (matches Discord usernames) ----
        // LEFT JOIN channels to find a DM channel (recipient_id = user.id)
        // when one exists, plus avatar bytes for the card.
        let userSQL = """
            SELECT u.id, u.username,
                   c.id AS dm_channel_id,
                   a.image_data AS avatar
            FROM users u
            LEFT JOIN channels c ON c.recipient_id = u.id
            LEFT JOIN avatars a ON a.user_id = u.id
            WHERE u.username LIKE ? COLLATE NOCASE
            LIMIT 6
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, userSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT_DC)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let userId = colText(stmt, 0)
                let name   = colText(stmt, 1)
                let dmCh   = colTextOptional(stmt, 2)
                let avatar = colBlobOptional(stmt, 3)
                guard !userId.isEmpty, !name.isEmpty else { continue }

                // Prefer a known DM channel for the deep-link; fall back to
                // the user-profile URL which lets you DM them from there.
                let openURL: String = {
                    if let dmCh, !dmCh.isEmpty {
                        return "discord://-/channels/@me/\(dmCh)"
                    }
                    return "discord://-/users/\(userId)"
                }()

                out.append(SearchResult(
                    title: name,
                    subtitle: "Open Discord DM",
                    source: .discord,
                    date: nil,
                    badge: nil,
                    openTarget: .url(openURL),
                    rank: 1_000,
                    iconData: avatar
                ))
            }
        }

        // ---- Guilds (matches server names) ----
        let guildSQL = """
            SELECT g.id, g.name, gi.image_data
            FROM guilds g
            LEFT JOIN guild_icons gi ON gi.guild_id = g.id
            WHERE g.name LIKE ? COLLATE NOCASE
            LIMIT 4
        """
        var gStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, guildSQL, -1, &gStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(gStmt) }
            sqlite3_bind_text(gStmt, 1, pattern, -1, SQLITE_TRANSIENT_DC)
            while sqlite3_step(gStmt) == SQLITE_ROW {
                let id   = colText(gStmt, 0)
                let name = colText(gStmt, 1)
                let icon = colBlobOptional(gStmt, 2)
                guard !id.isEmpty, !name.isEmpty else { continue }
                out.append(SearchResult(
                    title: name,
                    subtitle: "Open Discord server",
                    source: .discord,
                    date: nil,
                    badge: nil,
                    openTarget: .url("discord://-/channels/\(id)"),
                    rank: 1_000,
                    iconData: icon
                ))
            }
        }
        return out
    }

    // MARK: - Index lifecycle

    private func refreshIfNeeded() async {
        // Avoid hammering the filesystem on every keystroke.
        if let t = lastDirCheck, Date().timeIntervalSince(t) < Self.indexLifetime {
            return
        }
        if let existing = buildTask {
            await existing.value
            return
        }
        let task = Task {
            await self.runIncrementalBuild()
        }
        buildTask = task
        await task.value
        buildTask = nil
        lastDirCheck = Date()
    }

    private func runIncrementalBuild() async {
        let lastBuilt = readLastBuildTime() ?? .distantPast
        let cacheDir = self.cacheDir

        // Heavy work: enumerate, parse, return rows to ingest. Detached
        // so we don't block the actor for the multi-second scan.
        let payload: [ParsedEndpoint] = await Task.detached(priority: .userInitiated) {
            Self.scanCache(cacheDir: cacheDir, since: lastBuilt)
        }.value

        guard !payload.isEmpty else { return }
        ingestSQL(payload)
        writeLastBuildTime(Date())
    }

    // MARK: - SQLite open + schema

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
            """
            CREATE TABLE IF NOT EXISTS guilds (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                icon_hash TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS channels (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL DEFAULT '',
                guild_id TEXT,
                recipient_id TEXT,
                type INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                username TEXT NOT NULL,
                avatar_hash TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                channel_id TEXT NOT NULL,
                author_id TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp INTEGER NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS avatars (
                user_id TEXT PRIMARY KEY,
                image_data BLOB NOT NULL,
                size INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS guild_icons (
                guild_id TEXT PRIMARY KEY,
                image_data BLOB NOT NULL,
                size INTEGER NOT NULL DEFAULT 0
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_messages_ch ON messages(channel_id)",
            "CREATE INDEX IF NOT EXISTS idx_messages_author ON messages(author_id)",
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """
        ]
        for s in stmts { sqlite3_exec(db, s, nil, nil, nil) }
        return db
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func readLastBuildTime() -> Date? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key='last_build_time'",
                                 -1, &stmt, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cstr = sqlite3_column_text(stmt, 0) else { return nil }
        let s = String(cString: cstr)
        guard let secs = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: secs)
    }

    private func writeLastBuildTime(_ date: Date) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO metadata(key,value) VALUES('last_build_time', ?)",
            -1, &stmt, nil
        ) == SQLITE_OK else { return }
        let v = String(date.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 1, v, -1, SQLITE_TRANSIENT_DC)
        sqlite3_step(stmt)
    }

    // MARK: - Ingest into SQLite

    private func ingestSQL(_ items: [ParsedEndpoint]) {
        exec("BEGIN TRANSACTION")

        var guildStmt:   OpaquePointer?
        var channelStmt: OpaquePointer?
        var userStmt:    OpaquePointer?
        var messageStmt: OpaquePointer?
        var avatarStmt:    OpaquePointer?
        var guildIconStmt: OpaquePointer?

        sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO guilds(id, name, icon_hash) VALUES(?,?,?)",
            -1, &guildStmt, nil)
        // Conditional upsert: preserve any existing name (don't clobber with
        // empty) and fill in missing guild_id/recipient_id when we learn them.
        sqlite3_prepare_v2(db, """
            INSERT INTO channels(id, name, guild_id, recipient_id, type) VALUES(?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                name = CASE WHEN excluded.name != '' THEN excluded.name ELSE channels.name END,
                guild_id = COALESCE(channels.guild_id, excluded.guild_id),
                recipient_id = COALESCE(channels.recipient_id, excluded.recipient_id),
                type = CASE WHEN excluded.type != 0 THEN excluded.type ELSE channels.type END
        """, -1, &channelStmt, nil)
        sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO users(id, username, avatar_hash) VALUES(?,?,?)",
            -1, &userStmt, nil)
        sqlite3_prepare_v2(db,
            "INSERT OR IGNORE INTO messages(id, channel_id, author_id, content, timestamp) VALUES(?,?,?,?,?)",
            -1, &messageStmt, nil)
        // Image upserts: only replace if the new image is larger (better quality).
        sqlite3_prepare_v2(db, """
            INSERT INTO avatars(user_id, image_data, size) VALUES(?,?,?)
            ON CONFLICT(user_id) DO UPDATE SET
                image_data = excluded.image_data,
                size = excluded.size
            WHERE excluded.size > avatars.size
        """, -1, &avatarStmt, nil)
        sqlite3_prepare_v2(db, """
            INSERT INTO guild_icons(guild_id, image_data, size) VALUES(?,?,?)
            ON CONFLICT(guild_id) DO UPDATE SET
                image_data = excluded.image_data,
                size = excluded.size
            WHERE excluded.size > guild_icons.size
        """, -1, &guildIconStmt, nil)

        defer {
            sqlite3_finalize(guildStmt)
            sqlite3_finalize(channelStmt)
            sqlite3_finalize(userStmt)
            sqlite3_finalize(messageStmt)
            sqlite3_finalize(avatarStmt)
            sqlite3_finalize(guildIconStmt)
        }

        for item in items {
            switch item {
            case .guild(let g):
                bind(guildStmt, [g.id, g.name, g.iconHash])
                sqlite3_step(guildStmt); sqlite3_reset(guildStmt)
            case .channel(let c):
                guildStmt.flatMap { _ in }
                sqlite3_bind_text(channelStmt, 1, c.id, -1, SQLITE_TRANSIENT_DC)
                sqlite3_bind_text(channelStmt, 2, c.name, -1, SQLITE_TRANSIENT_DC)
                if let gid = c.guildId {
                    sqlite3_bind_text(channelStmt, 3, gid, -1, SQLITE_TRANSIENT_DC)
                } else {
                    sqlite3_bind_null(channelStmt, 3)
                }
                if let rid = c.recipientId {
                    sqlite3_bind_text(channelStmt, 4, rid, -1, SQLITE_TRANSIENT_DC)
                } else {
                    sqlite3_bind_null(channelStmt, 4)
                }
                sqlite3_bind_int(channelStmt, 5, Int32(c.type))
                sqlite3_step(channelStmt); sqlite3_reset(channelStmt)
            case .user(let u):
                bind(userStmt, [u.id, u.username, u.avatarHash])
                sqlite3_step(userStmt); sqlite3_reset(userStmt)
            case .message(let m):
                sqlite3_bind_text(messageStmt, 1, m.id, -1, SQLITE_TRANSIENT_DC)
                sqlite3_bind_text(messageStmt, 2, m.channelId, -1, SQLITE_TRANSIENT_DC)
                sqlite3_bind_text(messageStmt, 3, m.authorId, -1, SQLITE_TRANSIENT_DC)
                sqlite3_bind_text(messageStmt, 4, m.content, -1, SQLITE_TRANSIENT_DC)
                sqlite3_bind_int64(messageStmt, 5, Int64(m.timestamp.timeIntervalSince1970))
                sqlite3_step(messageStmt); sqlite3_reset(messageStmt)
            case .avatar(let a):
                sqlite3_bind_text(avatarStmt, 1, a.userId, -1, SQLITE_TRANSIENT_DC)
                _ = a.bytes.withUnsafeBytes { raw in
                    sqlite3_bind_blob(avatarStmt, 2, raw.baseAddress, Int32(a.bytes.count), SQLITE_TRANSIENT_DC)
                }
                sqlite3_bind_int(avatarStmt, 3, Int32(a.size))
                sqlite3_step(avatarStmt); sqlite3_reset(avatarStmt)
            case .guildIcon(let g):
                sqlite3_bind_text(guildIconStmt, 1, g.guildId, -1, SQLITE_TRANSIENT_DC)
                _ = g.bytes.withUnsafeBytes { raw in
                    sqlite3_bind_blob(guildIconStmt, 2, raw.baseAddress, Int32(g.bytes.count), SQLITE_TRANSIENT_DC)
                }
                sqlite3_bind_int(guildIconStmt, 3, Int32(g.size))
                sqlite3_step(guildIconStmt); sqlite3_reset(guildIconStmt)
            }
        }

        exec("COMMIT")
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [String?]) {
        for (i, v) in values.enumerated() {
            if let v {
                sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT_DC)
            } else {
                sqlite3_bind_null(stmt, Int32(i + 1))
            }
        }
    }

    // MARK: - SQL query

    /// Shared SELECT used by both content-LIKE search and the new contact-id
    /// filter. The WHERE clause is appended by callers.
    private static let messageSelectPrefix = """
        SELECT m.id, m.channel_id, m.author_id, m.content, m.timestamp,
               c.name AS channel_name, c.guild_id, c.recipient_id, c.type,
               g.name AS guild_name,
               recip.username AS recipient_username,
               author.username AS author_username,
               av_author.image_data AS author_avatar,
               av_recip.image_data  AS recipient_avatar,
               gi.image_data        AS guild_icon
        FROM messages m
        LEFT JOIN channels c       ON c.id = m.channel_id
        LEFT JOIN guilds   g       ON g.id = c.guild_id
        LEFT JOIN users  recip     ON recip.id = c.recipient_id
        LEFT JOIN users  author    ON author.id = m.author_id
        LEFT JOIN avatars av_author ON av_author.user_id = m.author_id
        LEFT JOIN avatars av_recip  ON av_recip.user_id = c.recipient_id
        LEFT JOIN guild_icons gi    ON gi.guild_id = c.guild_id
    """

    /// Messages "involving the contact." Three overlapping conditions are
    /// unioned because Discord's cache doesn't reliably give us channel
    /// metadata — so we can't just filter by recipient_id alone:
    ///   1. messages the contact authored anywhere
    ///   2. messages in any DM channel whose recipient is the contact
    ///      (when we DID harvest the channel record)
    ///   3. messages in any channel where the contact has ever spoken —
    ///      this rescues the user's OWN sent messages in a DM with the
    ///      contact when (2) is missing channel metadata. Without this,
    ///      "what address did I send drish" never sees the user's own
    ///      address message because the DM channel's recipient_id is NULL.
    private func queryMessagesByUserIds(_ ids: [String], limit: Int) -> [SearchResult] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            WITH contact_channels AS (
                SELECT DISTINCT channel_id FROM messages
                WHERE author_id IN (\(placeholders))
            )
            \(Self.messageSelectPrefix)
            WHERE m.author_id IN (\(placeholders))
               OR c.recipient_id IN (\(placeholders))
               OR m.channel_id IN (SELECT channel_id FROM contact_channels)
            ORDER BY m.timestamp DESC
            LIMIT \(limit)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        // Bind ids three times: CTE author_id, WHERE author_id, WHERE recipient_id.
        for round in 0..<3 {
            for (i, id) in ids.enumerated() {
                sqlite3_bind_text(stmt,
                    Int32(round * ids.count + i + 1),
                    id, -1, SQLITE_TRANSIENT_DC)
            }
        }
        return drainMessageRows(stmt: stmt)
    }

    private func querySQL(needle: String, limit: Int) -> [SearchResult] {
        let sql = """
            \(Self.messageSelectPrefix)
            WHERE m.content LIKE ? COLLATE NOCASE
            ORDER BY m.timestamp DESC
            LIMIT \(limit)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(needle)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT_DC)
        return drainMessageRows(stmt: stmt)
    }

    /// Materialize SearchResult rows from a prepared statement that follows
    /// the `messageSelectPrefix` column layout.
    private func drainMessageRows(stmt: OpaquePointer?) -> [SearchResult] {
        let now = Date()
        var out: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId  = colText(stmt, 0)
            let channelId  = colText(stmt, 1)
            let content    = colText(stmt, 3)
            let ts         = sqlite3_column_int64(stmt, 4)
            let chanName   = colText(stmt, 5)
            let guildId    = colTextOptional(stmt, 6)
            let guildName  = colTextOptional(stmt, 9)
            let dmUser     = colTextOptional(stmt, 10)
            let author     = colTextOptional(stmt, 11)
            let authorAv   = colBlobOptional(stmt, 12)
            let recipAv    = colBlobOptional(stmt, 13)
            let guildIcon  = colBlobOptional(stmt, 14)

            let date = Date(timeIntervalSince1970: TimeInterval(ts))

            // Resolve title, badge, sender-display, icon based on what we have.
            let isServer = guildName != nil && !(guildName!.isEmpty)
            let title: String
            let badge: String?
            let iconData: Data?
            let displaySender: String?

            if isServer {
                title = guildName!
                badge = chanName.isEmpty ? nil : "#\(chanName)"
                iconData = guildIcon ?? authorAv     // prefer server icon; fall back to sender avatar
                displaySender = author               // show "Sender: msg" in subtitle
            } else if let dmUser, !dmUser.isEmpty {
                title = dmUser
                badge = nil
                iconData = recipAv ?? authorAv       // prefer recipient; fall back to sender
                displaySender = nil                  // DM context is implicit
            } else if !chanName.isEmpty,
                      let chanType = colTypeOptional(stmt: stmt, idx: 8),
                      [0, 2, 4, 5, 13, 15, 16].contains(chanType) {
                // We have a server channel name but no guild record. Still
                // useful — show "#channel-name" prefixed with sender so the
                // user gets context.
                title = author ?? "Discord"
                badge = "#\(chanName)"
                iconData = authorAv
                displaySender = nil                  // sender is the title
            } else if let author, !author.isEmpty {
                // No channel metadata — fall back to the sender's name
                // (almost always correct for DMs).
                title = author
                badge = nil
                iconData = authorAv
                displaySender = nil
            } else {
                title = chanName.isEmpty ? "Discord" : chanName
                badge = nil
                iconData = nil
                displaySender = nil
            }

            let openURL: String = {
                if let guildId {
                    return "discord://-/channels/\(guildId)/\(channelId)/\(messageId)"
                }
                return "discord://-/channels/@me/\(channelId)/\(messageId)"
            }()

            let days = max(0, now.timeIntervalSince(date) / 86_400)
            let rank = 60 + max(0, 80 - Int(days / 3))

            out.append(SearchResult(
                title: title,
                subtitle: collapseWS(content),
                source: .discord,
                date: date,
                badge: badge,
                openTarget: .url(openURL),
                rank: rank,
                iconData: iconData,
                senderName: displaySender
            ))
        }
        return out
    }

    private func colTypeOptional(stmt: OpaquePointer?, idx: Int32) -> Int? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, idx))
    }

    private func colBlobOptional(_ stmt: OpaquePointer?, _ idx: Int32) -> Data? {
        guard sqlite3_column_type(stmt, idx) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(stmt, idx) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, idx))
        guard len > 0 else { return nil }
        return Data(bytes: bytes, count: len)
    }

    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: p)
    }

    private func colTextOptional(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: p)
    }

    private func collapseWS(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "  ", with: " ")
    }

    // MARK: - Cache scan (heavy; runs detached)

    private enum ParsedEndpoint: Sendable {
        case guild(GuildRow)
        case channel(ChannelRow)
        case user(UserRow)
        case message(MessageRow)
        case avatar(AvatarRow)
        case guildIcon(GuildIconRow)
    }
    private struct GuildRow:     Sendable { let id: String; let name: String; let iconHash: String? }
    private struct ChannelRow:   Sendable { let id: String; let name: String; let guildId: String?; let recipientId: String?; let type: Int }
    private struct UserRow:      Sendable { let id: String; let username: String; let avatarHash: String? }
    private struct MessageRow:   Sendable { let id: String; let channelId: String; let authorId: String; let content: String; let timestamp: Date }
    private struct AvatarRow:    Sendable { let userId: String; let bytes: Data; let size: Int }
    private struct GuildIconRow: Sendable { let guildId: String; let bytes: Data; let size: Int }

    nonisolated private static func scanCache(cacheDir: String, since: Date) -> [ParsedEndpoint] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: cacheDir)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .nameKey]

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var out: [ParsedEndpoint] = []
        out.reserveCapacity(2048)

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasSuffix("_0") else { continue }

            // Incremental: skip files that haven't changed since the last build.
            if since != .distantPast {
                let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if mtime <= since { continue }
            }

            guard let entry = ChromiumCacheParser.parse(fileURL: fileURL) else { continue }
            classifyAndAppend(entry: entry, into: &out)
        }
        return out
    }

    nonisolated private static func classifyAndAppend(
        entry: ChromiumCacheParser.Entry, into out: inout [ParsedEndpoint]
    ) {
        let url = entry.url
        let urlOnly = url.contains("https://") ? String(url.drop(while: { $0 != "h" })) : url

        // ---- avatar images on Discord's CDN ----
        if let range = urlOnly.range(
            of: #"cdn\.discordapp\.com/avatars/(\d+)/[a-f0-9]+\.(webp|png|gif|jpg)"#,
            options: .regularExpression
        ) {
            let userId = extractIdFromCDNURL(urlOnly[range], pathSegment: "/avatars/")
            if !userId.isEmpty {
                let size = parseSize(from: urlOnly)
                out.append(.avatar(AvatarRow(
                    userId: userId, bytes: entry.body, size: size
                )))
            }
            return
        }

        // ---- guild (server) icon images on Discord's CDN ----
        if let range = urlOnly.range(
            of: #"cdn\.discordapp\.com/icons/(\d+)/[a-f0-9]+\.(webp|png|gif|jpg)"#,
            options: .regularExpression
        ) {
            let guildId = extractIdFromCDNURL(urlOnly[range], pathSegment: "/icons/")
            if !guildId.isEmpty {
                let size = parseSize(from: urlOnly)
                out.append(.guildIcon(GuildIconRow(
                    guildId: guildId, bytes: entry.body, size: size
                )))
            }
            return
        }

        guard urlOnly.contains("/api/v") else { return }

        // ---- Voice-stream URL: encodes (guildId, channelId) right in the path
        // without us having to parse the body, e.g.
        //   /api/v9/streams/guild%3A<guildId>%3A<channelId>%3A<userId>/preview
        if let m = urlOnly.range(of: #"streams/guild%3A(\d+)%3A(\d+)"#,
                                  options: .regularExpression) {
            // pieces = ["streams/guild", "<guildId>", "<channelId>"]
            let pieces = String(urlOnly[m]).components(separatedBy: "%3A")
            if pieces.count >= 3,
               pieces[1].allSatisfy({ $0.isNumber }),
               pieces[2].allSatisfy({ $0.isNumber }) {
                out.append(.channel(ChannelRow(
                    id: pieces[2], name: "", guildId: pieces[1],
                    recipientId: nil, type: 2
                )))
            }
        }

        // Generic harvest: ANY API response may incidentally embed a guild
        // or channel object (invites, app listings, threads, search results,
        // messages with referenced channels in embeds, ...). Walk the whole
        // JSON tree once and pull anything that looks structurally like a
        // guild or a channel. This is how we recover ~270 guild names that
        // would never appear in the direct guild-list endpoint (which
        // Discord doesn't cache via REST).
        if let obj = try? JSONSerialization.jsonObject(with: entry.body) {
            harvestObjects(in: obj, into: &out)
        }

        if urlOnly.range(of: #"/api/v\d+/users/@me/guilds(\?|$)"#,
                         options: .regularExpression) != nil {
            ingestGuildList(body: entry.body, into: &out)
            return
        }
        if urlOnly.range(of: #"/api/v\d+/users/@me/channels(\?|$)"#,
                         options: .regularExpression) != nil {
            ingestChannelList(body: entry.body, into: &out, defaultGuildId: nil)
            return
        }
        if let m = urlOnly.range(of: #"/api/v\d+/guilds/(\d+)/channels"#,
                                 options: .regularExpression) {
            let guildId = guildIdFromRange(urlOnly, range: m)
            ingestChannelList(body: entry.body, into: &out, defaultGuildId: guildId)
            return
        }
        if let m = urlOnly.range(of: #"/api/v\d+/guilds/(\d+)(\?|$)"#,
                                 options: .regularExpression) {
            let guildId = guildIdFromRange(urlOnly, range: m)
            ingestSingleGuild(body: entry.body, fallbackId: guildId, into: &out)
            return
        }
        if let m = urlOnly.range(of: #"/api/v\d+/channels/(\d+)/messages"#,
                                 options: .regularExpression) {
            let channelId = idFromRange(urlOnly, range: m, prefix: "/channels/", suffix: "/messages")
            ingestMessages(body: entry.body, channelId: channelId, into: &out)
            return
        }
        // Single-channel detail responses are rare in cache (~3 entries on a
        // typical install) but the ones we do have carry guild_id, which
        // lets us link those messages to their parent server.
        if urlOnly.range(of: #"/api/v\d+/channels/\d+(\?|$)"#,
                         options: .regularExpression) != nil {
            ingestSingleChannel(body: entry.body, into: &out)
            return
        }
    }

    nonisolated private static func ingestSingleChannel(
        body: Data, into out: inout [ParsedEndpoint]
    ) {
        guard let c = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        ingestChannel(dict: c, into: &out, defaultGuildId: nil)
    }

    nonisolated private static func guildIdFromRange(_ s: String, range: Range<String.Index>) -> String {
        idFromRange(s, range: range, prefix: "/guilds/", suffix: "/")
    }

    /// Extract the id after a CDN path segment, e.g. given
    /// "cdn.discordapp.com/avatars/12345/abcd.webp" and segment "/avatars/",
    /// returns "12345".
    nonisolated private static func extractIdFromCDNURL(_ s: Substring, pathSegment: String) -> String {
        guard let r = s.range(of: pathSegment) else { return "" }
        var rest = s[r.upperBound...]
        if let endR = rest.firstIndex(of: "/") {
            rest = rest[..<endR]
        }
        return String(rest)
    }

    nonisolated private static func parseSize(from url: String) -> Int {
        guard let r = url.range(of: "size="),
              let endR = url.range(of: "&", range: r.upperBound..<url.endIndex)
                ?? url.range(of: "?", range: r.upperBound..<url.endIndex) else {
            // No trailing delimiter — grab to end
            if let r2 = url.range(of: "size=") {
                let tail = url[r2.upperBound...]
                return Int(tail) ?? 0
            }
            return 0
        }
        return Int(url[r.upperBound..<endR.lowerBound]) ?? 0
    }

    nonisolated private static func idFromRange(
        _ s: String, range: Range<String.Index>, prefix: String, suffix: String
    ) -> String {
        let chunk = String(s[range])
        guard let prefRange = chunk.range(of: prefix) else { return "" }
        var rest = String(chunk[prefRange.upperBound...])
        if let suffRange = rest.range(of: suffix) {
            rest = String(rest[..<suffRange.lowerBound])
        }
        return rest
    }

    nonisolated private static func ingestGuildList(body: Data, into out: inout [ParsedEndpoint]) {
        guard let arr = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return }
        for g in arr {
            guard let id = g["id"] as? String, let name = g["name"] as? String else { continue }
            out.append(.guild(GuildRow(id: id, name: name, iconHash: g["icon"] as? String)))
        }
    }

    nonisolated private static func ingestSingleGuild(
        body: Data, fallbackId: String, into out: inout [ParsedEndpoint]
    ) {
        guard let g = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        let id = (g["id"] as? String) ?? fallbackId
        guard !id.isEmpty, let name = g["name"] as? String else { return }
        out.append(.guild(GuildRow(id: id, name: name, iconHash: g["icon"] as? String)))
    }

    nonisolated private static func ingestChannelList(
        body: Data, into out: inout [ParsedEndpoint], defaultGuildId: String?
    ) {
        guard let arr = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return }
        for c in arr {
            ingestChannel(dict: c, into: &out, defaultGuildId: defaultGuildId)
        }
    }

    nonisolated private static func ingestChannel(
        dict: [String: Any], into out: inout [ParsedEndpoint], defaultGuildId: String?
    ) {
        guard let id = dict["id"] as? String else { return }
        let type    = (dict["type"] as? Int) ?? 0
        let name    = (dict["name"] as? String) ?? ""
        let guildId = (dict["guild_id"] as? String) ?? defaultGuildId

        var recipientId: String?
        if let recipients = dict["recipients"] as? [[String: Any]] {
            for r in recipients {
                if let uid = r["id"] as? String,
                   let username = r["username"] as? String {
                    out.append(.user(UserRow(id: uid, username: username, avatarHash: r["avatar"] as? String)))
                    if recipients.count == 1 { recipientId = uid }
                }
            }
        } else if let rids = dict["recipient_ids"] as? [String], rids.count == 1 {
            recipientId = rids.first
        }

        out.append(.channel(ChannelRow(
            id: id, name: name, guildId: guildId, recipientId: recipientId, type: type
        )))
    }

    /// Recursively walk a JSON tree harvesting embedded guild/channel
    /// objects and ANY co-occurrence of `channel_id` + `guild_id`.
    /// The contextual co-occurrence is what unlocks the vast majority of
    /// channel→guild mappings: Discord embeds `{channel_id, guild_id}`
    /// pairs all over (notifications, mentions, voice states, message
    /// references), even when no full channel object is present.
    ///
    /// We propagate `guild_id` and `channel_id` down the tree so a `guild_id`
    /// at one level can pair with a `channel_id` at a deeper level (mention
    /// objects, etc).
    nonisolated private static func harvestObjects(
        in node: Any,
        parentKey: String? = nil,
        parentGuildId: String? = nil,
        parentChannelId: String? = nil,
        into out: inout [ParsedEndpoint]
    ) {
        if let dict = node as? [String: Any] {
            // Update context with any guild_id / channel_id at THIS level,
            // overriding inherited values.
            var gid = parentGuildId
            var cid = parentChannelId
            if let g = dict["guild_id"] as? String, !g.isEmpty { gid = g }
            if let c = dict["channel_id"] as? String, !c.isEmpty { cid = c }

            // ---- structural detection of full guild/channel objects ----
            if let id = dict["id"] as? String,
               let name = dict["name"] as? String,
               !id.isEmpty, !name.isEmpty {

                let parentSaysGuild   = parentKey == "guild"   || parentKey == "guilds"
                let parentSaysChannel = parentKey == "channel" || parentKey == "channels"

                if looksLikeGuild(dict) || parentSaysGuild {
                    out.append(.guild(GuildRow(
                        id: id, name: name, iconHash: dict["icon"] as? String
                    )))
                } else if let type = dict["type"] as? Int,
                          (looksLikeChannel(type: type, dict: dict) || parentSaysChannel) {
                    out.append(.channel(ChannelRow(
                        id: id, name: name,
                        guildId: dict["guild_id"] as? String ?? gid,
                        recipientId: nil, type: type
                    )))
                } else if parentSaysChannel {
                    out.append(.channel(ChannelRow(
                        id: id, name: name,
                        guildId: dict["guild_id"] as? String ?? gid,
                        recipientId: nil, type: 0
                    )))
                }
            }

            // ---- contextual: emit any (channel_id, guild_id) co-occurrence ----
            // This is the high-yield path — recovers ~170 extra mappings
            // from message embeds, mentions, notifications, etc. The
            // conditional channel upsert preserves existing names; this
            // only fills in missing guild_ids.
            if let cid, let gid {
                out.append(.channel(ChannelRow(
                    id: cid, name: "", guildId: gid,
                    recipientId: nil, type: 0
                )))
            }

            for (k, v) in dict {
                harvestObjects(in: v, parentKey: k,
                               parentGuildId: gid, parentChannelId: cid,
                               into: &out)
            }
        } else if let arr = node as? [Any] {
            for v in arr {
                harvestObjects(in: v, parentKey: parentKey,
                               parentGuildId: parentGuildId,
                               parentChannelId: parentChannelId,
                               into: &out)
            }
        }
    }

    /// Discord guild objects carry these strictly-guild-only fields.
    /// Loose markers like `owner_id` or `splash` also appear on application
    /// and embed objects, leading to false positives like GitHub release
    /// titles being indexed as servers — so we require one of the strict
    /// markers here.
    nonisolated private static func looksLikeGuild(_ dict: [String: Any]) -> Bool {
        // `verification_level` is an int 0–4 unique to guilds.
        // `preferred_locale` is a string locale code unique to guilds.
        // `premium_subscription_count` is unique to guilds (boost count).
        // `vanity_url_code` (even when null) is unique to guilds.
        if dict["verification_level"] is Int { return true }
        if dict["preferred_locale"] is String { return true }
        if dict["premium_subscription_count"] is Int { return true }
        if dict.keys.contains("vanity_url_code") { return true }
        // `system_channel_id` and `afk_channel_id` only exist on guild objects.
        if dict.keys.contains("system_channel_id") { return true }
        if dict.keys.contains("afk_channel_id") { return true }
        return false
    }

    /// Channel `type` values we care about for search context:
    ///   0  GUILD_TEXT, 2 GUILD_VOICE, 4 GUILD_CATEGORY, 5 GUILD_ANNOUNCEMENT,
    ///   13 GUILD_STAGE_VOICE, 15 GUILD_FORUM, 16 GUILD_MEDIA.
    /// DMs (1) and group DMs (3) we already learn from messages.
    nonisolated private static func looksLikeChannel(type: Int, dict: [String: Any]) -> Bool {
        guard [0, 2, 4, 5, 13, 15, 16].contains(type) else { return false }
        // Skip orphan items that just happen to have a numeric `type` — we
        // want some genuinely channel-shape signal. Any of these is OK:
        // a position int (channels in a list are positioned), a parent_id
        // (subchannels), a guild_id, an nsfw bool, a topic, or rate-limit.
        return dict["position"] is Int
            || dict["parent_id"] != nil
            || dict["guild_id"] != nil
            || dict["nsfw"] is Bool
            || dict["topic"] != nil
            || dict["rate_limit_per_user"] is Int
            || dict["last_message_id"] != nil
    }

    nonisolated private static func ingestMessages(
        body: Data, channelId: String, into out: inout [ParsedEndpoint]
    ) {
        guard let arr = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for m in arr {
            guard let id = m["id"] as? String,
                  let content = m["content"] as? String,
                  !content.isEmpty else { continue }

            var authorId = ""
            if let author = m["author"] as? [String: Any] {
                if let aid = author["id"] as? String { authorId = aid }
                if let aid = author["id"] as? String,
                   let username = author["username"] as? String {
                    out.append(.user(UserRow(
                        id: aid, username: username, avatarHash: author["avatar"] as? String
                    )))
                }
            }

            let timestamp: Date = {
                guard let s = m["timestamp"] as? String,
                      let d = iso.date(from: s) else { return .distantPast }
                return d
            }()

            out.append(.message(MessageRow(
                id: id, channelId: channelId, authorId: authorId,
                content: content, timestamp: timestamp
            )))
        }
    }
}
