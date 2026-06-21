import Foundation

/// Consumes `image_added` events and runs the per-image MobileCLIP-S2 +
/// Vision pipeline in `ImageIndexService.indexPath(_:)`.
///
/// `batchSize` is intentionally low because each image triggers CoreML
/// inference; we want to interleave with `search` calls (also serialised
/// through the service actor) rather than blocking it for minutes.
final class ImageIndexWorker: EventWorker, @unchecked Sendable {
    let eventType = EventType.imageAdded
    let batchSize = 5
    let pollInterval: TimeInterval = 3.0

    private let images: ImageIndexService

    init(images: ImageIndexService) {
        self.images = images
    }

    func process(_ event: Event) async throws {
        guard let payload = event.decode(ImageAddedPayload.self) else {
            throw NSError(
                domain: "ImageIndexWorker", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "payload decode failed"]
            )
        }
        await images.indexPath(payload.path)
    }
}
