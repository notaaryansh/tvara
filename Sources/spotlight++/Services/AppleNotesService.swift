import Foundation
import SQLite3

private let SQLITE_TRANSIENT_NT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only search over Apple Notes via the Core Data SQLite store at
/// `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`.
///
/// We search title and snippet (the plain-text preview the Notes app stores
/// alongside each note). The full body is gzipped protobuf in ZICNOTEDATA
/// and would need a heavier parser — out of scope for v1. Title+snippet
/// covers most real searches because the user usually remembers a phrase
/// from the top of the note.
///
/// Requires Full Disk Access (the Notes group container is TCC-protected).
actor AppleNotesService {
    private let dbPath: String

    init() {
        self.dbPath = NSHomeDirectory()
            + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    }

    /// Touch the file so macOS fires the FDA prompt at launch (rather than
    /// silently denying inside `search`). Fails open on missing/denied.
    func warmCache() async {
        _ = try? Data(contentsOf: URL(fileURLWithPath: dbPath), options: [.mappedIfSafe])
    }

    func search(query: String, limit: Int = 25) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        // Notes can be actively writing to its SQLite; copy db + WAL/SHM to
        // a temp path so our read doesn't conflict with the app's locks.
        let tmp = NSTemporaryDirectory()
            + "spotlight_notes_\(UUID().uuidString).sqlite"
        do {
            try FileManager.default.copyItem(atPath: dbPath, toPath: tmp)
        } catch {
            return []
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
        guard sqlite3_open_v2(tmp, &db,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else { return [] }
        defer { sqlite3_close(db) }

        // Notes vs folders both live in ZICCLOUDSYNCINGOBJECT. Notes have a
        // non-null ZTITLE1 and a foreign key to ZICNOTEDATA; folders don't.
        // Filtering on ZNOTEDATA IS NOT NULL excludes folders cleanly without
        // having to look up the entity-type table.
        let sql = """
            SELECT ZTITLE1, ZSNIPPET, ZIDENTIFIER, ZMODIFICATIONDATE1
            FROM ZICCLOUDSYNCINGOBJECT
            WHERE ZNOTEDATA IS NOT NULL
              AND ZTITLE1 IS NOT NULL
              AND (ZTITLE1 LIKE ? COLLATE NOCASE OR ZSNIPPET LIKE ? COLLATE NOCASE)
            ORDER BY
              CASE WHEN ZTITLE1 LIKE ? COLLATE NOCASE THEN 0 ELSE 1 END,
              ZMODIFICATIONDATE1 DESC
            LIMIT \(limit)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(trimmed)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT_NT)
        sqlite3_bind_text(stmt, 2, pattern, -1, SQLITE_TRANSIENT_NT)
        sqlite3_bind_text(stmt, 3, pattern, -1, SQLITE_TRANSIENT_NT)

        let queryLower = trimmed.lowercased()
        var out: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let title   = colText(stmt, 0)
            let snippet = colTextOptional(stmt, 1) ?? ""
            // Core Data Mac absolute time: seconds since 2001-01-01.
            let zts     = sqlite3_column_double(stmt, 3)
            let date    = zts > 0 ? Date(timeIntervalSinceReferenceDate: zts) : nil

            // Title match wins the rank tie-breaker. Otherwise rank by recency.
            let titleHit = title.lowercased().contains(queryLower)
            let snippetHit = snippet.lowercased().contains(queryLower)
            let rank: Int = {
                if titleHit { return 250 }
                if snippetHit { return 130 }
                return 80
            }()

            out.append(SearchResult(
                title: title.isEmpty ? "(untitled note)" : title,
                subtitle: snippet,
                source: .notes,
                date: date,
                badge: nil,
                openTarget: .notesNote(title: title),
                rank: rank
            ))
        }
        return out
    }

    // MARK: - Helpers

    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: p)
    }

    private func colTextOptional(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: p)
    }
}
