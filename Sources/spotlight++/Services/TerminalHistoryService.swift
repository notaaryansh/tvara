import Foundation

/// Reads shell history files (zsh / bash / fish) and serves a search.
///
/// History lives in plain files we can re-read cheaply (~tens of KB each
/// for typical users). We cache the parsed entries and refresh whenever
/// the source files' mtime advances. No SQLite — the data set is small
/// enough that in-memory LIKE-style matching is faster than the overhead
/// of round-tripping through a query engine.
actor TerminalHistoryService {
    struct Entry: Sendable {
        let command: String
        let timestamp: Date?
        let shell: String        // "zsh" / "bash" / "fish"
        let frequency: Int       // how often this exact command appears
    }

    private var cache: [Entry] = []
    private var cacheMtime: Date?
    private static let refreshLifetime: TimeInterval = 30

    private let zshHistory   = NSHomeDirectory() + "/.zsh_history"
    private let bashHistory  = NSHomeDirectory() + "/.bash_history"
    private let fishHistory  = NSHomeDirectory() + "/.local/share/fish/fish_history"

    func search(query: String, limit: Int = 30) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        await refreshIfNeeded()
        let needle = trimmed.lowercased()
        let now = Date()

        var scored: [(Entry, Int)] = []
        for entry in cache {
            let cmdLower = entry.command.lowercased()
            guard cmdLower.contains(needle) else { continue }

            // Ranking: prefix-match beats substring, frequent commands
            // beat one-offs, recent commands beat old ones.
            var rank = 0
            if cmdLower.hasPrefix(needle) { rank += 300 }
            else if let firstWord = cmdLower.split(separator: " ").first,
                    String(firstWord).hasPrefix(needle) { rank += 200 }
            else { rank += 80 }
            rank += min(entry.frequency * 5, 120)
            if let ts = entry.timestamp {
                let days = max(0, now.timeIntervalSince(ts) / 86_400)
                rank += max(0, 60 - Int(days))
            }
            scored.append((entry, rank))
        }

        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map { (entry, rank) in
            SearchResult(
                title: entry.command,
                subtitle: subtitleFor(entry: entry),
                source: .terminal,
                date: entry.timestamp,
                badge: entry.frequency > 1 ? "×\(entry.frequency)" : nil,
                openTarget: .copyToClipboard(entry.command),
                rank: rank
            )
        }
    }

    private func subtitleFor(entry: Entry) -> String {
        // Tell the user what ↩ will do; their terminal of choice can
        // accept it via ⌘V. Future v1: AppleScript directly into
        // Terminal.app / iTerm2.
        return "Copy to clipboard — \(entry.shell)"
    }

    // MARK: - Refresh

    private func refreshIfNeeded() async {
        if let t = cacheMtime, Date().timeIntervalSince(t) < Self.refreshLifetime {
            return
        }
        cache = await Task.detached(priority: .userInitiated) {
            Self.readAll(
                zsh: self.zshHistory,
                bash: self.bashHistory,
                fish: self.fishHistory
            )
        }.value
        cacheMtime = Date()
    }

    // MARK: - File readers (run detached)

    nonisolated private static func readAll(zsh: String, bash: String, fish: String) -> [Entry] {
        var entries: [Entry] = []
        entries.append(contentsOf: readZsh(zsh))
        entries.append(contentsOf: readBash(bash))
        entries.append(contentsOf: readFish(fish))
        return aggregate(entries)
    }

    /// zsh extended history line: `: TIMESTAMP:ELAPSED;COMMAND`
    /// zsh plain line: just the command.
    /// Multi-line commands continue with a trailing `\`.
    nonisolated private static func readZsh(_ path: String) -> [Entry] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        // zsh history is "metafied" — bytes >= 0x80 are escaped with 0x83
        // followed by (byte ^ 0x20). For our purposes (ASCII commands are
        // the common case), Latin-1 fallback is good enough.
        guard let text = String(data: data, encoding: .utf8)
              ?? String(data: data, encoding: .isoLatin1) else { return [] }

        var out: [Entry] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var pending: String? = nil
        var pendingTs: Date? = nil

        for line in lines {
            // Continuation of a previous multi-line command
            if let p = pending {
                if p.hasSuffix("\\") {
                    pending = String(p.dropLast()) + "\n" + line
                    continue
                }
                out.append(Entry(command: p, timestamp: pendingTs, shell: "zsh", frequency: 1))
                pending = nil
                pendingTs = nil
            }

            if line.hasPrefix(": ") {
                // Extended history line
                let rest = String(line.dropFirst(2))
                guard let semi = rest.firstIndex(of: ";") else { continue }
                let metaPart = String(rest[..<semi])
                let cmdPart  = String(rest[rest.index(after: semi)...])
                let parts = metaPart.split(separator: ":", maxSplits: 1).map(String.init)
                let ts: Date? = parts.first.flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
                if cmdPart.hasSuffix("\\") {
                    pending = cmdPart
                    pendingTs = ts
                } else if !cmdPart.isEmpty {
                    out.append(Entry(command: cmdPart, timestamp: ts, shell: "zsh", frequency: 1))
                }
            } else if !line.isEmpty {
                if line.hasSuffix("\\") {
                    pending = line
                    pendingTs = nil
                } else {
                    out.append(Entry(command: line, timestamp: nil, shell: "zsh", frequency: 1))
                }
            }
        }
        if let p = pending {
            out.append(Entry(command: p, timestamp: pendingTs, shell: "zsh", frequency: 1))
        }
        return out
    }

    nonisolated private static func readBash(_ path: String) -> [Entry] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { Entry(command: String($0), timestamp: nil, shell: "bash", frequency: 1) }
    }

    /// fish history is a YAML-like format:
    ///   - cmd: <command>
    ///     when: <unix epoch>
    nonisolated private static func readFish(_ path: String) -> [Entry] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        var currentCmd: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.hasPrefix("- cmd:") {
                if let c = currentCmd {
                    out.append(Entry(command: c, timestamp: nil, shell: "fish", frequency: 1))
                }
                currentCmd = String(l.dropFirst("- cmd:".count).trimmingCharacters(in: .whitespaces))
            } else if l.hasPrefix("  when:"), let cmd = currentCmd {
                let tsStr = l.dropFirst("  when:".count).trimmingCharacters(in: .whitespaces)
                let ts = TimeInterval(tsStr).map { Date(timeIntervalSince1970: $0) }
                out.append(Entry(command: cmd, timestamp: ts, shell: "fish", frequency: 1))
                currentCmd = nil
            }
        }
        if let c = currentCmd {
            out.append(Entry(command: c, timestamp: nil, shell: "fish", frequency: 1))
        }
        return out
    }

    /// Collapse duplicate commands into a single entry with the highest
    /// frequency + newest timestamp.
    nonisolated private static func aggregate(_ raw: [Entry]) -> [Entry] {
        var byCmd: [String: Entry] = [:]
        byCmd.reserveCapacity(raw.count)
        for e in raw {
            if let existing = byCmd[e.command] {
                byCmd[e.command] = Entry(
                    command: e.command,
                    timestamp: max(existing.timestamp ?? .distantPast,
                                   e.timestamp ?? .distantPast),
                    shell: existing.shell,
                    frequency: existing.frequency + 1
                )
            } else {
                byCmd[e.command] = e
            }
        }
        return Array(byCmd.values)
    }
}
