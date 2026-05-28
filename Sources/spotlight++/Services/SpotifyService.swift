import Foundation
import SQLite3

private let SQLITE_TRANSIENT_SP = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Reads the synced Spotify library (playlists / albums / artists) from
/// `spotify_index.db` — populated by `scripts/sync_spotify.py` which mines
/// Spotify.app's local LevelDB cache. Zero user setup: as long as Spotify
/// is installed and the user has launched it (so the LDB exists), this
/// service surfaces real items by name with their cover artwork.
///
/// Click handling:
///   - Album / playlist  → AppleScript "play track <uri>" with shuffle on
///   - Artist            → AppleScript plays the artist (Spotify resolves
///                         this to top tracks / artist radio)
actor SpotifyService {
    private static let appPath  = "/Applications/Spotify.app"
    private static let dbPath   = NSHomeDirectory()
        + "/Library/Application Support/spotlight++/spotify_index.db"
    private static let syncScript = "scripts/sync_spotify.py"

    private var db: OpaquePointer?

    init() {
        var handle: OpaquePointer?
        if sqlite3_open_v2(Self.dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            self.db = handle
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// Re-open the DB on warm (in case the Python sync has run since launch
    /// and the file is newer). Triggers a background sync if the index is
    /// stale or missing.
    func warmCache() async {
        if let db { sqlite3_close(db) }
        var handle: OpaquePointer?
        if sqlite3_open_v2(Self.dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            self.db = handle
        }
        // Kick off a background sync. Non-blocking — the script takes ~10s
        // but we don't wait. Next search after it finishes picks up fresh data.
        await Self.runSyncInBackground()
    }

    func search(query: String, limit: Int = 8) async -> [SearchResult] {
        guard FileManager.default.fileExists(atPath: Self.appPath) else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Empty needle still returns the most-recent items so "spotify"
        // alone surfaces something useful.
        let pattern = trimmed.isEmpty ? "%" : "%\(trimmed)%"
        guard let db else { return [] }

        // Query: prioritize playlists > albums > artists (so user-named
        // playlists land above generic catalog matches). Tie-break by
        // whether name starts with the needle, then by name length asc
        // (shorter, exact-fit matches first).
        let sql = """
            SELECT kind, id, name, art_hash,
                CASE
                    WHEN name LIKE ? COLLATE NOCASE THEN 0   -- prefix match
                    ELSE 1
                END AS prefix_match
            FROM items
            WHERE name LIKE ? COLLATE NOCASE
            ORDER BY
                CASE kind
                    WHEN 'playlist' THEN 0
                    WHEN 'album'    THEN 1
                    WHEN 'artist'   THEN 2
                    ELSE 3
                END,
                prefix_match ASC,
                length(name) ASC
            LIMIT \(limit * 3)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let prefixPat = trimmed.isEmpty ? "%" : "\(trimmed)%"
        sqlite3_bind_text(stmt, 1, prefixPat, -1, SQLITE_TRANSIENT_SP)
        sqlite3_bind_text(stmt, 2, pattern,   -1, SQLITE_TRANSIENT_SP)

        var rows: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind     = colText(stmt, 0)
            let id       = colText(stmt, 1)
            let name     = colText(stmt, 2)
            let artHash  = colTextOptional(stmt, 3)
            let isPrefix = sqlite3_column_int(stmt, 4) == 0

            let uri = "spotify:\(kind):\(id)"
            let artURL = artHash.map { "https://i.scdn.co/image/\($0)" }
            let subtitle = Self.subtitleFor(kind: kind, prefix: isPrefix)

            // Rank: playlist > album > artist; prefix > contains.
            let kindBoost: Int = (kind == "playlist") ? 200
                : (kind == "album") ? 120
                : 80
            let prefixBoost = isPrefix ? 80 : 0
            rows.append(SearchResult(
                title: name,
                subtitle: subtitle,
                source: .spotify,
                date: nil,
                badge: kind.capitalized,
                openTarget: .spotifyPlay(uri: uri, shuffle: true),
                rank: 600 + kindBoost + prefixBoost,
                iconData: nil,
                senderName: nil,
                remoteArtURL: artURL
            ))
            if rows.count >= limit { break }
        }
        return rows
    }

    // MARK: - Helpers

    private static func subtitleFor(kind: String, prefix: Bool) -> String {
        switch kind {
        case "playlist": return "Spotify · Play playlist · shuffle"
        case "album":    return "Spotify · Play album · shuffle"
        case "artist":   return "Spotify · Play artist"
        default:         return "Spotify"
        }
    }

    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: p)
    }

    private func colTextOptional(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, idx) else { return nil }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }

    // MARK: - Background sync

    /// Run `python3 scripts/sync_spotify.py` in the background so the
    /// index stays fresh. Searches the project root (working dir when
    /// running from `swift run` / Xcode) and the bundle's parent dir
    /// (when running the bundled .app from ~/Documents/GitHub/...).
    nonisolated private static func runSyncInBackground() async {
        guard let scriptPath = findSyncScript() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptPath]
        // Discard stdout/stderr — we don't want to block on pipes.
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
        try? process.run()
        // Intentionally not awaiting — the script runs ~10s and we want
        // the launcher to be responsive immediately.
    }

    nonisolated private static func findSyncScript() -> String? {
        let candidates = [
            FileManager.default.currentDirectoryPath + "/" + syncScript,
            Bundle.main.bundleURL.deletingLastPathComponent().path + "/" + syncScript,
            // ~/Documents/GitHub/spotlight++/scripts/sync_spotify.py — known
            // dev path; remove for distributable builds.
            NSHomeDirectory() + "/Documents/GitHub/spotlight++/" + syncScript,
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return nil
    }
}
