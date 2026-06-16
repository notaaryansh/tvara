import AppKit

/// Process-wide NSImage cache for file/app icons.
///
/// `NSWorkspace.shared.icon(forFile:)` returns instantly but the resulting
/// NSImage loads its bitmap representations LAZILY on first draw — which
/// is why search result rows seem to render one frame, then their icons
/// fill in the next. We work around that two ways:
///
/// 1. Cache the NSImage object by path so subsequent rows that share an
///    icon (multiple files from the same app, the same app appearing in
///    multiple sections) hit a warm object.
/// 2. Pre-decode every app icon at launch via `warm(paths:)` — uses
///    `cgImage(forProposedRect:…)` to force the bitmap representation into
///    memory while still on the background thread. The first ever render
///    of an app row then has nothing left to load.
///
/// FileIconView reads from this cache; AppSearchService.warmCache hands
/// it the full app path list once the scan finishes.
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

    /// Pre-warm icons for the given paths. Runs on a background task so
    /// the main actor stays responsive — decodes the `.icns` bitmaps off
    /// the main thread, then bulk-stores the prepared NSImages.
    ///
    /// Safe to call multiple times; already-cached paths are skipped so
    /// a re-warm after the 5-minute app-cache refresh does the minimum
    /// work needed for any new bundles found.
    func warm(paths: [String]) {
        let pending = paths.filter { byPath[$0] == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) {
            var prepared: [(String, NSImage)] = []
            prepared.reserveCapacity(pending.count)
            for path in pending {
                let img = NSWorkspace.shared.icon(forFile: path)
                // Force the bitmap representation into memory now, on this
                // background thread, so the first on-screen render doesn't
                // stall the frame to decode.
                _ = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
                prepared.append((path, img))
            }
            await MainActor.run {
                for (path, img) in prepared {
                    if IconCache.shared.byPath[path] == nil {
                        IconCache.shared.byPath[path] = img
                    }
                }
            }
        }
    }
}
