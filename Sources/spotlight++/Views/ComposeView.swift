import SwiftUI

/// Compose panel shown when the user has triggered an action on a selected
/// result and the planner returned a structured ComposeAction. Pure UI for
/// v1 — the Send button animates but doesn't actually transmit anything.
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
            // whole panel flipping over.
            switch state.kind {
            case .sendMessage(let msg):
                readyView(action: msg,
                          sourceSnippet: state.sourceSnippet,
                          sending: state.stage == .sending)
            case .createEvent(let ev):
                CalendarComposeView(
                    viewModel: viewModel,
                    event: ev,
                    sourceSnippet: state.sourceSnippet,
                    sending: state.stage == .sending
                )
            case .none:
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

    // MARK: - Ready (editable compose card)

    private func readyView(action: MessageAction, sourceSnippet: String, sending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            contextCard(snippet: sourceSnippet)
            contactCard(action: action)
            editor(action: action)
                .disabled(sending)
                .opacity(sending ? 0.6 : 1.0)
            buttons(sending: sending)
        }
        .padding(20)
    }

    private func contextCard(snippet: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            Text("Based on: ")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            + Text(snippet)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .lineLimit(2)
    }

    private func contactCard(action: MessageAction) -> some View {
        HStack(spacing: 12) {
            avatar(data: action.contactAvatar, platform: action.platform)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.recipientName.isEmpty ? "(no contact)" : action.recipientName)
                    .font(.system(size: 15, weight: .semibold))
                Text(action.platform.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func avatar(data: Data?, platform: ComposePlatform) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.purple.opacity(0.7), Color.blue.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    )
            }
            Image(systemName: platform.badgeIcon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(platformColor(platform))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
        }
    }

    private func platformColor(_ p: ComposePlatform) -> Color {
        switch p {
        case .whatsapp: return Color(red: 0.15, green: 0.78, blue: 0.42)
        case .imessage: return Color(red: 0.16, green: 0.72, blue: 0.35)
        case .discord:  return Color(red: 0.35, green: 0.40, blue: 0.95)
        case .mail:     return Color(red: 0.16, green: 0.45, blue: 0.95)
        }
    }

    private func editor(action: MessageAction) -> some View {
        // Bind through the viewModel so edits propagate to composeState.kind.
        let binding = Binding<String>(
            get: {
                if case .sendMessage(let m) = viewModel.composeState?.kind { return m.content }
                return ""
            },
            set: { viewModel.updateComposeContent($0) }
        )
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
            TextEditor(text: binding)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(10)
        }
        .frame(minHeight: 100, maxHeight: 160)
    }

    private func buttons(sending: Bool) -> some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: { viewModel.cancelCompose() }) {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .disabled(sending)

            Button(action: { viewModel.confirmSend() }) {
                HStack(spacing: 6) {
                    if sending {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                            .tint(.white)
                        Text("Sending…")
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Send")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .frame(minWidth: 96)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(
                            colors: sending
                                ? [Color.blue.opacity(0.6), Color.blue.opacity(0.5)]
                                : [Color.blue, Color.blue.opacity(0.85)],
                            startPoint: .top, endPoint: .bottom
                        ))
                )
                .animation(.easeOut(duration: 0.18), value: sending)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(sending)
        }
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
