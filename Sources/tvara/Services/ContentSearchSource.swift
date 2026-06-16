import Foundation

/// Common shape for the SQLite-backed content sources that all
/// contribute to a single blended section AND go through the same
/// fan-out pattern in `SearchViewModel.runKeywordSearch`:
/// `await service.search(...)`, run the frequency reranker against the
/// selection history, assign to a `@Published` array.
///
/// Conforming today: Mail / Notes / iMessage / Discord / WhatsApp /
/// Clipboard / Files. The remaining services (Notion, Browser, Image,
/// Linear, Spotify) each have a quirk — folded into another section,
/// blacklisted from the reranker, different signature, semantic rerank
/// path — that doesn't fit cleanly here, so they stay as their own Tasks.
///
/// Every conforming service is already an `actor`, so the protocol is
/// declared `Sendable` and its single requirement is `async`. Conformance
/// is an empty extension per service — every impl already has the right
/// signature; we just promise the compiler it does.
protocol ContentSearchSource: Sendable {
    func search(query: String, limit: Int) async -> [SearchResult]
}

extension AppleMailService:        ContentSearchSource {}
extension AppleMessagesService:    ContentSearchSource {}
extension AppleNotesService:       ContentSearchSource {}
extension ClipboardHistoryService: ContentSearchSource {}
extension DiscordService:          ContentSearchSource {}
extension FileSearchService:       ContentSearchSource {}
extension WhatsAppService:         ContentSearchSource {}
