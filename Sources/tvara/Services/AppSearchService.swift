import Foundation

/// In-memory app index. The cache is built once at launch via `warmCache()`
/// (off the main thread), then every keystroke calls the synchronous
/// `match(query:)` and gets an instant answer from RAM — same shape as
/// SystemSettingsService / WindowManagerService / FoldersService. The
/// previous actor-based design forced every search through an actor hop
/// + async Task scheduling + the smart-search debounce, which added
/// noticeable latency for queries like "spoti" that the cache could
/// otherwise answer in microseconds.
@MainActor
final class AppSearchService {
    struct AppEntry: Sendable {
        let name: String
        let path: String
        /// `name.lowercased()` precomputed once at warmCache time. Skipping
        /// this per-keystroke recomputation eliminates ~300 string
        /// allocations on the search hot path.
        let nameLower: String
        /// First letter of each word in `nameLower`, joined. `""` when the
        /// name is a single word (no acronym to form). Precomputed at the
        /// same time as `nameLower` so the scoring loop is allocation-free.
        let acronym: String
        /// PNG bytes of the app's icon at `AppIconStore.pngMaxDim`. Baked
        /// into every emitted `SearchResult.iconData` so the row renders
        /// the icon via `NSImage(data:)` in the same frame as the row —
        /// no lazy `.icns` decode on first draw. `nil` only between
        /// scan-completion and the first warm pass that populates it.
        let iconData: Data?
    }

    private var cache: [AppEntry] = []
    private var cacheTime: Date?
    private static let cacheLifetime: TimeInterval = 300   // 5 min

    /// Monotonic id bumped on every `refreshCacheIfNeeded` pass. The
    /// background icon-enrichment task captures this at dispatch time
    /// and only swaps its result into `cache` if the generation still
    /// matches — so a stale enrichment from refresh N can never
    /// clobber the live cache from refresh N+1, even when the two
    /// scans happen to have the same path set.
    private var refreshGeneration: UInt64 = 0

    /// On-disk PNG cache shared across launches. Populated lazily in
    /// `refreshCacheIfNeeded`; survives restarts so the second-launch
    /// search renders icons immediately rather than re-encoding ~300
    /// `.icns` bitmaps each cold start.
    private let iconStore: AppIconStore

    /// Nonisolated so the ViewModel's parameter list (`appService: AppSearchService
    /// = AppSearchService()`) can construct one in the synchronous nonisolated
    /// context Swift uses for default values. The body touches no MainActor
    /// state — every stored property has a default — so it's safe.
    nonisolated init() {
        self.iconStore = AppIconStore()
    }

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

    /// Synchronous match against the in-memory cache. The MainActor caller
    /// gets an instant answer with no Task scheduling or actor hop — this
    /// is what makes typing "spoti" surface Spotify in the same frame as
    /// the keystroke. Returns [] if the cache is cold (before warmCache
    /// lands); the async `search()` path then fills it for the next query.
    func match(query: String, limit: Int = 20) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard !cache.isEmpty else { return [] }
        return scoreAndRank(query: trimmed.lowercased(), limit: limit)
    }

    /// Async entry — refreshes the cache if it's stale, then runs the same
    /// scoring as `match`. Existing call sites that hit this signature
    /// (warmCache + the keyword fan-out) keep working unchanged.
    func search(query: String, limit: Int = 20) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        await refreshCacheIfNeeded()
        return scoreAndRank(query: trimmed.lowercased(), limit: limit)
    }

    /// In-memory scoring loop. Shared by `match(query:)` (sync, called per
    /// keystroke) and `search(query:)` (async, fills the cache first). The
    /// scoring tiers live here so both paths produce identical rankings.
    private func scoreAndRank(query q: String, limit: Int) -> [SearchResult] {
        var scored: [(AppEntry, Int)] = []
        scored.reserveCapacity(cache.count / 4)

        for app in cache {
            // nameLower / acronym are precomputed at warmCache time, so
            // the loop is allocation-free on the hot keystroke path.
            let nameLower = app.nameLower
            let acro = app.acronym
            let rank: Int
            // Tier hierarchy:
            //   1500 — full name equals query exactly ("notion" → Notion.app)
            //   1400 — query equals the app's acronym ("vsc" → Visual Studio Code,
            //          "gc" → Google Chrome, "as" → App Store). Acronym only
            //          exists when the name has 2+ words.
            //   1300 — query equals a WORD inside the name ("chrome" → Google Chrome,
            //          "code" → Visual Studio Code). This sits above file/folder
            //          exact-name matches (~430) so the app wins over a node_modules
            //          folder that happens to share the name.
            //    500 — full name has the query as a prefix
            //    450 — query is a prefix of the acronym, length >= 2 ("vs" → VS Code).
            //          Ambiguous at 2 letters (matches multiple apps) but harmless
            //          since the user is visually scanning a short candidate list.
            //    380 — any word in the name has the query as a prefix
            //    220 — name contains the query as a substring
            if nameLower == q                                   { rank = 1500 }
            else if !acro.isEmpty && acro == q                  { rank = 1400 }
            else if wordEqualMatch(nameLower, q)                { rank = 1300 }
            else if nameLower.hasPrefix(q)                      { rank = 500 }
            else if !acro.isEmpty && q.count >= 2 && acro.hasPrefix(q) { rank = 450 }
            else if wordPrefixMatch(nameLower, q)               { rank = 380 }
            else if nameLower.contains(q)                       { rank = 220 }
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
                    if let dist = FuzzyMatch.levenshtein(
                        q, app.nameLower, budget: budget
                    ) {
                        fuzzy.append((app, dist))
                    }
                }
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
                        // exact matches from any other source.
                        rank: 280,
                        iconData: app.iconData,
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
                rank: rank,
                iconData: app.iconData
            )
        }
    }

    private func refreshCacheIfNeeded() async {
        if let t = cacheTime, Date().timeIntervalSince(t) < Self.cacheLifetime, !cache.isEmpty {
            return
        }

        // 1. Scan installed apps off main and publish the un-enriched
        //    cache IMMEDIATELY. The first search after launch returns
        //    app results in ~scan-time + ~0 instead of waiting on ~300
        //    icon encodes (1-3s cold). Rows with `iconData = nil`
        //    fall back to FileIconView in the view layer — same path
        //    that was used before app-icon caching landed, so this is
        //    a zero-regression first-paint.
        let scanned = await Task.detached(priority: .userInitiated) {
            Self.scanInstalledApps()
        }.value
        cache = scanned
        cacheTime = Date()
        refreshGeneration &+= 1
        let generation = refreshGeneration

        // 2. Enrich the cache with PNG iconData in the background. On
        //    a warm launch (disk cache hits) this completes in tens
        //    of ms; on a cold launch it takes 1-3s. Either way the
        //    user can already search apps from step 1.
        IconCache.shared.warm(paths: cache.map(\.path))
        startIconEnrichment(for: scanned, generation: generation)
    }

    /// Spawns a background task that hydrates `cache` entries with
    /// their PNG `iconData`. Disk-cached entries (matching mtime) come
    /// straight from `AppIconStore`; misses are re-encoded off main
    /// and persisted in a side task so the enrichment loop isn't gated
    /// on sqlite writes. The enriched cache is published in a single
    /// actor-isolated swap via `replaceCache` once the pass completes.
    /// `generation` is the refresh id at dispatch time — `replaceCache`
    /// drops the result if a fresher refresh has bumped it since.
    private func startIconEnrichment(for scanned: [AppEntry], generation: UInt64) {
        let iconStore = self.iconStore
        Task { [weak self] in
            let cached = await iconStore.bulkFetch(paths: scanned.map(\.path))
            let enriched = await Task.detached(priority: .utility) { () -> [AppEntry] in
                var out: [AppEntry] = []
                out.reserveCapacity(scanned.count)
                for entry in scanned {
                    let mtime = bundleMtimeSeconds(path: entry.path)
                    let iconData: Data?
                    if let mtime,
                       let hit = cached[entry.path],
                       abs(hit.bundleMtime - mtime) < 1.0 {
                        iconData = hit.png
                    } else {
                        let png = encodeAppIconPNG(path: entry.path)
                        iconData = png
                        // Only persist when we have a usable freshness
                        // key. A nil mtime means stat failed; caching
                        // the row would risk a self-matching `mtime=0`
                        // entry that never re-encodes.
                        if let png, let mtime {
                            Task { await iconStore.upsert(
                                path: entry.path, bundleMtime: mtime, png: png
                            ) }
                        }
                    }
                    out.append(AppEntry(
                        name: entry.name,
                        path: entry.path,
                        nameLower: entry.nameLower,
                        acronym: entry.acronym,
                        iconData: iconData
                    ))
                }
                return out
            }.value
            await self?.replaceCache(enriched, generation: generation)
            await iconStore.prune(keepPaths: Set(scanned.map(\.path)))
        }
    }

    /// Actor-isolated cache swap. Drops the result when `generation`
    /// no longer matches `refreshGeneration` — a fresher refresh has
    /// run since this enrichment was dispatched and its result is the
    /// one that should win. A monotonic id beats a path-set guard
    /// because two back-to-back refreshes with the same install set
    /// would otherwise let a stale enrichment clobber a newer one.
    private func replaceCache(_ enriched: [AppEntry], generation: UInt64) {
        guard generation == refreshGeneration else { return }
        cache = enriched
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

    /// First letter of each word in the (already-lowercased) name,
    /// concatenated. Returns "" for single-word names where there's no
    /// acronym to make. "visual studio code" → "vsc", "google chrome" → "gc",
    /// "app store" → "as", "notion" → "" (single word, fall through to
    /// other tiers).
    nonisolated static func acronym(of nameLower: String) -> String {
        let words = nameLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard words.count >= 2 else { return "" }
        return words.compactMap { $0.first.map(String.init) }.joined()
    }

    private nonisolated func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Scan

    /// Enumerate `.app` bundles via two passes, unioned:
    ///
    /// 1. **Directory walk** over the standard install locations (FileManager).
    ///    Reliable for freshly-installed apps that Spotlight hasn't reindexed
    ///    yet. Misses apps in non-standard paths (~/Downloads, ~/Desktop,
    ///    custom locations).
    /// 2. **`mdfind` scan** for `kMDItemContentType == "com.apple.application-bundle"`.
    ///    Catches every `.app` Launch Services knows about, in any location
    ///    on disk — including VS Code launched from ~/Downloads.
    ///
    /// We need both because each path has gaps the other covers: the dir
    /// walk misses non-standard locations; mdfind misses just-installed
    /// apps that haven't been reindexed. Union + dedupe by path covers
    /// the merge.
    ///
    /// Cost: ~30-80 ms cold; warm-cache amortizes across every subsequent
    /// keystroke. Runs on Task.detached → never blocks the main actor.
    nonisolated private static func scanInstalledApps() -> [AppEntry] {
        var entries: [AppEntry] = []
        var seen = Set<String>()

        for root in appRoots {
            scan(directory: root, depth: 0, into: &entries, seen: &seen)
        }
        for path in scanViaMdfind() {
            // mdfind returns full bundle paths. Same dedupe + nested-app
            // filter as the dir walk so a Helper.app inside Electron
            // doesn't pollute the index.
            if path.range(of: ".app/") != nil { continue }
            guard path.hasSuffix(".app") else { continue }
            guard seen.insert(path).inserted else { continue }
            let appName = (path as NSString).lastPathComponent
            let trimmed = (appName as NSString).deletingPathExtension
            guard !trimmed.isEmpty else { continue }
            entries.append(makeEntry(name: trimmed, path: path))
        }
        return entries
    }

    /// Build an `AppEntry` with `nameLower` + `acronym` precomputed so the
    /// hot keystroke loop stays allocation-free. `iconData` is left nil
    /// here — `refreshCacheIfNeeded` populates it from the disk cache or
    /// re-encodes off main before exposing the entries to search.
    nonisolated private static func makeEntry(name: String, path: String) -> AppEntry {
        let lower = name.lowercased()
        return AppEntry(
            name: name,
            path: path,
            nameLower: lower,
            acronym: acronym(of: lower),
            iconData: nil
        )
    }

    /// Shell out to `mdfind` for every `.app` bundle on the local volume.
    /// Faster than NSMetadataQuery for a one-shot read (NSMetadataQuery is
    /// async with notification plumbing; we just want a list). Empty array
    /// on failure — the dir walk still covers the standard locations.
    nonisolated private static func scanViaMdfind() -> [String] {
        let task = Process()
        task.launchPath = "/usr/bin/mdfind"
        task.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: { $0 == "\n" }).map(String.init)
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
                entries.append(makeEntry(name: appName, path: path))
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
