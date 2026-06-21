import Foundation

/// Consumes `embed_message` events, batches them, calls OpenAI's
/// embeddings endpoint, and writes vectors back into `embeddings.db`.
///
/// Mirrors `scripts/embed_messages.py` (same model, same schema, same
/// batch size). The Python script is still the right bulk path for the
/// initial cold-start backfill; this worker handles the steady-state
/// "one message at a time as they arrive" case.
///
/// If `OPENAI_API_KEY` isn't set, the worker silently completes events
/// without embedding. That keeps dev boxes from filling the queue's
/// `failed` bucket — the events are simply skipped rather than burned.
final class EmbedMessageWorker: EventWorker, @unchecked Sendable {
    let eventType = EventType.embedMessage
    let batchSize = 50
    let pollInterval: TimeInterval = 4.0

    /// Skip messages shorter than this — matches the Python script's
    /// `MIN_CHARS = 4` filter. "k", "lol", "ok" make for noisy embeddings
    /// and waste tokens.
    private static let minChars = 4

    private let store: EmbeddingStore
    private let imessage: AppleMessagesService

    init(store: EmbeddingStore, imessage: AppleMessagesService) {
        self.store = store
        self.imessage = imessage
    }

    func process(_ event: Event) async throws {
        let _ = await processBatch([event])
    }

    func processBatch(_ events: [Event]) async -> [BatchResult] {
        guard let key = OpenAIKey.load() else {
            return events.map { BatchResult(id: $0.id, error: nil) }
        }

        var imessageEvents: [(eventId: Int64, rowid: Int64)] = []
        var results: [BatchResult] = []
        results.reserveCapacity(events.count)

        for e in events {
            guard let p = e.decode(EmbedMessagePayload.self) else {
                results.append(BatchResult(
                    id: e.id,
                    error: NSError(
                        domain: "EmbedMessageWorker", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "payload decode failed"]
                    )
                ))
                continue
            }
            switch p.source {
            case EventSource.imessage:
                imessageEvents.append((eventId: e.id, rowid: p.messageId))
            default:
                results.append(BatchResult(
                    id: e.id,
                    error: NSError(
                        domain: "EmbedMessageWorker", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "unsupported source: \(p.source)"]
                    )
                ))
            }
        }

        guard !imessageEvents.isEmpty else { return results }

        let rowids = imessageEvents.map(\.rowid)
        let texts = await imessage.fetchTextForRowIds(rowids)

        var inputs: [String] = []
        var orderedEvents: [(eventId: Int64, rowid: Int64)] = []
        for entry in imessageEvents {
            let text = (texts[entry.rowid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count < Self.minChars {
                // Too short to embed — complete the event so it doesn't loop.
                results.append(BatchResult(id: entry.eventId, error: nil))
                continue
            }
            inputs.append(text)
            orderedEvents.append(entry)
        }

        guard !inputs.isEmpty else { return results }

        do {
            let vectors = try await store.embedBatch(inputs, apiKey: key)
            guard vectors.count == orderedEvents.count else {
                let err = NSError(
                    domain: "EmbedMessageWorker", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "vector count mismatch"]
                )
                for entry in orderedEvents {
                    results.append(BatchResult(id: entry.eventId, error: err))
                }
                return results
            }
            for (entry, vec) in zip(orderedEvents, vectors) {
                await store.upsert(
                    messageId: String(entry.rowid),
                    source: EventSource.imessage,
                    model: EmbeddingStore.model,
                    embedding: vec
                )
                results.append(BatchResult(id: entry.eventId, error: nil))
            }
        } catch {
            for entry in orderedEvents {
                results.append(BatchResult(id: entry.eventId, error: error))
            }
        }
        return results
    }
}

/// Loads the OpenAI API key from environment, then from the project's
/// `.env` file (matching `scripts/embed_messages.py` behaviour).
enum OpenAIKey {
    static func load() -> String? {
        if let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !k.isEmpty {
            return k
        }
        // Walk up from CWD to find a `.env` with `OPENAI_API_KEY=...`.
        var dir = FileManager.default.currentDirectoryPath
        for _ in 0..<6 {
            let candidate = dir + "/.env"
            if let s = try? String(contentsOfFile: candidate, encoding: .utf8) {
                for line in s.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let prefix = "OPENAI_API_KEY="
                    if let r = trimmed.range(of: prefix) {
                        var v = String(trimmed[r.upperBound...])
                        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                        if !v.isEmpty { return v }
                    }
                }
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}
