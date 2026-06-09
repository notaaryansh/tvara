import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor BrowserDatabaseService {
    private struct Source {
        let kind: SearchResult.Source
        let historyRelPath: String
        let faviconsRelPath: String
    }

    private let sources: [Source] = [
        Source(kind: .chrome,
               historyRelPath:  "Library/Application Support/Google/Chrome/Default/History",
               faviconsRelPath: "Library/Application Support/Google/Chrome/Default/Favicons"),
        Source(kind: .arc,
               historyRelPath:  "Library/Application Support/Arc/User Data/Default/History",
               faviconsRelPath: "Library/Application Support/Arc/User Data/Default/Favicons"),
        Source(kind: .brave,
               historyRelPath:  "Library/Application Support/BraveSoftware/Brave-Browser/Default/History",
               faviconsRelPath: "Library/Application Support/BraveSoftware/Brave-Browser/Default/Favicons"),
        Source(kind: .edge,
               historyRelPath:  "Library/Application Support/Microsoft Edge/Default/History",
               faviconsRelPath: "Library/Application Support/Microsoft Edge/Default/Favicons"),
    ]

    func search(query: String, limit: Int = 40) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var all: [SearchResult] = []

        for source in sources {
            let historyPath = (home as NSString).appendingPathComponent(source.historyRelPath)
            guard FileManager.default.fileExists(atPath: historyPath) else { continue }

            let faviconPath = (home as NSString).appendingPathComponent(source.faviconsRelPath)
            let faviconExists = FileManager.default.fileExists(atPath: faviconPath)

            let tmpHistory  = NSTemporaryDirectory()
                + "spotlight_\(source.kind.rawValue.lowercased())_\(UUID().uuidString)_h.db"
            let tmpFavicons = NSTemporaryDirectory()
                + "spotlight_\(source.kind.rawValue.lowercased())_\(UUID().uuidString)_f.db"

            do {
                try FileManager.default.copyItem(atPath: historyPath, toPath: tmpHistory)
                defer { try? FileManager.default.removeItem(atPath: tmpHistory) }

                var faviconAttachPath: String?
                if faviconExists {
                    if (try? FileManager.default.copyItem(atPath: faviconPath, toPath: tmpFavicons)) != nil {
                        faviconAttachPath = tmpFavicons
                    }
                }
                defer {
                    if faviconAttachPath != nil {
                        try? FileManager.default.removeItem(atPath: tmpFavicons)
                    }
                }

                all.append(contentsOf: querySQLite(
                    historyPath: tmpHistory,
                    faviconPath: faviconAttachPath,
                    query: trimmed,
                    limit: limit,
                    source: source.kind
                ))
            } catch {
                continue
            }
        }

        all.sort { a, b in
            if a.rank != b.rank { return a.rank > b.rank }
            return (a.date ?? .distantPast) > (b.date ?? .distantPast)
        }
        return Array(all.prefix(limit))
    }

    private func querySQLite(
        historyPath: String,
        faviconPath: String?,
        query: String,
        limit: Int,
        source: SearchResult.Source
    ) -> [SearchResult] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(historyPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        let hasFavicons = attachFaviconsIfPossible(db: db, path: faviconPath)

        let sql: String
        if hasFavicons {
            sql = """
                SELECT u.url, u.title, u.visit_count, u.last_visit_time,
                       (SELECT fb.image_data
                        FROM fav.icon_mapping im
                        JOIN fav.favicon_bitmaps fb ON fb.icon_id = im.icon_id
                        WHERE im.page_url = u.url
                        ORDER BY (fb.width * fb.height) DESC
                        LIMIT 1) AS favicon_data
                FROM urls u
                WHERE u.title LIKE ? OR u.url LIKE ?
                ORDER BY u.visit_count DESC, u.last_visit_time DESC
                LIMIT \(limit)
            """
        } else {
            sql = """
                SELECT url, title, visit_count, last_visit_time, NULL
                FROM urls
                WHERE title LIKE ? OR url LIKE ?
                ORDER BY visit_count DESC, last_visit_time DESC
                LIMIT \(limit)
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(query)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, pattern, -1, SQLITE_TRANSIENT)

        var results: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let url    = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let title  = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let visits = Int(sqlite3_column_int(stmt, 2))
            let chromeTime = sqlite3_column_int64(stmt, 3)

            guard !url.isEmpty else { continue }

            var iconData: Data?
            if sqlite3_column_type(stmt, 4) == SQLITE_BLOB,
               let bytes = sqlite3_column_blob(stmt, 4) {
                let len = sqlite3_column_bytes(stmt, 4)
                if len > 0 {
                    iconData = Data(bytes: bytes, count: Int(len))
                }
            }

            results.append(SearchResult(
                title: title,
                subtitle: url,
                source: source,
                date: Self.chromeTimeToDate(chromeTime),
                badge: visits > 0 ? "\(visits) visit\(visits == 1 ? "" : "s")" : nil,
                openTarget: .url(url),
                rank: min(visits, 500),
                iconData: iconData
            ))
        }
        return results
    }

    private func attachFaviconsIfPossible(db: OpaquePointer?, path: String?) -> Bool {
        guard let path else { return false }
        // sqlite3_exec with quoted path; escape any single quotes in the path.
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        let sql = "ATTACH DATABASE '\(escaped)' AS fav"
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func chromeTimeToDate(_ chromeTime: Int64) -> Date? {
        guard chromeTime > 0 else { return nil }
        let seconds = Double(chromeTime) / 1_000_000 - 11_644_473_600
        return Date(timeIntervalSince1970: seconds)
    }
}
