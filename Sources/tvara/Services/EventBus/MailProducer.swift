import Foundation

/// FSEvents-driven producer for Apple Mail. Watches the mail base tree
/// (e.g. `~/Library/Mail/V*`) and enqueues one `mail_added` event per new
/// or modified `.emlx` file. Dedupe key `mail:<path>` collapses repeated
/// writes to the same file (Mail re-writes status flags into the .emlx
/// repeatedly without changing content).
///
/// First-launch bootstrap is intentionally NOT this producer's job — the
/// existing `AppleMailService.bootstrap()` walks the tree once and writes
/// rows directly into the FTS5 mirror. The producer only carries deltas
/// from there on out, so steady-state ingest costs scale with new mail
/// volume rather than the size of the mailbox.
actor MailProducer {
    private let bus: EventBus
    private let mailBase: String
    private var watcher: FSEventsWatcher?

    init(bus: EventBus, mailBase: String) {
        self.bus = bus
        self.mailBase = mailBase
    }

    /// Idempotent.
    func start() {
        guard watcher == nil else { return }
        guard FileManager.default.fileExists(atPath: mailBase) else { return }

        let bus = self.bus
        let w = FSEventsWatcher(paths: [mailBase]) { path in
            // FSEvents fires on the parent dir on .emlx writes; filter
            // here so we don't enqueue events for sidecar files (.partial,
            // .emlxpart, the maildir index files, etc).
            guard path.hasSuffix(".emlx") else { return }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0

            // Hop off the FSEvents queue onto the bus actor. The closure
            // is @Sendable and synchronous — we kick a detached Task to
            // do the actual enqueue.
            Task.detached(priority: .utility) {
                let payload = MailAddedPayload(path: path, mtime: mtime)
                do {
                    _ = try await bus.enqueue(
                        type: EventType.mailAdded,
                        source: EventSource.mail,
                        payload: payload,
                        dedupeKey: "mail:\(path)"
                    )
                } catch {
                    NSLog("MailProducer enqueue failed for %@: %@", path, "\(error)")
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
