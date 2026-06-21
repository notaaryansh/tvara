import Foundation

/// Owns every component of the push-based ingestion pipeline so the
/// objects stay alive for the lifetime of the app.
///
/// Each producer/worker/runner is a reference-counted actor — if the
/// only reference is a local in a `Task.detached` block that returns,
/// they all deallocate the moment setup finishes. Bundling here and
/// holding the bundle on `SearchViewModel` gives them an owner whose
/// lifetime matches the search panel's.
final class EventBusPipeline: @unchecked Sendable {
    let bus: EventBus

    private let imsgProducer: IMessageProducer
    private let imsgWorker: MessageIndexWorker
    private let imsgRunner: WorkerRunner

    private let fileIndex: FileIndexService
    private let fileProducer: FileProducer
    private let fileWorker: FileIndexWorker
    private let fileRunner: WorkerRunner

    private let imageProducer: ImageProducer
    private let imageWorker: ImageIndexWorker
    private let imageRunner: WorkerRunner

    init(
        imessage: AppleMessagesService,
        images: ImageIndexService
    ) {
        let bus = EventBus()
        self.bus = bus

        self.imsgProducer = IMessageProducer(bus: bus, service: imessage)
        self.imsgWorker = MessageIndexWorker(imessage: imessage)
        self.imsgRunner = WorkerRunner(bus: bus, worker: imsgWorker)

        self.fileIndex = FileIndexService()
        self.fileProducer = FileProducer(
            bus: bus,
            watchPaths: FileProducer.defaultWatchPaths()
        )
        self.fileWorker = FileIndexWorker(index: fileIndex)
        self.fileRunner = WorkerRunner(bus: bus, worker: fileWorker)

        self.imageProducer = ImageProducer(
            bus: bus,
            watchPaths: ImageProducer.defaultWatchPaths()
        )
        self.imageWorker = ImageIndexWorker(images: images)
        self.imageRunner = WorkerRunner(bus: bus, worker: imageWorker)
    }

    func start() async {
        await imsgProducer.start()
        await imsgRunner.start()
        await fileProducer.start()
        await fileRunner.start()
        await imageProducer.start()
        await imageRunner.start()

        let depth = await bus.depthByStatus()
        let pending = depth["pending"] ?? 0
        let failed = depth["failed"] ?? 0
        NSLog(
            "EventBus depth at launch: pending=%d failed=%d done=%d",
            pending, failed, depth["done"] ?? 0
        )
        let failures = await bus.recentFailures(limit: 5)
        for f in failures {
            NSLog(
                "EventBus failed event id=%lld type=%@ source=%@",
                f.id, f.type, f.source
            )
        }
    }
}
