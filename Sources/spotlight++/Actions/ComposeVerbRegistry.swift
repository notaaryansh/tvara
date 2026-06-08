import Foundation

/// Single source of truth for the set of compose verbs the app supports.
///
/// To add a new verb: append one line to `all`. No other call site needs to
/// know about the new verb — `ComposeView` and `SearchViewModel` consult
/// the registry to route by `handles(state:)`.
///
/// Deliberately not a runtime plugin system: this is a single-binary Swift
/// app, the cost of recompilation is zero, and "loadable at runtime" would
/// be massive over-engineering for the value we'd get.
@MainActor
enum ComposeVerbRegistry {

    /// All verbs known to the app, in stable order. Order matters only when
    /// two verbs would claim the same state — first match wins. In practice
    /// each verb handles a disjoint `ComposeKind` so order is cosmetic.
    static let all: [any ComposeVerb] = [
        CalendarVerb(),
        MessageVerb(),
    ]

    /// Look up a verb by its stable id. Returns nil if the id isn't known
    /// — caller should treat this as a programmer error.
    static func verb(withId id: String) -> (any ComposeVerb)? {
        all.first(where: { $0.id == id })
    }

    /// Find the verb that claims the given compose state. Returns the first
    /// verb whose `handles(state:)` returns true; nil if none match.
    static func verb(for state: ComposeState) -> (any ComposeVerb)? {
        all.first(where: { $0.handles(state) })
    }
}
