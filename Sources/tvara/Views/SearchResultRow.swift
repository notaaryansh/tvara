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
            // Image source: render the actual photo thumbnail we baked into
            // iconData at index time. Falls through to FileIconView for any
            // non-image file source.
            if result.source == .images,
               let data = result.iconData,
               let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                FileIconView(path: path)
                    .frame(width: 36, height: 36)
            }
        case .whatsappChat:
            messageAvatar(platformBadge: Self.whatsappBadgeIcon)
        case .imessageChat:
            messageAvatar(platformBadge: Self.messagesBadgeIcon)
        case .copyToClipboard:
            tintedBadge
        case .notesNote:
            tintedBadge   // Notes source already has its yellow tint + note.text icon
        case .spotifyPlay:
            spotifyArtBadge   // remote-loaded album / playlist cover when present
        case .windowAction(let action):
            // The icon IS the preview at small size — schematic of the
            // screen with the target rect filled. Frame matches the
            // 36-square the other badges occupy so row heights stay aligned.
            WindowActionPreview(action: action)
                .frame(width: 36, height: 36)
        case .systemAction:
            // Power-button red tinted badge using the Source.systemAction
            // color + the SF Symbol "power" baked into the source. No
            // schematic preview — the symbol itself is the visual.
            tintedBadge
        case .imagesCollection:
            // SearchView routes the collection row to PhotoCollectionRow
            // and never instantiates SearchResultRow for it, so this case
            // is unreachable in practice. Fall back to the tinted images
            // badge so a future caller that bypasses the router doesn't
            // crash.
            tintedBadge
        case .expandSection:
            // Same story: SearchView routes the expand footer to its
            // own dedicated SeeMoreRow view. Unreachable in practice;
            // keep a small tinted symbol as the safety fallback.
            tintedBadge
        case .url:
            if isDiscord {
                messageAvatar(platformBadge: Self.discordBadgeIcon)
            } else if isMail {
                messageAvatar(platformBadge: Self.mailBadgeIcon)
            } else if let data = result.iconData, let img = NSImage(data: data) {
                // System Settings rows ship a real macOS app icon
                // (gradient + symbol baked in). Render it full-bleed at
                // 36x36 without the favicon bubble — adding the bubble
                // around an already-finished app icon looks like an
                // icon-inside-an-icon.
                if result.source == .settings {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 36, height: 36)
                } else {
                    // Browser favicons are tiny 16-32px PNGs typically
                    // designed to sit on a colored chrome — the soft
                    // bubble + thin border gives them weight.
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
                }
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

    /// Spotify rows: square album/playlist art (AsyncImage if we have a
    /// URL, otherwise green tinted music-note placeholder) PLUS a small
    /// Spotify-app-icon overlay in the bottom-right — same pattern as
    /// the WhatsApp/Discord platform badges on message rows.
    @ViewBuilder
    private var spotifyArtBadge: some View {
        ZStack(alignment: .bottomTrailing) {
            // Base: art or fallback
            Group {
                if let s = result.remoteArtURL, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        default:
                            tintedBadge
                        }
                    }
                } else {
                    tintedBadge
                }
            }
            // Platform badge: Spotify app icon, bottom-right
            Image(nsImage: Self.spotifyBadgeIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .offset(x: 4, y: 4)
        }
        .frame(width: 36, height: 36)
    }

    private static let spotifyBadgeIcon: NSImage =
        NSWorkspace.shared.icon(forFile: "/Applications/Spotify.app")

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
