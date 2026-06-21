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

    init(imessage: AppleMessagesService) {
        self.imessage = imessage
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
    /// Any decode/SQLite failure surfaces as an error for every event in
    /// that bucket so the bus retries them with backoff.
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
                do {
                    try await imessage.indexRowIds(rowids)
                    for entry in entries {
                        out.append(BatchResult(id: entry.id, error: nil))
                    }
                } catch {
                    // Transient chat.db copy / sqlite failure — let the
                    // bus retry the whole batch rather than silently
                    // dropping the events.
                    for entry in entries {
                        out.append(BatchResult(id: entry.id, error: error))
                    }
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
