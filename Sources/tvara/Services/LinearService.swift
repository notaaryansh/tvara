import Foundation

/// Lightweight Linear "shortcut" — when the user says "open X in linear",
/// we surface a single SearchResult that deep-links into Linear.app via
/// its `linear://` URL scheme. We don't index Linear's actual issue list
/// yet (their cache is IndexedDB / LevelDB, which is a heavier lift).
///
/// Result subtitle echoes the cleaned needle so the user knows we heard
/// them, even though we're not literally matching against issue titles.
actor LinearService {
    private static let appPath = "/Applications/Linear.app"

    /// Optional override file. If present, its contents (a single URL on
    /// the first line) become the target for every Linear shortcut result.
    /// Lets the user point us at their workspace's "Active issues" or
    /// similar page without rebuilding the app.
    ///
    /// Example file contents:
    ///   https://linear.app/acme/team/ENG/active
    /// or:
    ///   linear://acme/team/ENG/active
    private static let urlConfigPath = NSHomeDirectory()
        + "/Library/Application Support/tvara/linear_issues_url.txt"

    /// No-op — kept for parity with other services so wiring stays uniform.
    func warmCache() async {}

    func search(query: String) async -> [SearchResult] {
        // Only surface a Linear result if the app is actually installed.
        guard FileManager.default.fileExists(atPath: Self.appPath) else { return [] }

        let needle = query.trimmingCharacters(in: .whitespaces)
        let url = Self.configuredURL() ?? "linear://"
        let subtitle = needle.isEmpty
            ? "Open Linear"
            : "Open in Linear · \"\(needle)\""

        return [SearchResult(
            title: "Linear",
            subtitle: subtitle,
            source: .linear,
            date: nil,
            badge: nil,
            openTarget: .url(url),
            rank: 700,
            iconData: SourceAppIcons.iconData(for: .linear)
        )]
    }

    /// Read first non-empty line from the config file. Returns nil if the
    /// file doesn't exist or has no usable line.
    nonisolated private static func configuredURL() -> String? {
        guard let contents = try? String(contentsOfFile: urlConfigPath, encoding: .utf8) else {
            return nil
        }
        for raw in contents.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return line
        }
        return nil
    }
}
