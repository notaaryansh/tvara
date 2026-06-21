import Foundation

/// Consumes `file_added` events and stores path metadata in
/// `FileIndexService`. Files that no longer exist by the time we get to
/// them complete cleanly — they're not errors, just transient downloads.
final class FileIndexWorker: EventWorker, @unchecked Sendable {
    let eventType = EventType.fileAdded
    let batchSize = 50
    let pollInterval: TimeInterval = 2.0

    private let index: FileIndexService

    init(index: FileIndexService) {
        self.index = index
    }

    func process(_ event: Event) async throws {
        guard let payload = event.decode(FileAddedPayload.self) else {
            throw NSError(
                domain: "FileIndexWorker", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "payload decode failed"]
            )
        }
        // upsert returns false for missing paths — treat as success since
        // the file was deleted before we got here (common with browser
        // download flows). No error to retry.
        _ = await index.upsert(path: payload.path)
    }
}
