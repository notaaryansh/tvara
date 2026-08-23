import Foundation

/// Drains `mail_added` events. Each event carries one `.emlx` path; the
/// worker batches the claim and calls `AppleMailService.indexEmlxPaths`
/// once per batch so the FTS5 transaction overhead amortises.
final class MailIndexWorker: EventWorker, @unchecked Sendable {
    let eventType = EventType.mailAdded
    let batchSize = 50
    let pollInterval: TimeInterval = 3.0

    private let mail: AppleMailService

    init(mail: AppleMailService) {
        self.mail = mail
    }

    /// Single-event fallback. Default `processBatch` calls this if we
    /// don't override — but we do (below) so this only fires on the very
    /// unlikely single-event claim.
    func process(_ event: Event) async throws {
        _ = await processBatch([event])
    }

    func processBatch(_ events: [Event]) async -> [BatchResult] {
        var paths: [(id: Int64, path: String)] = []
        var out: [BatchResult] = []
        out.reserveCapacity(events.count)

        for e in events {
            guard let p = e.decode(MailAddedPayload.self), !p.path.isEmpty else {
                out.append(BatchResult(
                    id: e.id,
                    error: NSError(
                        domain: "MailIndexWorker", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "payload decode failed"]
                    )
                ))
                continue
            }
            paths.append((id: e.id, path: p.path))
        }

        guard !paths.isEmpty else { return out }

        let pathOnly = paths.map(\.path)
        do {
            try await mail.indexEmlxPaths(pathOnly)
            for entry in paths {
                out.append(BatchResult(id: entry.id, error: nil))
            }
        } catch {
            for entry in paths {
                out.append(BatchResult(id: entry.id, error: error))
            }
        }
        return out
    }
}
