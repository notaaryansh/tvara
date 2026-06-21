import Foundation

/// Watches a set of directories with `FSEventsWatcher` and enqueues one
/// `file_added` event per created/modified file. Dedupe key is the
/// absolute path — repeated saves coalesce naturally.
///
/// Filters out hidden files and common "still downloading" temp suffixes
/// so the queue doesn't fill up with `.crdownload` noise.
actor FileProducer {
    private let bus: EventBus
    private let paths: [String]
    private var watcher: FSEventsWatcher?

    /// Common partial-download extensions to drop on the producer side.
    /// These rename to the final extension on completion, which fires a
    /// second FSEvent that we will accept.
    private static let temporaryExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "tmp", "temp"
    ]

    init(bus: EventBus, watchPaths: [String]) {
        self.bus = bus
        self.paths = watchPaths
    }

    static func defaultWatchPaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Downloads",
            home + "/Desktop",
            home + "/Documents",
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        guard watcher == nil else { return }
        let bus = self.bus
        let watcher = FSEventsWatcher(paths: paths) { path in
            guard Self.shouldEnqueue(path: path) else { return }
            Task.detached(priority: .utility) {
                let payload = FileAddedPayload(path: path)
                await bus.enqueue(
                    type: EventType.fileAdded,
                    source: EventSource.fs,
                    payload: payload,
                    dedupeKey: "fs:\(path)"
                )
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
        if temporaryExtensions.contains(ext) { return false }
        return true
    }
}
