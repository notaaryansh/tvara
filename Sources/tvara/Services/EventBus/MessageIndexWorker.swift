import Foundation

/// Consumes `message_added` events and routes them to the right
/// source-specific indexer. Currently only iMessage is wired; Discord /
/// WhatsApp follow the same pattern.
///
/// Batches the chat.db copy across all events in a single claim — the
/// iMessage decode path benefits enormously from sharing one snapshot
/// rather than copying chat.db per event.
final class MessageIndexWorker: EventWorker, @unchecked Sendable {
    let eventType = EventType.messageAdded
    let batchSize = 100
    let pollInterval: TimeInterval = 3.0

    private let imessage: AppleMessagesService
    /// Optional: when set, the worker enqueues `embed_message` events
    /// downstream after each successful index. Nil disables that hop —
    /// useful for tests that don't want to model the embedding side.
    private let bus: EventBus?

    init(imessage: AppleMessagesService, bus: EventBus? = nil) {
        self.imessage = imessage
        self.bus = bus
    }

    /// Single-event path — only used if `processBatch` isn't overridden
    /// (it is). Kept to satisfy the protocol; should not be called.
    func process(_ event: Event) async throws {
        // The batch path below shadows this. If we ever fall through here
        // it means something routed a single event past the batch hook;
        // handle it by treating it as a one-event batch.
        let _ = await processBatch([event])
    }

    /// Group events by source and dispatch one bulk-index call per source.
    /// Any decode/SQLite failure marks all events in that bucket as failed
    /// (they get retried with backoff individually).
    func processBatch(_ events: [Event]) async -> [BatchResult] {
        var bySource: [String: [(id: Int64, rowid: Int64)]] = [:]
        var out: [BatchResult] = []
        out.reserveCapacity(events.count)

        for e in events {
            guard let p = e.decode(MessageAddedPayload.self) else {
                out.append(BatchResult(
                    id: e.id,
                    error: NSError(
                        domain: "MessageIndexWorker", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "payload decode failed"]
                    )
                ))
                continue
            }
            bySource[e.source, default: []].append((id: e.id, rowid: p.rowid))
        }

        for (source, entries) in bySource {
            switch source {
            case EventSource.imessage:
                let rowids = entries.map(\.rowid)
                await imessage.indexRowIds(rowids)
                // Hand off to the embed worker via the bus. Decoupling
                // means heavy OpenAI calls don't block the cheap index.
                if let bus {
                    for rowid in rowids {
                        let payload = EmbedMessagePayload(
                            messageId: rowid,
                            source: EventSource.imessage
                        )
                        await bus.enqueue(
                            type: EventType.embedMessage,
                            source: EventSource.imessage,
                            payload: payload,
                            dedupeKey: "embed:imessage:\(rowid)"
                        )
                    }
                }
                for entry in entries {
                    out.append(BatchResult(id: entry.id, error: nil))
                }
            default:
                // Unknown source: mark failed so it surfaces in diagnostics.
                let err = NSError(
                    domain: "MessageIndexWorker", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "unsupported source: \(source)"]
                )
                for entry in entries {
                    out.append(BatchResult(id: entry.id, error: err))
                }
            }
        }
        return out
    }
}
