import Foundation

/// Watches image-bearing directories with `FSEventsWatcher` and enqueues
/// one `image_added` event per created/modified image file. Dedupe key
/// is the absolute path.
///
/// Filters to image extensions on the producer side so we don't pay the
/// queue cost (or wake the worker) for non-image filesystem activity in
/// the same directories.
actor ImageProducer {
    private let bus: EventBus
    private let paths: [String]
    private var watcher: FSEventsWatcher?

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif",
        "tiff", "tif", "bmp", "webp", "gif",
    ]

    init(bus: EventBus, watchPaths: [String]) {
        self.bus = bus
        self.paths = watchPaths
    }

    /// `~/Pictures`, `~/Desktop`, `~/Downloads` — same defaults as the
    /// legacy `ImageIndexService` sweep roots so the queue-driven path
    /// covers the same ground.
    static func defaultWatchPaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Pictures",
            home + "/Desktop",
            home + "/Downloads",
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        guard watcher == nil else { return }
        let bus = self.bus
        let watcher = FSEventsWatcher(paths: paths) { path in
            guard Self.shouldEnqueue(path: path) else { return }
            // Microsecond mtime so a re-saved image gets re-indexed
            // instead of being permanently silenced by the original
            // dedupe row.
            let mtime = FileProducer.mtimeBucket(path: path)
            Task.detached(priority: .utility) {
                let payload = ImageAddedPayload(path: path)
                do {
                    _ = try await bus.enqueue(
                        type: EventType.imageAdded,
                        source: EventSource.fs,
                        payload: payload,
                        dedupeKey: "img:\(path):\(mtime)"
                    )
                } catch {
                    NSLog("ImageProducer enqueue failed for %@: %@", path, "\(error)")
                }
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    nonisolated static func shouldEnqueue(path: String) -> Bool {
        let basename = (path as NSString).lastPathComponent
        if basename.hasPrefix(".") { return false }
        let ext = (basename as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }
}
