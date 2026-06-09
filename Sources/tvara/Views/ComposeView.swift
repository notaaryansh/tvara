import SwiftUI

/// Thin router for the compose flow. Delegates per-verb rendering to the
/// `ComposeVerbRegistry` — adding a new verb does NOT require editing this
/// file. The only verb-agnostic UI that lives here is the planning spinner
/// and the post-send confirmation banner.
struct ComposeView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let state = viewModel.composeState {
                content(for: state)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: viewModel.composeState?.stage)
    }

    @ViewBuilder
    private func content(for state: ComposeState) -> some View {
        switch state.stage {
        case .planning:
            planningView
        case .ready, .sending:
            // Compose card stays mounted during .sending so the button can
            // morph into a spinner in place — feels native instead of the
            // whole panel flipping over. Registry returns the right verb
            // view; falls back to EmptyView if no verb claims this state
            // (which should be unreachable unless the planner returned
            // garbage).
            if let verb = ComposeVerbRegistry.verb(for: state) {
                verb.makeView(state: state, viewModel: viewModel)
            } else {
                EmptyView()
            }
        case .sent:
            sentView(for: state.kind)
        }
    }

    // MARK: - Planning (waiting on OpenAI)

    private var planningView: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text("Planning your action…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Sent confirmation

    @State private var checkScale: CGFloat = 0.5
    @State private var checkOpacity: Double = 0

    @ViewBuilder
    private func sentView(for kind: ComposeKind?) -> some View {
        switch kind {
        case .sendMessage(let m):
            sentBanner(title: m.recipientName.isEmpty
                ? "Sent" : "Sent to \(m.recipientName)",
                       subtitle: "Delivered via \(m.platform.displayName)")
        case .createEvent(let e):
            sentBanner(
                title: "Event created",
                subtitle: "\(e.title) · \(e.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))"
            )
        case .none:
            sentBanner(title: "Done", subtitle: "")
        }
    }

    private func sentBanner(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.green)
                    .scaleEffect(checkScale)
                    .opacity(checkOpacity)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.green.opacity(0.05))
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                checkScale = 1.0
                checkOpacity = 1.0
            }
        }
    }
}
