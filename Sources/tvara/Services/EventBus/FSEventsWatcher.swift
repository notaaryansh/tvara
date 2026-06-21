import CoreServices
import Foundation

/// Thin Swift wrapper around `FSEventStream` for watching directory trees.
/// Delivers one callback per filesystem event path. Created/modified-file
/// filtering is done by the watcher; the producer is responsible for
/// path-level filters (extensions, hidden, etc).
///
/// Modern API: dispatch queue rather than CFRunLoop. The callback runs off
/// the utility QoS queue — keep it cheap and hand work off to actors.
final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onCreated: @Sendable (String) -> Void
    private let queue: DispatchQueue

    /// Latency in seconds before FSEvents coalesces and delivers a batch.
    /// 1.0s is the Apple-recommended default for non-realtime watchers.
    static let coalesceLatency: CFTimeInterval = 1.0

    init(paths: [String], onCreated: @escaping @Sendable (String) -> Void) {
        self.paths = paths
        self.onCreated = onCreated
        self.queue = DispatchQueue(label: "com.tvara.fsevents", qos: .utility)
    }

    deinit { stop() }

    /// Idempotent.
    func start() {
        guard stream == nil else { return }

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let cb: FSEventStreamCallback = { (
            _: ConstFSEventStreamRef,
            info: UnsafeMutableRawPointer?,
            count: Int,
            pathsPtr: UnsafeMutableRawPointer,
            flagsPtr: UnsafePointer<FSEventStreamEventFlags>,
            _: UnsafePointer<FSEventStreamEventId>
        ) in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = unsafeBitCast(pathsPtr, to: CFArray.self)
            for i in 0..<count {
                let cfStr = unsafeBitCast(
                    CFArrayGetValueAtIndex(cfPaths, i),
                    to: CFString.self
                )
                let path = cfStr as String
                let flags = flagsPtr[i]
                // Created OR modified files only; ignore renames/removes.
                let isFile = (flags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
                let isCreated = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                let isModified = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0
                guard isFile, isCreated || isModified else { continue }
                watcher.onCreated(path)
            }
        }

        let cfPaths = paths as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            cb,
            &ctx,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.coalesceLatency,
            flags
        ) else {
            NSLog("FSEventsWatcher: FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            NSLog("FSEventsWatcher: FSEventStreamStart failed")
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return
        }
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
