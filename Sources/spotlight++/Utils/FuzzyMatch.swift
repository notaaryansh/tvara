import Foundation

/// Bounded Levenshtein-distance helper used by command sources as a typo-
/// tolerant fallback when prefix matching returns zero hits.
///
/// The bounded variant tracks the minimum value in each DP row and aborts
/// early when no cell ≤ budget — most non-matches reject in microseconds.
/// Combined with a length-difference pre-check, comparing a query against
/// ~250 aliases stays under 2 ms even on the cold-cache path.
///
/// The budget itself scales with query length so a 2-char nonsense string
/// can't fuzzy-route to a real command — see `budget(for:)`.
enum FuzzyMatch {

    /// Edit distance between `a` and `b` if it's ≤ `budget`, else nil.
    /// Insert / delete / substitute all cost 1 (classic Levenshtein, no
    /// transposition shortcut — keeps the function predictable).
    static func levenshtein(_ a: String, _ b: String, budget: Int) -> Int? {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count

        // Length pre-check: a string of length 4 can never reach length 8
        // in fewer than 4 edits, so any pair where the length gap already
        // exceeds the budget is rejected for free.
        if abs(n - m) > budget { return nil }
        if n == 0 { return m <= budget ? m : nil }
        if m == 0 { return n <= budget ? n : nil }

        // Two-row DP, swapping roles each iteration so we never allocate
        // the full n×m matrix. Memory: 2(m+1) ints.
        var prev = [Int](0...m)
        var curr = [Int](repeating: 0, count: m + 1)

        for i in 1...n {
            curr[0] = i
            var rowMin = curr[0]
            for j in 1...m {
                if aChars[i - 1] == bChars[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = Swift.min(prev[j - 1], prev[j], curr[j - 1]) + 1
                }
                if curr[j] < rowMin { rowMin = curr[j] }
            }
            // Early termination: if every cell in this row already exceeds
            // budget, no extension can recover. Abort.
            if rowMin > budget { return nil }
            swap(&prev, &curr)
        }
        let result = prev[m]
        return result <= budget ? result : nil
    }

    /// Distance budget chosen by query length:
    ///   ≤3 chars  → 0  (no fuzzy — would match random short strings)
    ///   4 chars   → 1  (one realistic typo, no more)
    ///   5+ chars  → 2  (covers most double-typo realistic cases)
    /// Capped at 2 — anything looser blurs into loosely-related strings,
    /// which is the "aldjasfjsafd routes to a real command" failure mode.
    static func budget(for query: String) -> Int {
        switch query.count {
        case 0...3: return 0
        case 4:     return 1
        default:    return 2
        }
    }
}
