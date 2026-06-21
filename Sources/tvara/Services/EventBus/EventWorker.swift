import Foundation

/// A consumer that pulls events of one `eventType` off the bus and indexes them.
///
/// Conformers implement `process(_:)` for single-item handling. Workers that
/// benefit from amortized setup across the batch (e.g. one chat.db copy per
/// claim) can additionally implement `processBatch(_:)` to avoid repeating
/// the setup per event. The default `processBatch` implementation forwards
/// to `process` for each event.
protocol EventWorker: AnyObject, Sendable {
    var eventType: String { get }
    var batchSize: Int { get }
    var pollInterval: TimeInterval { get }

    /// Process one event. Throw to fail the attempt.
    func process(_ event: Event) async throws

    /// Process a claimed batch. Returns one outcome per event id (nil error
    /// = success). Default impl calls `process` per event.
    func processBatch(_ events: [Event]) async -> [BatchResult]
}

/// Outcome for a single event inside a batch.
struct BatchResult: Sendable {
    let id: Int64
    let error: Error?
}

extension EventWorker {
    var batchSize: Int { 25 }
    var pollInterval: TimeInterval { 2.0 }

    func processBatch(_ events: [Event]) async -> [BatchResult] {
        var out: [BatchResult] = []
        out.reserveCapacity(events.count)
        for e in events {
            do {
                try await process(e)
                out.append(BatchResult(id: e.id, error: nil))
            } catch {
                out.append(BatchResult(id: e.id, error: error))
            }
        }
        return out
    }
}

/// Runs an `EventWorker` against an `EventBus` in a background Task.
///
/// Loop: claim → processBatch → complete/fail each → repeat. Empty claims
/// sleep for `pollInterval` before retrying. Cancellation is honoured at
/// every claim boundary.
actor WorkerRunner {
    private let bus: EventBus
    private let worker: any EventWorker
    private var task: Task<Void, Never>?

    init(bus: EventBus, worker: any EventWorker) {
        self.bus = bus
        self.worker = worker
    }

    /// Idempotent — calling twice is a no-op.
    func start() {
        guard task == nil else { return }
        let bus = self.bus
        let worker = self.worker
        task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let batch = await bus.claim(type: worker.eventType, limit: worker.batchSize)
                if batch.isEmpty {
                    try? await Task.sleep(
                        nanoseconds: UInt64(worker.pollInterval * 1_000_000_000)
                    )
                    continue
                }
                let results = await worker.processBatch(batch)
                // Finalize every claimed event before honouring cancellation
                // — bailing out mid-loop would leave processed rows stuck
                // in `processing` until the stale-claim sweep ran.
                // Cancellation takes effect at the next claim boundary.
                for r in results {
                    if let err = r.error {
                        await bus.fail(id: r.id, error: "\(err)")
                    } else {
                        await bus.complete(id: r.id)
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
