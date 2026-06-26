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

    /// Single worker drains `message_added` for every messaging source —
    /// the producer tags `events.source` (imessage / whatsapp / …) and
    /// the worker dispatches into the matching per-source service.
    private let imsgProducer: IMessageProducer
    private let whatsappProducer: WhatsAppProducer
    private let messageWorker: MessageIndexWorker
    private let messageRunner: WorkerRunner

    private let fileIndex: FileIndexService
    private let fileProducer: FileProducer
    private let fileWorker: FileIndexWorker
    private let fileRunner: WorkerRunner

    private let imageProducer: ImageProducer
    private let imageWorker: ImageIndexWorker
    private let imageRunner: WorkerRunner

    private let mailProducer: MailProducer
    private let mailWorker: MailIndexWorker
    private let mailRunner: WorkerRunner
    private let mail: AppleMailService

    private let ocrVocabWorker: OCRVocabBackfillWorker
    private let ocrVocabRunner: WorkerRunner
    private let images: ImageIndexService

    init(
        imessage: AppleMessagesService,
        whatsapp: WhatsAppService,
        mail: AppleMailService,
        images: ImageIndexService
    ) {
        let bus = EventBus()
        self.bus = bus
        self.images = images
        self.mail = mail

        self.imsgProducer = IMessageProducer(bus: bus, service: imessage)
        self.whatsappProducer = WhatsAppProducer(bus: bus, service: whatsapp)
        self.messageWorker = MessageIndexWorker(imessage: imessage, whatsapp: whatsapp)
        self.messageRunner = WorkerRunner(bus: bus, worker: messageWorker)

        self.mailProducer = MailProducer(bus: bus, mailBase: mail.mailBase)
        self.mailWorker = MailIndexWorker(mail: mail)
        self.mailRunner = WorkerRunner(bus: bus, worker: mailWorker)

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

        self.ocrVocabWorker = OCRVocabBackfillWorker(images: images)
        self.ocrVocabRunner = WorkerRunner(bus: bus, worker: ocrVocabWorker)
    }

    func start() async {
        await imsgProducer.start()
        await whatsappProducer.start()
        await messageRunner.start()
        await fileProducer.start()
        await fileRunner.start()
        await imageProducer.start()
        await imageRunner.start()
        await mailProducer.start()
        await mailRunner.start()
        await ocrVocabRunner.start()
        // Seed the spellfix1 vocab backfill into the queue. Cheap when
        // the meta flag has already been flipped — early-returns inside
        // the service — so safe to call on every launch.
        Task.detached(priority: .utility) { [bus, images] in
            await images.enqueueOCRVocabBackfillIfNeeded(bus: bus)
        }
        // Mail bootstrap: walk every .emlx into the mirror once per
        // launch. Detached so it doesn't block the pipeline start;
        // FSEvents picks up anything that arrives mid-walk and the
        // dedupe key collapses overlap with bootstrap rows.
        Task.detached(priority: .utility) { [mail] in
            await mail.bootstrap()
        }

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
