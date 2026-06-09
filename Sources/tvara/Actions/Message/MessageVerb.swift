import SwiftUI

/// The message compose verb. Routes a MessageAction payload to the right
/// platform-specific executor. Only iMessage actually sends today; other
/// platforms (WhatsApp, Discord, Mail) are UI-only stubs that confirmSend
/// handles with a 600ms fake-delivery delay — keep this stub here too so
/// the verb stays consistent with that contract.
///
/// iMessage send is not implemented in `execute(state:)` because it needs
/// AppleMessagesService for handle resolution — that dependency lives on
/// SearchViewModel today. `SearchViewModel.confirmSend` still handles the
/// real iMessage path; the verb's execute is reserved for platforms whose
/// payload is self-contained.
@MainActor
struct MessageVerb: ComposeVerb {
    let id = "message"
    let displayName = "Message"

    func handles(_ state: ComposeState) -> Bool {
        guard case .sendMessage = state.kind else { return false }
        return true
    }

    func makeView(state: ComposeState, viewModel: SearchViewModel) -> AnyView {
        guard case .sendMessage(let msg) = state.kind else {
            return AnyView(EmptyView())
        }
        return AnyView(MessageComposeView(
            viewModel: viewModel,
            action: msg,
            sourceSnippet: state.sourceSnippet,
            sending: state.stage == .sending
        ))
    }

    func execute(state: ComposeState) async throws {
        // iMessage send currently routed through SearchViewModel.confirmSend
        // because it needs the messages service for handle resolution. This
        // method intentionally no-ops so the registry contract is satisfied
        // without claiming a path that lives elsewhere.
    }
}
