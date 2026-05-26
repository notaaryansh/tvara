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
            if nameLower == q                    { rank = 600 }
            else if nameLower.hasPrefix(q)       { rank = 500 }
            else if wordPrefixMatch(nameLower, q){ rank = 380 }
            else if nameLower.contains(q)        { rank = 220 }
            else { continue }
            scored.append((app, rank))
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

    private nonisolated func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Scan

    nonisolated private static func scanInstalledApps() -> [AppEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        // Spotlight's content type for any .app bundle.
        process.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(3.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { process.terminate() }
        } catch {
            return []
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let paths = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        var seen = Set<String>()
        var entries: [AppEntry] = []
        entries.reserveCapacity(paths.count)

        for path in paths {
            // Reject .app bundles nested inside other .app bundles
            // (Xcode simulators, Helper.app inside Electron apps, etc).
            if path.range(of: ".app/")  != nil { continue }
            if !isAcceptableLocation(path) { continue }
            if !seen.insert(path).inserted { continue }

            let name = (URL(fileURLWithPath: path).lastPathComponent as NSString).deletingPathExtension
            guard !name.isEmpty else { continue }
            entries.append(AppEntry(name: name, path: path))
        }
        return entries
    }

    nonisolated private static func isAcceptableLocation(_ path: String) -> Bool {
        // Whitelist standard install locations so we don't surface deep
        // system internals (caches, install staging dirs, etc).
        let prefixes = [
            "/Applications/",
            "/System/Applications/",
            "/System/Library/CoreServices/",
            "/System/Library/PreferencePanes/",
            NSHomeDirectory() + "/Applications/",
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }
}
