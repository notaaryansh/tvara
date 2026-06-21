import Foundation

/// Canonical strings stored in `events.type`. Producers and workers agree
/// on these so the queue is loosely coupled — anyone speaking this vocab
/// can join the bus.
enum EventType {
    static let messageAdded = "message_added"
    static let fileAdded = "file_added"
    static let imageAdded = "image_added"
    static let embedMessage = "embed_message"
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

struct EmbedMessagePayload: Codable {
    let messageId: Int64
    let source: String
}

// MARK: - Codable convenience

extension EventBus {
    /// JSON-encode then enqueue. Returns the new row id, or nil on dedupe.
    @discardableResult
    func enqueue<P: Codable>(
        type: String,
        source: String,
        payload: P,
        dedupeKey: String? = nil
    ) -> Int64? {
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return enqueue(type: type, source: source, payload: json, dedupeKey: dedupeKey)
    }
}

extension Event {
    /// Decode `payload` as the given Codable type. Returns nil on JSON failure.
    func decode<T: Codable>(_ type: T.Type) -> T? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
