import AppKit
import SwiftUI

struct SearchResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    var highlightQuery: String = ""

    private var isApp: Bool { result.source == .app }
    private var isMessage: Bool {
        result.source == .whatsapp || result.source == .discord
        || result.source == .imessage || result.source == .mail
    }
    private var isDiscord: Bool { result.source == .discord }
    private var isMail: Bool { result.source == .mail }

    var body: some View {
        HStack(alignment: isMessage ? .top : .center, spacing: 12) {
            iconBadge
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(result.displayTitle)
                        .font(.system(size: isApp ? 15 : 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isDiscord, let channelLabel = result.badge {
                        Text(channelLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if !isApp {
                    Text(highlightedSubtitle)
                        .lineLimit(isMessage ? 2 : 1)
                        .truncationMode(isMessage ? .tail : .middle)
                        .fixedSize(horizontal: false, vertical: isMessage)
                }
            }
            Spacer(minLength: 8)
            trailingMeta
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var iconBadge: some View {
        switch result.openTarget {
        case .file(let path):
            FileIconView(path: path)
                .frame(width: 36, height: 36)
        case .whatsappChat:
            messageAvatar(platformBadge: Self.whatsappBadgeIcon)
        case .imessageChat:
            messageAvatar(platformBadge: Self.messagesBadgeIcon)
        case .url:
            if isDiscord {
                messageAvatar(platformBadge: Self.discordBadgeIcon)
            } else if isMail {
                messageAvatar(platformBadge: Self.mailBadgeIcon)
            } else if let data = result.iconData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                    .frame(width: 36, height: 36)
            } else {
                tintedBadge
            }
        }
    }

    private static let discordBadgeIcon: NSImage =
        NSWorkspace.shared.icon(forFile: "/Applications/Discord.app")
    private static let messagesBadgeIcon: NSImage =
        NSWorkspace.shared.icon(forFile: "/System/Applications/Messages.app")
    private static let mailBadgeIcon: NSImage =
        NSWorkspace.shared.icon(forFile: "/System/Applications/Mail.app")

    /// Circular avatar (or initial-letter placeholder) + small platform logo
    /// badge in the bottom-right corner. Same pattern for WhatsApp, Discord,
    /// future Slack/Telegram/etc — just swap the badge icon.
    private func messageAvatar(platformBadge: NSImage) -> some View {
        ZStack(alignment: .bottomTrailing) {
            avatarCircle
            Image(nsImage: platformBadge)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .offset(x: 2, y: 2)
        }
        .frame(width: 36, height: 36)
    }

    private static let whatsappBadgeIcon: NSImage =
        NSWorkspace.shared.icon(forFile: "/Applications/WhatsApp.app")

    @ViewBuilder
    private var avatarCircle: some View {
        if let data = result.iconData, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        } else {
            // Placeholder: tinted circle with the chat name's first letter.
            ZStack {
                Circle().fill(avatarPlaceholderColor)
                Text(initial(from: result.displayTitle))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
        }
    }

    private var avatarPlaceholderColor: Color {
        // Deterministic per-chat tint so the same name always gets the same color.
        let hash = result.displayTitle.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let palette: [Color] = [
            Color(red: 0.45, green: 0.55, blue: 0.85),
            Color(red: 0.85, green: 0.45, blue: 0.55),
            Color(red: 0.45, green: 0.80, blue: 0.65),
            Color(red: 0.85, green: 0.65, blue: 0.40),
            Color(red: 0.65, green: 0.50, blue: 0.85),
            Color(red: 0.50, green: 0.70, blue: 0.85)
        ]
        return palette[abs(hash) % palette.count]
    }

    private func initial(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    private var tintedBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            result.source.tint.opacity(0.95),
                            result.source.tint.opacity(0.65)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 36, height: 36)
            Image(systemName: result.source.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var trailingMeta: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let date = result.date {
                Text(relativeString(date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            // Discord uses `badge` for the "#channel" label which we show
            // inline next to the title — suppress it here to avoid duplication.
            if !isDiscord, let badge = result.badge {
                Text(badge)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func relativeString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private var highlightedSubtitle: AttributedString {
        let base = NSMutableAttributedString()

        // Sender prefix for messages with a distinct author (Discord server
        // channels). Rendered in a brighter color and slightly heavier
        // weight than the message body so the eye lands on it first.
        var bodyOffset = 0
        if let sender = result.senderName, !sender.isEmpty {
            let prefix = "\(sender)  "
            base.append(NSAttributedString(string: prefix, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]))
            bodyOffset = prefix.count
        }

        base.append(NSAttributedString(string: result.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))

        let q = highlightQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1 else { return AttributedString(base) }

        let haystack = result.subtitle.lowercased()
        let needle   = q.lowercased()
        var cursor   = haystack.startIndex

        while cursor < haystack.endIndex,
              let found = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
            let nsRange = NSRange(found, in: haystack)
            // Shift the range into the combined string's coordinate space
            // (we may have prepended a sender prefix above).
            let shifted = NSRange(location: nsRange.location + bodyOffset,
                                  length: nsRange.length)
            base.addAttributes([
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ], range: shifted)
            cursor = found.upperBound
        }
        return AttributedString(base)
    }
}

private struct FileIconView: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSWorkspace.shared.icon(forFile: path)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = NSWorkspace.shared.icon(forFile: path)
    }
}
