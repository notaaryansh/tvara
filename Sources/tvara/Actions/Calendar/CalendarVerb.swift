import SwiftUI

/// The calendar compose verb. Owns its payload (EventAction), its compose
/// view (CalendarComposeView), and its executor (CalendarEventSaver).
@MainActor
struct CalendarVerb: ComposeVerb {
    let id = "calendar"
    let displayName = "Calendar"

    func handles(_ state: ComposeState) -> Bool {
        guard case .createEvent = state.kind else { return false }
        return true
    }

    func makeView(state: ComposeState, viewModel: SearchViewModel) -> AnyView {
        guard case .createEvent(let ev) = state.kind else {
            return AnyView(EmptyView())
        }
        return AnyView(CalendarComposeView(
            viewModel: viewModel,
            event: ev,
            sourceSnippet: state.sourceSnippet,
            sending: state.stage == .sending
        ))
    }

    func execute(state: ComposeState) async throws {
        guard case .createEvent(let ev) = state.kind else { return }
        try await CalendarEventSaver.save(ev)
    }
}
