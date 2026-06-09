import Foundation

/// Reorders results by usage frequency, *within each source band*, then
/// rewrites each result's `rank` int so the ViewModel's downstream merge
/// sort (`rankSort`) preserves the new ordering.
///
/// **Why within-band only.** Source ranks live in disjoint ranges by
/// convention (e.g. window/system commands sit around 920+, content
/// results sit lower). A globally-applied frequency boost could push a
/// heavily-clicked content result past a command, which would feel wrong
/// — commands belong on top because they're terminal intents. Within-band
/// reranking keeps the rank-range envelope intact for each source.
///
/// **Rank rewrite mechanic.** For each source group we extract the
/// original rank values, sort them descending, then assign them to the
/// frequency-sorted results in order — top-frequency gets the group's
/// highest original rank, next gets second-highest, etc. The group's
/// rank set is unchanged; only the assignment to results within it
/// changes. Downstream `rankSort` is none the wiser.
///
/// **Skip rule.** A source whose first result has no `stableId`
/// (blacklisted source type — system / window / images) is skipped
/// entirely; results retain their original ranks.
///
/// Pure function. No side effects, no I/O. Test by passing synthetic
/// inputs.
enum FrequencyReranker {

    /// Reorder `results` using `history`, rewriting `rank` fields so the
    /// ViewModel's merge sort respects the new order. Results are
    /// returned in the same overall order as the input — only the rank
    /// fields change.
    static func apply(
        to results: [SearchResult],
        history: [String: SelectionHistoryEntry]
    ) -> [SearchResult] {
        if results.isEmpty { return results }

        // Group by source while remembering each result's original index
        // so we can return the list in its input order with rewritten ranks.
        var indicesBySource: [SearchResult.Source: [Int]] = [:]
        for (idx, r) in results.enumerated() {
            indicesBySource[r.source, default: []].append(idx)
        }

        // Build the rewritten array. Start as a copy of the input; we'll
        // overwrite specific positions with rank-rewritten clones.
        var out = results

        for (_, indices) in indicesBySource {
            // Skip groups whose results aren't trackable (blacklisted
            // sources have nil stableId for every row). The "any nil" check
            // is intentionally strict — mixed-stableId groups also skip,
            // erring toward "do nothing" rather than partial reorderings
            // that could surprise the user.
            if indices.contains(where: { results[$0].stableId == nil }) {
                continue
            }

            // Build (originalIndex, history) pairs for sorting.
            let pairs: [(idx: Int, entry: SelectionHistoryEntry?)] = indices.map {
                ($0, results[$0].stableId.flatMap { history[$0] })
            }

            // Frequency-sort: count DESC, lastSelectedAt DESC, base_rank DESC.
            // The .sorted(by:) is stable (per Swift docs) so ties on all
            // three keys preserve input order.
            let sortedIndices = pairs
                .sorted { a, b in
                    let ac = a.entry?.count ?? 0
                    let bc = b.entry?.count ?? 0
                    if ac != bc { return ac > bc }
                    let at = a.entry?.lastSelectedAt ?? 0
                    let bt = b.entry?.lastSelectedAt ?? 0
                    if at != bt { return at > bt }
                    return results[a.idx].rank > results[b.idx].rank
                }
                .map { $0.idx }

            // Original ranks of this group, sorted descending. We'll
            // re-assign them in this order onto the frequency-sorted
            // results.
            let originalRanksDesc = indices.map { results[$0].rank }.sorted(by: >)

            // Pair them up: positionally, the top frequency-sorted result
            // gets the highest original rank, etc.
            for (newPos, originalIdx) in sortedIndices.enumerated() {
                let newRank = originalRanksDesc[newPos]
                out[originalIdx] = results[originalIdx].withRank(newRank)
            }
        }

        return out
    }
}
