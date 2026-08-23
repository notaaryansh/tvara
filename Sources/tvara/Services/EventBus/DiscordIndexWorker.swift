import Foundation

/// Drains `discord_scan` events. Each event is a coalesced "Discord cache
/// changed within bucket N" signal, not per-message metadata — the worker
/// just calls `DiscordService.indexFromCache()`, which does its own
/// `lastBuildTime`-gated incremental walk.
///
/// Because the producer's dedupe key collapses bursts within a single
/// time bucket, the worker rarely sees more than one event per bucket,
/// and even if a stale bucket reappears the indexFromCache call is
/// idempotent.
final class DiscordIndexWorker: EventWorker, @unchecked Sendable {
    let eventType = EventType.discordScan
    let batchSize = 5
    let pollInterval: TimeInterval = 3.0

    private let discord: DiscordService

    init(discord: DiscordService) {
        self.discord = discord
    }

    func process(_ event: Event) async throws {
        await discord.indexFromCache()
    }
}
