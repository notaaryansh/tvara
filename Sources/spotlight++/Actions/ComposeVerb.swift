import SwiftUI

/// A compose verb — one action that can be invoked from the compose flow
/// (Calendar event creation, iMessage send, Mail compose, ...).
///
/// Each verb owns its own payload model, SwiftUI compose view, and executor.
/// The registry holds a flat list of verbs, so adding a new one is:
///
///   1. `mkdir Actions/<NewVerb>/`
///   2. Define a payload, view, executor, and a `<NewVerb>Verb` conforming
///      to this protocol.
///   3. Append it to `ComposeVerbRegistry.all`.
///
/// The protocol intentionally erases concrete payload / View types: the
/// registry holds `[any ComposeVerb]` so it can iterate uniformly. Each
/// verb pattern-matches on the `ComposeState.kind` it knows about and
/// returns nil / no-ops for kinds it doesn't handle.
@MainActor
protocol ComposeVerb {
    /// Stable identifier used by the planner to select this verb and by
    /// the registry for lookup. Lowercase, no spaces (e.g. "calendar",
    /// "message").
    var id: String { get }

    /// User-facing name shown wherever the verb is labeled. Kept on the
    /// verb itself (not on the payload) so display strings live next to
    /// the verb definition.
    var displayName: String { get }

    /// Returns true if this verb can handle the kind currently stored in
    /// `state.kind`. Used by the registry to route a compose state to the
    /// right verb.
    func handles(_ state: ComposeState) -> Bool

    /// Builds the SwiftUI view for the given state. Verbs return `AnyView`
    /// to allow the registry to hold a heterogeneous list. Called only
    /// after `handles(state:)` returns true.
    func makeView(state: ComposeState, viewModel: SearchViewModel) -> AnyView

    /// Execute the verb against the payload in the state. Returning
    /// normally indicates success; throwing signals a hard failure the
    /// UI should surface. Called only after `handles(state:)` returns true.
    func execute(state: ComposeState) async throws
}
