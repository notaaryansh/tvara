import Foundation

actor FileSearchService {
    /// Reference to the most-recently-spawned mdfind subprocess. When a
    /// new query arrives we terminate it before launching the next one —
    /// otherwise N keystrokes pile up N concurrent mdfind processes, all
    /// hammering spotlightd, and the new query has to wait through the
    /// contention.
    private var currentProcess: Process?

    /// Touch the three TCC-protected user folders so macOS fires the
    /// permission prompts at launch. Without this, our `mdfind` subprocess
    /// silently inherits a denied TCC context and returns *only* the
    /// unrestricted paths (e.g. ~/Library/Application Support) — so a
    /// search for "pitch" surfaces Steam icons but not the PDF on the
    /// user's Desktop. Reading the directory listing is enough to trip TCC.
    func warmCache() async {
        let home = NSHomeDirectory()
        for folder in ["Desktop", "Documents", "Downloads"] {
            _ = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/\(folder)")
        }
    }

    func search(query: String, limit: Int = 25) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // Kill the prior mdfind if it's still running. Its detached
        // consumer task will see process.isRunning == false, exit the
        // busy-poll, return whatever it has (usually empty), and the
        // SearchViewModel's searchID guard will drop the stale result.
        currentProcess?.terminate()
        currentProcess = nil

        // Spawn the new subprocess on the actor so we can track the
        // Process reference for the next call's terminate(). The
        // blocking read/wait runs on the detached task below.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        // -onlyin forces a slow post-query filter (~1s); the unscoped index
        // returns in ~50ms. We filter to the user's home in Swift below.
        process.arguments = ["-name", trimmed]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return []
        }
        currentProcess = process

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return await Task.detached(priority: .userInitiated) {
            Self.consume(process: process, stdout: stdout,
                         query: trimmed, scopePrefix: home, limit: limit)
        }.value
    }

    nonisolated private static func consume(
        process: Process, stdout: Pipe,
        query: String, scopePrefix: String, limit: Int
    ) -> [SearchResult] {
        let queryLower = query.lowercased()

        // Hard cap so a pathological query can't stall the UI. Unscoped
        // mdfind normally returns in ~50ms so this is well above noise.
        // Loop exits early if the actor's terminate() killed us — fine,
        // we'll return whatever partial output reached the pipe.
        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { process.terminate() }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let paths = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix(scopePrefix) }
            .filter { !Self.isJunkPath($0) }
            .prefix(limit * 4)               // we'll filter junk before truncating

        let now = Date()
        var results: [SearchResult] = []
        results.reserveCapacity(paths.count)

        for path in paths {
            guard let result = makeResult(for: path, query: queryLower, now: now) else { continue }
            results.append(result)
        }

        // Rank within the Files tab so prefix/exact name matches and recent
        // edits surface above arbitrary substring matches.
        results.sort { a, b in
            if a.rank != b.rank { return a.rank > b.rank }
            return (a.date ?? .distantPast) > (b.date ?? .distantPast)
        }
        return Array(results.prefix(limit))
    }

    nonisolated private static func makeResult(
        for path: String, query: String, now: Date
    ) -> SearchResult? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return nil }   // skip dotfiles

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .contentModificationDateKey, .fileSizeKey
        ]
        let values = try? url.resourceValues(forKeys: resourceKeys)
        let isDir = values?.isDirectory ?? false
        let modDate = values?.contentModificationDate
        let size = Int64(values?.fileSize ?? 0)

        let nameLower = name.lowercased()
        let baseLower = (nameLower as NSString).deletingPathExtension

        // Rank components — kept comparable with browser visit counts (capped at 500).
        let nameMatchBoost: Int = {
            if baseLower == query { return 400 }       // exact match on filename (sans extension)
            if nameLower.hasPrefix(query) { return 300 }
            if baseLower.hasPrefix(query) { return 250 }
            if nameLower.contains(query) { return 120 }
            return 60                                  // matched via content/metadata, not name
        }()

        let recencyBoost: Int = {
            guard let modDate else { return 0 }
            let days = max(0, now.timeIntervalSince(modDate) / 86_400)
            return max(0, 30 - Int(days))              // up to +30 for items modified today
        }()

        let badge: String? = isDir ? nil : Self.formatSize(size)

        return SearchResult(
            title: name,
            subtitle: abbreviateHome(path),
            source: isDir ? .folder : .file,
            date: modDate,
            badge: badge,
            openTarget: .file(path),
            rank: nameMatchBoost + recencyBoost
        )
    }

    nonisolated private static func formatSize(_ bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    nonisolated private static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Paths that pass mdfind's name match but are noise for a launcher
    /// — dependency caches, build artifacts, hidden folders. Filtering
    /// here keeps "chrome" from surfacing four node_modules/chrome
    /// folders above the actual Google Chrome.app.
    nonisolated private static func isJunkPath(_ path: String) -> Bool {
        // Dependency manager + build artifact caches.
        let junkSegments = [
            "/node_modules/",
            "/.venv/",
            "/venv/",
            "/.git/",
            "/__pycache__/",
            "/.next/",
            "/.nuxt/",
            "/.svelte-kit/",
            "/dist/",
            "/build/",
            "/.build/",
            "/DerivedData/",
            "/Pods/",
            "/.gradle/",
            "/.cache/",
            "/Caches/",
        ]
        for segment in junkSegments where path.range(of: segment) != nil {
            return true
        }
        // ~/Library is full of internal app caches; user almost never
        // wants to navigate there from a launcher.
        let home = NSHomeDirectory()
        if path.hasPrefix("\(home)/Library/") { return true }
        // Any path component starting with `.` (dotfolders / dotfiles).
        for component in path.split(separator: "/") {
            if component.hasPrefix(".") && component.count > 1 { return true }
        }
        return false
    }
}
