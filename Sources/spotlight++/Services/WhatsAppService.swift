import Foundation
import SQLite3

private let SQLITE_TRANSIENT_WA = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor WhatsAppService {
    private let dbPath: String
    private let profilePicDir: String

    init() {
        let groupContainer = NSHomeDirectory()
            + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
        self.dbPath = groupContainer + "/ChatStorage.sqlite"
        self.profilePicDir = groupContainer + "/Media/Profile"
    }

    func search(query: String, limit: Int = 30) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Don't fire on 1-char queries — too broad, and LIKE '%a%' would
        // scan the whole table for negligible value.
        guard trimmed.count >= 2 else { return [] }
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        // Copy the main db + WAL/SHM together so a write in flight at copy
        // time doesn't corrupt the snapshot we read.
        let tmpDb  = NSTemporaryDirectory() + "spotlight_wa_\(UUID().uuidString).sqlite"
        let tmpWal = tmpDb + "-wal"
        let tmpShm = tmpDb + "-shm"

        do {
            try FileManager.default.copyItem(atPath: dbPath, toPath: tmpDb)
        } catch {
            return []
        }
        if FileManager.default.fileExists(atPath: dbPath + "-wal") {
            try? FileManager.default.copyItem(atPath: dbPath + "-wal", toPath: tmpWal)
        }
        if FileManager.default.fileExists(atPath: dbPath + "-shm") {
            try? FileManager.default.copyItem(atPath: dbPath + "-shm", toPath: tmpShm)
        }
        defer {
            try? FileManager.default.removeItem(atPath: tmpDb)
            try? FileManager.default.removeItem(atPath: tmpWal)
            try? FileManager.default.removeItem(atPath: tmpShm)
        }

        let avatarIndex = buildAvatarIndex()
        return querySQLite(path: tmpDb, query: trimmed, limit: limit, avatarIndex: avatarIndex)
    }

    /// Builds a `<localPart> -> bestFilePath` map once per search by listing
    /// the Profile dir. Avoids hitting the filesystem per result.
    private func buildAvatarIndex() -> [String: String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: profilePicDir) else {
            return [:]
        }
        var index: [String: (path: String, isFull: Bool)] = [:]
        for name in entries {
            // Filename format: <localPart>-<pictureId>.{thumb|jpg}
            let isThumb = name.hasSuffix(".thumb")
            let isJpg   = name.hasSuffix(".jpg")
            guard isThumb || isJpg else { continue }
            guard let dash = name.firstIndex(of: "-") else { continue }
            let localPart = String(name[..<dash])
            guard !localPart.isEmpty else { continue }

            let path = profilePicDir + "/" + name
            // Prefer full-size .jpg over .thumb when both exist.
            if let existing = index[localPart], existing.isFull, isThumb { continue }
            index[localPart] = (path, isJpg)
        }
        return index.mapValues { $0.path }
    }

    private func querySQLite(
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
            let text         = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let coreDataTime = sqlite3_column_double(stmt, 1)
            let isFromMe     = sqlite3_column_int(stmt, 2) == 1
            let partner      = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let jid          = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let sessionType  = Int(sqlite3_column_int(stmt, 5))

            guard !text.isEmpty else { continue }

            let date = Date(timeIntervalSinceReferenceDate: coreDataTime)
            let chatName = displayName(partner: partner, jid: jid, sessionType: sessionType)
            let snippet  = collapseWhitespace(text)

            // Newer messages rank higher. Base 60 puts WhatsApp matches
            // roughly on par with mid-visit-count URLs.
            let days = max(0, now.timeIntervalSince(date) / 86_400)
            let recency = max(0, 80 - Int(days / 3))   // ~80 for today, decays slowly
            let rank = 60 + recency

            let avatarData = Self.loadAvatar(forJid: jid, avatarIndex: avatarIndex)

            results.append(SearchResult(
                title: chatName,
                subtitle: snippet,
                source: .whatsapp,
                date: date,
                badge: isFromMe ? "you" : nil,
                openTarget: .whatsappChat(jid: jid, messageText: text),
                rank: rank,
                iconData: avatarData
            ))
        }
        return results
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

    private static func loadAvatar(forJid jid: String, avatarIndex: [String: String]) -> Data? {
        guard let at = jid.firstIndex(of: "@") else { return nil }
        let localPart = String(jid[..<at])
        guard !localPart.isEmpty,
              let path = avatarIndex[localPart] else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}
