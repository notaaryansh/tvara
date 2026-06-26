import Foundation
import SQLite3

private let SQLITE_TRANSIENT_NN = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read pages directly from Notion.app's local SQLite cache at
/// `~/Library/Application Support/Notion/notion.db`. Zero setup — as long
/// as the user has Notion.app installed and signed in, this just works.
///
/// The `block` table stores every page/heading/paragraph in the user's
/// workspaces. We filter to top-level pages (type='page' or
/// 'collection_view_page') and pull the title out of the `properties`
/// JSON column. The id (with dashes) becomes a `notion://` deep link that
/// the desktop app intercepts.
///
/// Notion writes to this db constantly, so we copy to /tmp before reading
/// to avoid lock contention (same pattern as WhatsAppService).
actor NotionService {
    private let dbPath: String

    init() {
        self.dbPath = NSHomeDirectory()
            + "/Library/Application Support/Notion/notion.db"
    }

    /// Cheap to call repeatedly. We open per-search rather than holding a
    /// long-lived handle because Notion writes to this file constantly and
    /// a stale handle would miss new pages.
    func warmCache() async {
        _ = try? Data(contentsOf: URL(fileURLWithPath: dbPath), options: [.mappedIfSafe])
    }

    func search(query: String, limit: Int = 12) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        // Snapshot the db to avoid contending with the Notion app's writes.
        let tmp = NSTemporaryDirectory()
            + "spotlight_notion_\(UUID().uuidString).db"
        do {
            try FileManager.default.copyItem(atPath: dbPath, toPath: tmp)
        } catch {
            return []   // TCC denied or read failed
        }
        for suffix in ["-wal", "-shm"] {
            let src = dbPath + suffix
            if FileManager.default.fileExists(atPath: src) {
                try? FileManager.default.copyItem(atPath: src, toPath: tmp + suffix)
            }
        }
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: tmp + suffix)
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else { return [] }
        defer { sqlite3_close(db) }

        // Tokenize the needle so we can do per-word matching. "project
        // tracker" splits into ["project", "tracker"] — either word in a
        // title makes the page eligible, and the more words that match,
        // the higher the rank. This is what lets "project tracker" surface
        // "Progress Tracker" (1 word matches) and "Project Template" (1
        // word matches) alongside any literal "project tracker" hit (2).
        let tokens = trimmed
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0).lowercased() }
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return [] }

        let likeClauses = Array(repeating: "properties LIKE ? COLLATE NOCASE",
                                count: tokens.count).joined(separator: " OR ")
        let sql = """
            SELECT id, properties, last_edited_time
            FROM block
            WHERE type IN ('page', 'collection_view_page')
              AND alive = 1
              AND properties IS NOT NULL
              AND (\(likeClauses))
            LIMIT 200
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        for (i, token) in tokens.enumerated() {
            let pattern = "%\(token)%"
            sqlite3_bind_text(stmt, Int32(i + 1), pattern, -1, SQLITE_TRANSIENT_NN)
        }

        let icon = SourceAppIcons.iconData(for: .notion)
        var out: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id    = colText(stmt, 0)
            let props = colText(stmt, 1)
            let editedMs = sqlite3_column_double(stmt, 2)

            guard let title = Self.extractTitle(propertiesJSON: props),
                  !title.isEmpty
            else { continue }

            // Count how many of the needle's tokens appear in this title.
            // Reject titles where zero tokens match (false positives from
            // the LIKE matching JSON keys/values that aren't in the title).
            let titleLower = title.lowercased()
            let matched = tokens.filter { titleLower.contains($0) }.count
            guard matched > 0 else { continue }

            let editedDate = editedMs > 0
                ? Date(timeIntervalSince1970: editedMs / 1000.0)
                : nil
            let url = Self.deepLink(forBlockId: id)

            let rank = Self.rankFor(
                title: title, tokens: tokens, matched: matched, edited: editedDate
            )
            out.append(SearchResult(
                title: title,
                subtitle: "Open in Notion",
                source: .notion,
                date: editedDate,
                badge: nil,
                openTarget: .url(url),
                rank: rank,
                iconData: icon
            ))
        }
        // Sort by rank (highest first), keep top `limit`.
        return Array(out.sorted { $0.rank > $1.rank }.prefix(limit))
    }

    // MARK: - Title parsing

    /// Notion serializes a page's title as `{"title":[[ "Customer Call" ]]}`
    /// with optional rich-text decoration. The first inner array element is
    /// always the plain text — we collect those across all fragments to get
    /// the full visible title.
    nonisolated private static func extractTitle(propertiesJSON: String) -> String? {
        guard let data = propertiesJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // properties is a dict; the title lives under "title" for blocks of
        // type='page'. Some databases use a different key — fall back to
        // any value that looks title-shaped.
        let titleValue: Any? = json["title"] ?? json.values.first(where: { v in
            (v as? [[Any]])?.first is [Any]
        })
        guard let fragments = titleValue as? [[Any]] else { return nil }

        var pieces: [String] = []
        for frag in fragments {
            guard let first = frag.first else { continue }
            // Plain text fragments are just `["text"]`.
            // Mention/date fragments are `["‣", [["m", ...]]]` — we replace
            // those with a placeholder so the title isn't blank.
            if let text = first as? String {
                if text == "‣" {
                    pieces.append("(mention)")
                } else {
                    pieces.append(text)
                }
            }
        }
        return pieces.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the notion:// deep link for a block id. Notion accepts the id
    /// either dashed or undashed; we drop the dashes for the shortest URL.
    nonisolated private static func deepLink(forBlockId id: String) -> String {
        let undashed = id.replacingOccurrences(of: "-", with: "")
        return "notion://www.notion.so/\(undashed)"
    }

    /// Token-count match: titles that contain MORE of the needle's words
    /// rank higher. Bonus for the literal needle as a substring, plus a
    /// small recency boost. Range roughly 200–800.
    nonisolated private static func rankFor(
        title: String, tokens: [String], matched: Int, edited: Date?
    ) -> Int {
        let t = title.lowercased()
        let needle = tokens.joined(separator: " ")
        // 150 points per matched token: 1 word → 150, 2 → 300, etc.
        let tokenScore = matched * 150
        // Bonus when the literal phrase appears in the title — beats
        // titles that just happen to contain the same words separately.
        let substringBonus = t.contains(needle) ? 200 : 0
        // Bigger bonus for exact match.
        let exactBonus = (t == needle) ? 200 : 0
        let recency: Int = {
            guard let edited else { return 0 }
            let days = Date().timeIntervalSince(edited) / 86_400
            if days < 7   { return 40 }
            if days < 30  { return 20 }
            if days < 180 { return 8 }
            return 0
        }()
        return tokenScore + substringBonus + exactBonus + recency
    }

    // MARK: - SQLite helpers

    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: p)
    }
}
