import AppKit

/// Process-wide NSImage cache for file icons, keyed by full path.
///
/// `NSWorkspace.shared.icon(forFile:)` returns instantly but the resulting
/// NSImage decodes its bitmap lazily on first draw. Caching the object by
/// path means a path that is drawn again (the same file or folder showing
/// up in a later query, or in two sections) reuses its decoded image.
///
/// App rows normally render a small pre-encoded PNG from AppIconStore and
/// never come through here. Rows without one fall back to this cache: file
/// and folder rows, and app rows on a first launch before their PNG has
/// been encoded.
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
