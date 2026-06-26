import Foundation

/// Canonical strings stored in `events.type`. Producers and workers agree
/// on these so the queue is loosely coupled — anyone speaking this vocab
/// can join the bus.
enum EventType {
    static let messageAdded = "message_added"
    static let fileAdded = "file_added"
    static let imageAdded = "image_added"
    static let mailAdded = "mail_added"
    static let ocrVocabBackfill = "ocr_vocab_backfill"
}

/// Canonical strings stored in `events.source`.
enum EventSource {
    static let imessage = "imessage"
    static let discord = "discord"
    static let whatsapp = "whatsapp"
    static let mail = "mail"
    static let fs = "fs"
}

// MARK: - Typed payloads

struct MessageAddedPayload: Codable {
    /// ROWID in the source chat database (for iMessage: chat.db's message.ROWID).
    let rowid: Int64
    let chatId: String?
}

struct FileAddedPayload: Codable {
    let path: String
}

struct ImageAddedPayload: Codable {
    let path: String
}

/// One `.emlx` file landing in Mail's storage tree. mtime travels with the
/// payload so the worker can avoid re-parsing already-indexed files
/// without touching the filesystem.
struct MailAddedPayload: Codable {
    let path: String
    let mtime: Double
}

/// One image's contribution to the spellfix1 OCR vocab. Carries just the
/// `images.id` — the worker re-reads the OCR text inside the actor so we
/// never hold thousands of full OCR strings in memory at once.
struct OCRVocabBackfillPayload: Codable {
    let imageID: Int64
}

// MARK: - Codable convenience

extension EventBus {
    /// JSON-encode then enqueue. Returns the new row id, nil on dedupe,
    /// or throws on a real persistence/encoding failure so producers can
    /// decline to advance their watermark.
    @discardableResult
    func enqueue<P: Codable>(
        type: String,
        source: String,
        payload: P,
        dedupeKey: String? = nil
    ) throws -> Int64? {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EventBusError.encodeFailure
        }
        return try enqueue(type: type, source: source, payload: json, dedupeKey: dedupeKey)
    }
}

extension Event {
    /// Decode `payload` as the given Codable type. Returns nil on JSON failure.
    func decode<T: Codable>(_ type: T.Type) -> T? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
