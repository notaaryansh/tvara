import Foundation

/// Polls WhatsApp's `ChatStorage.sqlite` for new `ZWAMESSAGE.Z_PK` rows and
/// enqueues one `message_added` event per new row, tagged with
/// `EventSource.whatsapp`. Dedupe key `whatsapp:<zpk>` makes re-emission
/// safe across crashes/restarts.
///
/// Watermark is in-memory only — initialised from
/// `WhatsAppService.currentMessageWatermark()` (the max Z_PK already in
/// the mirror). On first launch the watermark is 0 and the producer fans
/// out one event per existing message into the queue; the worker drains
/// those in batches and the mirror bootstraps incrementally without
/// blocking startup.
actor WhatsAppProducer {
    private let bus: EventBus
    private let service: WhatsAppService
    private var lastEmittedZPK: Int64 = -1
    private var task: Task<Void, Never>?

    /// 5s matches IMessageProducer. ChatStorage.sqlite copies are small
    /// (~tens of MB even for power users), so the per-tick cost is low.
    static let pollInterval: TimeInterval = 5.0

    /// Bound the per-tick fanout. On first launch the watermark is 0 and
    /// the producer would otherwise enqueue every existing message in one
    /// tick — a few hundred thousand events on an active account. Capping
    /// at 1000 per tick keeps the EventBus' SQLite INSERT batch sane and
    /// gives the worker a chance to drain in parallel.
    static let perTickLimit: Int = 1000

    init(bus: EventBus, service: WhatsAppService) {
        self.bus = bus
        self.service = service
    }

    /// Idempotent.
    func start() {
        guard task == nil else { return }
        let bus = self.bus
        let service = self.service
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.tick(bus: bus, service: service)
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.pollInterval * 1_000_000_000)
                )
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick(bus: EventBus, service: WhatsAppService) async {
        if lastEmittedZPK < 0 {
            lastEmittedZPK = await service.currentMessageWatermark()
        }
        let newIds = await service.fetchNewZPKs(
            since: lastEmittedZPK, limit: Self.perTickLimit
        )
        guard !newIds.isEmpty else { return }

        for id in newIds {
            let payload = MessageAddedPayload(rowid: id, chatId: nil)
            do {
                _ = try await bus.enqueue(
                    type: EventType.messageAdded,
                    source: EventSource.whatsapp,
                    payload: payload,
                    dedupeKey: "whatsapp:\(id)"
                )
                if id > lastEmittedZPK { lastEmittedZPK = id }
            } catch {
                NSLog("WhatsAppProducer enqueue failed at zpk=%lld: %@", id, "\(error)")
                return
            }
        }
    }
}
