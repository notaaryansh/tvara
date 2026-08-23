import AppKit
import Foundation

/// Resolves the parent-app icon for integration sources (Notion, Linear,
/// Spotify, Mail, Notes) into PNG bytes the row renderer can drop into
/// `NSImage(data:)`. Lookups go through `NSWorkspace` once per app per
/// process; results are cached for the lifetime of the launch.
///
/// Missing-app results are cached as the sentinel empty Data so callers
/// don't re-resolve a missing app on every keystroke. The row falls back
/// to whatever default rendering the row renderer uses when iconData is
/// nil.
enum SourceAppIcons {
    private static let lock = NSLock()
    private static var cache: [String: Data] = [:]

    static func iconData(for app: SourceApp) -> Data? {
        let key = app.cacheKey
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached.isEmpty ? nil : cached
        }
        lock.unlock()

        var resolvedPath: String? = nil
        for bid in app.bundleIDCandidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                resolvedPath = url.path
                break
            }
        }
        // Display-name fallback for installs whose bundle ID isn't on
        // our candidate list (Notion + Linear have both shipped under
        // multiple bundle IDs across versions).
        if resolvedPath == nil, let appName = app.fallbackAppName {
            let path = NSWorkspace.shared.fullPath(forApplication: appName)
            if let path, !path.isEmpty { resolvedPath = path }
        }

        guard let path = resolvedPath, let png = encodeAppIconPNG(path: path) else {
            lock.lock(); cache[key] = Data(); lock.unlock()
            return nil
        }
        lock.lock(); cache[key] = png; lock.unlock()
        return png
    }
}

enum SourceApp {
    case notion
    case linear

    var cacheKey: String {
        switch self {
        case .notion: return "notion"
        case .linear: return "linear"
        }
    }

    /// Bundle IDs to try in order. First match wins. Linear has shipped
    /// under both `com.linear` and `com.linear.linear` across versions.
    var bundleIDCandidates: [String] {
        switch self {
        case .notion: return ["notion.id"]
        case .linear: return ["com.linear", "com.linear.linear"]
        }
    }

    /// Display name fallback — passed to `fullPath(forApplication:)` if
    /// no bundle-ID candidate resolves.
    var fallbackAppName: String? {
        switch self {
        case .notion: return "Notion"
        case .linear: return "Linear"
        }
    }
}
