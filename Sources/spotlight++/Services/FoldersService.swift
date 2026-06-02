import AppKit
import Foundation

/// Common-destination folder shortcuts. Each row maps a typed alias to an
/// absolute path that opens in Finder via NSWorkspace. Same flat alias
/// table pattern as WindowManagerService and SystemSettingsService.
///
/// v0 lineup: 10 folders covering ~/Downloads / ~/Documents / ~/Desktop
/// and the other places users actually navigate to from a launcher.
final class FoldersService {

    private struct Entry {
        let alias: String     // lowercase
        let canonical: String // shown as row title ("Downloads")
        let path: String      // absolute path
    }

    private static let home = NSHomeDirectory()

    /// 10 hand-picked folders. The home-relative paths use NSHomeDirectory
    /// at init time so the user's actual home is respected (no hardcoded
    /// /Users/anyone). Trash is the special case — system path under the
    /// user's library.
    private static let entries: [Entry] = [
        Entry(alias: "downloads",     canonical: "Downloads",
              path: "\(home)/Downloads"),
        Entry(alias: "dl",            canonical: "Downloads",
              path: "\(home)/Downloads"),
        Entry(alias: "dls",           canonical: "Downloads",
              path: "\(home)/Downloads"),

        Entry(alias: "documents",     canonical: "Documents",
              path: "\(home)/Documents"),
        Entry(alias: "docs",          canonical: "Documents",
              path: "\(home)/Documents"),

        Entry(alias: "desktop",       canonical: "Desktop",
              path: "\(home)/Desktop"),

        Entry(alias: "home",          canonical: "Home",
              path: home),
        Entry(alias: "~",             canonical: "Home",
              path: home),

        Entry(alias: "applications",  canonical: "Applications",
              path: "/Applications"),
        Entry(alias: "apps folder",   canonical: "Applications",
              path: "/Applications"),

        Entry(alias: "pictures",      canonical: "Pictures",
              path: "\(home)/Pictures"),
        Entry(alias: "photos folder", canonical: "Pictures",
              path: "\(home)/Pictures"),

        Entry(alias: "movies",        canonical: "Movies",
              path: "\(home)/Movies"),
        Entry(alias: "videos",        canonical: "Movies",
              path: "\(home)/Movies"),

        Entry(alias: "music",         canonical: "Music",
              path: "\(home)/Music"),

        Entry(alias: "icloud drive",  canonical: "iCloud Drive",
              path: "\(home)/Library/Mobile Documents/com~apple~CloudDocs"),
        Entry(alias: "icloud",        canonical: "iCloud Drive",
              path: "\(home)/Library/Mobile Documents/com~apple~CloudDocs"),

        Entry(alias: "trash",         canonical: "Trash",
              path: "\(home)/.Trash"),
    ]

    func match(query rawQuery: String) -> [SearchResult] {
        let normalized = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return [] }

        // ─── Pass 1: prefix ───────────────────────────────────────────
        var seen: Set<String> = []
        var prefixHits: [Entry] = []
        for entry in Self.entries {
            guard entry.alias.hasPrefix(normalized) else { continue }
            // Dedupe by path — "downloads" / "dl" / "dls" all collapse.
            guard !seen.contains(entry.path) else { continue }
            seen.insert(entry.path)
            prefixHits.append(entry)
        }
        if !prefixHits.isEmpty {
            return Self.render(entries: Array(prefixHits.prefix(8)), rankBase: 925)
        }

        // ─── Pass 2: fuzzy fallback ───────────────────────────────────
        let budget = FuzzyMatch.budget(for: normalized)
        guard budget > 0 else { return [] }
        seen.removeAll(keepingCapacity: true)
        var fuzzyHits: [(Entry, Int)] = []
        for entry in Self.entries {
            guard !seen.contains(entry.path) else { continue }
            if let dist = FuzzyMatch.levenshtein(
                normalized, entry.alias, budget: budget
            ) {
                seen.insert(entry.path)
                fuzzyHits.append((entry, dist))
            }
        }
        fuzzyHits.sort { $0.1 < $1.1 }
        return Self.render(
            entries: fuzzyHits.prefix(8).map { $0.0 },
            rankBase: 865
        )
    }

    private static func render(entries: [Entry], rankBase: Int) -> [SearchResult] {
        entries.enumerated().map { idx, entry in
            SearchResult(
                title: entry.canonical,
                subtitle: "Folders",
                source: .folder,
                date: nil,
                badge: nil,
                openTarget: .file(entry.path),
                rank: rankBase - idx
            )
        }
    }

    /// True when the typed query equals one of our aliases exactly. Used
    /// by the ViewModel's exclusivity rule.
    func hasExactMatch(query rawQuery: String) -> Bool {
        let normalized = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return false }
        return Self.entries.contains { $0.alias == normalized }
    }
}
