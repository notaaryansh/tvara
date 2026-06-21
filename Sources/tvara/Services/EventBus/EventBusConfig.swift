import Foundation

/// Runtime knobs for the push-based ingestion pipeline. v1 keeps legacy
/// pull-refresh on as a safety net while the queue bakes. Flip to false
/// once the queue path has proven itself across all migrated sources
/// and the cold-start backfill story is settled.
///
/// Read at call sites in `refreshIfNeeded()`-style methods that have a
/// queue equivalent.
enum EventBusConfig {
    /// When true, services that have been migrated to the queue still
    /// run their legacy `refreshIfNeeded()` path. Provides belt-and-
    /// suspenders during the migration: if the queue is silently
    /// missing events, the legacy path catches it on the next search.
    ///
    /// Set to false once the queue is trusted for the migrated source.
    static var legacyPullRefreshEnabled: Bool = true
}
