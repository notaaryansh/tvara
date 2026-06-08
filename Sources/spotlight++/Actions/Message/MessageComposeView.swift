import SwiftUI

/// Compose panel for the message verb. Pure UI: contact card, editable
/// message body, Cancel/Send buttons. The Send button binding lives on
/// the ViewModel (`confirmSend`) so the panel and the receiving end agree
/// on what's being sent.
struct MessageComposeView: View {
    @ObservedObject var viewModel: SearchViewModel
    let action: MessageAction
    let sourceSnippet: String
    let sending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            contextCard
            contactCard
            editor
                .disabled(sending)
                .opacity(sending ? 0.6 : 1.0)
            buttons
        }
        .padding(20)
    }

    private var contextCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            Text("Based on: ")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            + Text(sourceSnippet)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .lineLimit(2)
    }

    private var contactCard: some View {
        HStack(spacing: 12) {
            avatar
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

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            if let data = action.contactAvatar, let img = NSImage(data: data) {
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
            Image(systemName: action.platform.badgeIcon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(platformColor)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
        }
    }

    private var platformColor: Color {
        switch action.platform {
        case .whatsapp: return Color(red: 0.15, green: 0.78, blue: 0.42)
        case .imessage: return Color(red: 0.16, green: 0.72, blue: 0.35)
        case .discord:  return Color(red: 0.35, green: 0.40, blue: 0.95)
        case .mail:     return Color(red: 0.16, green: 0.45, blue: 0.95)
        }
    }

    private var editor: some View {
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

    private var buttons: some View {
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
}
