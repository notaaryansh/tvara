import Foundation

actor AppSearchService {
    struct AppEntry: Sendable {
        let name: String
        let path: String
    }

    private var cache: [AppEntry] = []
    private var cacheTime: Date?
    private static let cacheLifetime: TimeInterval = 300   // 5 min

    func warmCache() async {
        await refreshCacheIfNeeded()
    }

    /// True when the typed query equals one installed app's name exactly
    /// (case-insensitive). Used by SearchViewModel's command/content
    /// exclusivity rule. Strict equality only — prefix matches keep
    /// content visible until the user has committed to a full app name.
    func hasExactNameMatch(query: String) async -> Bool {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return false }
        await refreshCacheIfNeeded()
        return cache.contains { $0.name.lowercased() == normalized }
    }

    func search(query: String, limit: Int = 20) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        await refreshCacheIfNeeded()

        let q = trimmed.lowercased()
        var scored: [(AppEntry, Int)] = []
        scored.reserveCapacity(cache.count / 4)

        for app in cache {
            let nameLower = app.name.lowercased()
            let rank: Int
            // Tier hierarchy:
            //   1500 — full name equals query exactly ("notion" → Notion.app)
            //   1300 — query equals a WORD inside the name ("chrome" → Google Chrome,
            //          "code" → Visual Studio Code). This sits above file/folder
            //          exact-name matches (~430) so the app wins over a node_modules
            //          folder that happens to share the name.
            //    500 — full name has the query as a prefix
            //    380 — any word in the name has the query as a prefix
            //    220 — name contains the query as a substring
            if nameLower == q                       { rank = 1500 }
            else if wordEqualMatch(nameLower, q)    { rank = 1300 }
            else if nameLower.hasPrefix(q)          { rank = 500 }
            else if wordPrefixMatch(nameLower, q)   { rank = 380 }
            else if nameLower.contains(q)           { rank = 220 }
            else { continue }
            scored.append((app, rank))
        }

        // Fuzzy fallback for typos like "spottify" → Spotify, "noton" →
        // Notion. Only fires when prefix / word-prefix / contains all
        // returned zero — so it doesn't fight cleanly-typed queries.
        // Same per-character Levenshtein + length-based budget as the
        // command services use.
        if scored.isEmpty {
            let budget = FuzzyMatch.budget(for: q)
            if budget > 0 {
                var fuzzy: [(AppEntry, Int)] = []
                for app in cache {
                    let nameLower = app.name.lowercased()
                    if let dist = FuzzyMatch.levenshtein(
                        q, nameLower, budget: budget
                    ) {
                        fuzzy.append((app, dist))
                    }
                }
                // Closest typos first; tie-break by name alphabetical.
                fuzzy.sort { a, b in
                    if a.1 != b.1 { return a.1 < b.1 }
                    return a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
                }
                return fuzzy.prefix(limit).map { (app, _) in
                    SearchResult(
                        title: app.name,
                        subtitle: abbreviate(app.path),
                        source: .app,
                        date: nil,
                        badge: nil,
                        openTarget: .file(app.path),
                        // Fuzzy matches are GUESSES — they must rank below
                        // exact matches from any other source. Sits below
                        // FileSearchService's exact-filename match (~430)
                        // and below app prefix matches (500). Still shows
                        // up when no exact/prefix match exists anywhere.
                        rank: 280,
                        isFuzzyMatch: true
                    )
                }
            }
        }

        scored.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
        }

        return scored.prefix(limit).map { (app, rank) in
            SearchResult(
                title: app.name,
                subtitle: abbreviate(app.path),
                source: .app,
                date: nil,
                badge: nil,
                openTarget: .file(app.path),
                rank: rank
            )
        }
    }

    private func refreshCacheIfNeeded() async {
        if let t = cacheTime, Date().timeIntervalSince(t) < Self.cacheLifetime, !cache.isEmpty {
            return
        }
        cache = await Task.detached(priority: .userInitiated) {
            Self.scanInstalledApps()
        }.value
        cacheTime = Date()
    }

    // MARK: - Helpers

    private nonisolated func wordPrefixMatch(_ name: String, _ query: String) -> Bool {
        // Match queries against word boundaries, e.g. "settings" → "System Settings".
        for token in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if token.lowercased().hasPrefix(query) { return true }
        }
        return false
    }

    /// True when any whitespace-separated word in the app name equals the
    /// query exactly (case-insensitive). Catches "chrome" → "Google Chrome"
    /// and "code" → "Visual Studio Code" — the user clearly means the app,
    /// not a similarly-named folder.
    private nonisolated func wordEqualMatch(_ name: String, _ query: String) -> Bool {
        for token in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if token.lowercased() == query { return true }
        }
        return false
    }

    private nonisolated func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Scan

    /// Enumerate `.app` bundles in the standard install locations using
    /// FileManager. We used to shell out to `mdfind`, but Spotlight's
    /// metadata index silently misses some apps (notably WhatsApp after
    /// reinstall) — `mdls` returns "could not find" and the bundle never
    /// makes it into our cache even though it's plainly on disk.
    ///
    /// FileManager doesn't depend on the metadata index, so it sees every
    /// `.app` directory that actually exists. Cost: ~30 ms cold on a
    /// machine with ~250 apps; warm-cache amortizes that across all
    /// subsequent queries.
    nonisolated private static func scanInstalledApps() -> [AppEntry] {
        var entries: [AppEntry] = []
        var seen = Set<String>()

        for root in appRoots {
            scan(directory: root, depth: 0, into: &entries, seen: &seen)
        }
        return entries
    }

    /// Standard locations to walk. Each is non-recursive at this level —
    /// we descend one level into a couple of CoreServices sub-folders
    /// where Apple keeps things like Migration Assistant.
    nonisolated private static var appRoots: [String] {
        [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            "/System/Library/CoreServices/Applications",
            NSHomeDirectory() + "/Applications",
        ]
    }

    /// Walk a directory, picking up `.app` bundles. `depth` is bounded so
    /// we don't recurse forever into Frameworks/PlugIns trees inside an
    /// app bundle — those are caught by the `.app/` substring check.
    nonisolated private static func scan(
        directory: String,
        depth: Int,
        into entries: inout [AppEntry],
        seen: inout Set<String>
    ) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: directory) else {
            return
        }
        for name in children {
            let path = "\(directory)/\(name)"
            if name.hasSuffix(".app") {
                // Reject `.app` bundles nested inside other `.app` bundles —
                // Helper apps inside Electron, embedded Xcode toolchains, etc.
                if path.range(of: ".app/") != nil { continue }
                guard seen.insert(path).inserted else { continue }
                let appName = (name as NSString).deletingPathExtension
                guard !appName.isEmpty else { continue }
                entries.append(AppEntry(name: appName, path: path))
                continue
            }
            // Descend one level into top-level sub-folders so Utilities/
            // (a folder, not an app) yields the apps inside it. Don't go
            // deeper — keeps cold scan well under 50 ms.
            if depth < 1 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    scan(directory: path, depth: depth + 1, into: &entries, seen: &seen)
                }
            }
        }
    }
}
