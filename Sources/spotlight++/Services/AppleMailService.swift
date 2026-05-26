import Foundation
import SQLite3

private let SQLITE_TRANSIENT_ML = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor AppleMailService {
    /// Resolved at runtime to whichever `~/Library/Mail/V*/MailData/Envelope Index`
    /// exists. Nil if Mail isn't set up on this Mac.
    private var resolvedDbPath: String?
    private let mailBase: String

    init() {
        self.mailBase = NSHomeDirectory() + "/Library/Mail"
        self.resolvedDbPath = Self.locateEnvelopeIndex(under: NSHomeDirectory() + "/Library/Mail")
    }

    func isPermissionDenied() -> Bool {
        // We may have a cached path; re-check it's still readable.
        if let p = resolvedDbPath {
            if !FileManager.default.fileExists(atPath: p) { return false }
            return !FileManager.default.isReadableFile(atPath: p)
        }
        // No path resolved either because Mail isn't set up OR because we
        // couldn't even enumerate the Mail directory due to TCC.
        return !FileManager.default.isReadableFile(atPath: mailBase)
    }

    func search(query: String, limit: Int = 30) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }

        // Re-resolve in case Mail wasn't ready at init time.
        if resolvedDbPath == nil {
            resolvedDbPath = Self.locateEnvelopeIndex(under: mailBase)
        }
        guard let dbPath = resolvedDbPath else { return [] }
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        // Mail's Envelope Index is sometimes opened with WAL; copy siblings too.
        let tmpDb  = NSTemporaryDirectory() + "spotlight_mail_\(UUID().uuidString).db"
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

        return querySQL(path: tmpDb, query: trimmed, limit: limit)
    }

    // MARK: - SQL

    private func querySQL(path: String, query: String, limit: Int) -> [SearchResult] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        // Envelope Index uses deduped subjects + addresses tables.
        // Match against subject, sender address, and sender display name.
        let sql = """
            SELECT
                m.ROWID,
                m.message_id,
                s.subject,
                a.address,
                a.comment,
                m.date_received
            FROM messages m
            LEFT JOIN subjects s  ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            WHERE m.message_id IS NOT NULL
              AND ( s.subject LIKE ? COLLATE NOCASE
                 OR a.address LIKE ? COLLATE NOCASE
                 OR a.comment LIKE ? COLLATE NOCASE )
            ORDER BY m.date_received DESC
            LIMIT \(limit)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(query)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT_ML)
        sqlite3_bind_text(stmt, 2, pattern, -1, SQLITE_TRANSIENT_ML)
        sqlite3_bind_text(stmt, 3, pattern, -1, SQLITE_TRANSIENT_ML)

        let now = Date()
        var out: [SearchResult] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId = colTextOptional(stmt, 1) ?? ""
            let subject   = colTextOptional(stmt, 2) ?? "(no subject)"
            let senderAddr = colTextOptional(stmt, 3) ?? ""
            let senderName = colTextOptional(stmt, 4) ?? ""
            let dateRaw   = sqlite3_column_int64(stmt, 5)

            guard !messageId.isEmpty else { continue }

            let date = Date(timeIntervalSince1970: TimeInterval(dateRaw))
            let title = senderName.isEmpty ? senderAddr : senderName
            let subtitle = subject

            // message:// URL scheme expects the Message-ID with angle
            // brackets, URL-encoded. Envelope Index stores the bare value.
            let encoded = "<\(messageId)>".addingPercentEncoding(
                withAllowedCharacters: .urlHostAllowed
            ) ?? messageId
            let openURL = "message://\(encoded)"

            let days = max(0, now.timeIntervalSince(date) / 86_400)
            let rank = 60 + max(0, 80 - Int(days / 3))

            out.append(SearchResult(
                title: title.isEmpty ? "(unknown sender)" : title,
                subtitle: subtitle,
                source: .mail,
                date: date,
                badge: senderAddr.isEmpty ? nil : senderAddr,
                openTarget: .url(openURL),
                rank: rank
            ))
        }
        return out
    }

    // MARK: - Path resolution

    private static func locateEnvelopeIndex(under base: String) -> String? {
        // Find the highest-versioned MailData/Envelope Index path.
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            return nil
        }
        let versionDirs = entries.filter { $0.hasPrefix("V") && Int($0.dropFirst()) != nil }
        let sorted = versionDirs.sorted { (a, b) in
            (Int(a.dropFirst()) ?? 0) > (Int(b.dropFirst()) ?? 0)
        }
        for v in sorted {
            let candidate = "\(base)/\(v)/MailData/Envelope Index"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func colTextOptional(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: p)
    }
}
