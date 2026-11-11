import AppKit

/// Process-wide NSImage cache for file icons.
///
/// `NSWorkspace.shared.icon(forFile:)` returns instantly but the resulting
/// NSImage decodes its bitmap lazily on first draw. Caching the object by
/// path means rows that share an icon (several files of one type, the same
/// folder in two sections) reuse a decoded image instead of each paying
/// for it.
///
/// App rows don't come through here: they render a small pre-encoded PNG
/// from AppIconStore. This is the fallback for file rows, and for app rows
/// in the first moments after a cold launch.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private init() {}

    private var byPath: [String: NSImage] = [:]

    /// Cached icon if we have one, else fetch (cheap — NSWorkspace returns
    /// instantly) and store. The first render of an uncached path still
    /// pays the lazy-decode cost; subsequent renders are warm.
    func icon(forPath path: String) -> NSImage {
        if let cached = byPath[path] { return cached }
        let img = NSWorkspace.shared.icon(forFile: path)
        byPath[path] = img
        return img
    }
}
