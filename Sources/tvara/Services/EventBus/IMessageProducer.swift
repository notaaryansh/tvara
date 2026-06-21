import Foundation

/// Polls Apple Messages' `chat.db` for new ROWIDs and enqueues one
/// `message_added` event per new row. Dedupe key `imessage:<rowid>` makes
/// re-emission safe across crashes/restarts.
///
/// Watermark is in-memory only — initialised from
/// `AppleMessagesService.currentMessageWatermark()` (the legacy decoded-text
/// index high-water mark). Crash recovery: at startup the producer asks the
/// service for its current high-water and starts emitting from there. Any
/// events from the previous run that weren't yet processed will be re-emitted
/// once and silently deduped.
actor IMessageProducer {
    private let bus: EventBus
    private let service: AppleMessagesService
    private var lastEmittedRowId: Int64 = -1
    private var task: Task<Void, Never>?

    /// 5s is the same order of magnitude as the legacy `refreshIfNeeded`
    /// debounce; gives near-immediate freshness without thrashing chat.db.
    static let pollInterval: TimeInterval = 5.0

    init(bus: EventBus, service: AppleMessagesService) {
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

    private func tick(bus: EventBus, service: AppleMessagesService) async {
        if lastEmittedRowId < 0 {
            lastEmittedRowId = await service.currentMessageWatermark()
        }
        let newIds = await service.fetchNewRowIds(since: lastEmittedRowId)
        guard !newIds.isEmpty else { return }

        for id in newIds {
            let payload = MessageAddedPayload(rowid: id, chatId: nil)
            await bus.enqueue(
                type: EventType.messageAdded,
                source: EventSource.imessage,
                payload: payload,
                dedupeKey: "imessage:\(id)"
            )
            if id > lastEmittedRowId { lastEmittedRowId = id }
        }
    }
}
