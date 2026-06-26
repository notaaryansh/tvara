import Foundation

/// FSEvents-driven producer for Discord. Watches Discord's Chromium HTTP
/// cache directory and enqueues a single `discord_scan` event when writes
/// settle. The event payload carries a time-bucketed identifier so the
/// dedupe-key UNIQUE constraint collapses bursts of FSEvents within the
/// same minute into one queued scan — Discord-Electron writes dozens of
/// cache entries per session (avatars, message bodies, presence updates)
/// and we don't want that to translate into dozens of redundant full
/// cache walks.
///
/// First-launch bootstrap is the service's responsibility — see
/// `DiscordService.bootstrap()`. The producer only carries deltas.
actor DiscordProducer {
    private let bus: EventBus
    private let cacheDir: String
    private var watcher: FSEventsWatcher?

    /// Window over which FSEvents from Discord's cache get coalesced into
    /// a single scan event. 60s is small enough that fresh messages reach
    /// search within a minute and large enough that a typing burst doesn't
    /// enqueue more than one scan.
    static let bucketSeconds: Int64 = 60

    init(bus: EventBus, cacheDir: String) {
        self.bus = bus
        self.cacheDir = cacheDir
    }

    /// Idempotent.
    func start() {
        guard watcher == nil else { return }
        guard FileManager.default.fileExists(atPath: cacheDir) else { return }

        let bus = self.bus
        let w = FSEventsWatcher(paths: [cacheDir]) { _ in
            let now = Int64(Date().timeIntervalSince1970)
            let bucket = now / Self.bucketSeconds
            Task.detached(priority: .utility) {
                let payload = DiscordScanPayload(bucket: bucket)
                do {
                    _ = try await bus.enqueue(
                        type: EventType.discordScan,
                        source: EventSource.discord,
                        payload: payload,
                        dedupeKey: "discord:scan-\(bucket)"
                    )
                } catch {
                    NSLog("DiscordProducer enqueue failed: %@", "\(error)")
                }
            }
        }
        watcher = w
        w.start()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }
}
