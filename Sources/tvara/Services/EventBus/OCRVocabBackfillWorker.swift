import Foundation

/// Consumes `ocr_vocab_backfill` events and feeds each image's OCR tokens
/// into the spellfix1 vocab table via `ImageIndexService.indexOCRVocab`.
///
/// `batchSize` is small on purpose: each event triggers a spellfix1
/// virtual-table insert per distinct OCR token, and those carry a
/// non-trivial in-memory shadow-table cost until commit. Draining a few
/// at a time lets the journal flush before it grows and keeps the actor
/// responsive to interleaved search calls.
final class OCRVocabBackfillWorker: EventWorker, @unchecked Sendable {
    let eventType = EventType.ocrVocabBackfill
    let batchSize = 25
    let pollInterval: TimeInterval = 2.0

    private let images: ImageIndexService

    init(images: ImageIndexService) {
        self.images = images
    }

    func process(_ event: Event) async throws {
        guard let payload = event.decode(OCRVocabBackfillPayload.self) else {
            throw NSError(
                domain: "OCRVocabBackfillWorker", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "payload decode failed"]
            )
        }
        await images.indexOCRVocab(imageID: payload.imageID)
    }
}
