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
        .background(RowRendering.selectionBackground(isSelected))
        .contentShape(Rectangle())
        // Subtle visual treatment for fuzzy results so the user can
        // tell at a glance that "Did you mean?" results are below the
        // exact matches. Dimming the whole row by 25% reads as quieter
        // chrome without breaking layout or icon legibility.
        .opacity(result.isFuzzyMatch ? 0.7 : 1.0)
    }

    @ViewBuilder
    private var iconBadge: some View {
        switch result.openTarget {
        case .file(let path):
            // Image source: render the actual photo thumbnail we baked into
            // iconData at index time.
            if result.source == .images,
               let data = result.iconData,
               let img = RowRendering.image(from: data) {
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
            } else if result.source == .app,
                      let data = result.iconData,
                      let img = RowRendering.image(from: data) {
                // App source: render the pre-decoded PNG that
                // AppIconStore baked at warm time. Bypasses
                // FileIconView/IconCache's lazy `.icns` decode so the
                // icon lands in the same frame as the row instead of
                // popping in one frame later.
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
            } else {
                // Fallback for non-image, non-app file rows (and the
                // brief window on first launch before the app icon
                // cache has populated). IconCache keeps the decoded
                // image so repeat renders are warm.
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
            } else if let data = result.iconData, let img = RowRendering.image(from: data) {
                // Real macOS app icons (System Settings, Notion, Linear,
                // …) ship a complete gradient + symbol — render them
                // full-bleed at 36x36 without the favicon bubble.
                // Wrapping an already-finished app icon in a chrome
                // background looks like an icon-inside-an-icon.
                if Self.fullBleedAppIconSources.contains(result.source) {
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

    /// Sources whose `iconData` is a real macOS app icon (full gradient +
    /// symbol baked in) rather than a tiny favicon. The `.url` openTarget
    /// renderer skips the favicon bubble for these so the icon sits flush
    /// at 36×36 the way Apps + Settings rows do.
    private static let fullBleedAppIconSources: Set<SearchResult.Source> =
        [.settings, .notion, .linear]

    private static let discordBadgeIcon: NSImage =
        RowRendering.appIcon(bundleID: "com.hnc.Discord", fallbackPath: "/Applications/Discord.app")
    private static let messagesBadgeIcon: NSImage =
        RowRendering.appIcon(bundleID: "com.apple.MobileSMS", fallbackPath: "/System/Applications/Messages.app")
    private static let mailBadgeIcon: NSImage =
        RowRendering.appIcon(bundleID: "com.apple.mail", fallbackPath: "/System/Applications/Mail.app")

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
        RowRendering.appIcon(bundleID: "net.whatsapp.WhatsApp", fallbackPath: "/Applications/WhatsApp.app")

    @ViewBuilder
    private var avatarCircle: some View {
        if let data = result.iconData, let img = RowRendering.image(from: data) {
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
        RowRendering.placeholderColor(for: result.displayTitle)
    }

    private func initial(from name: String) -> String {
        RowRendering.initial(from: name)
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
        RowRendering.appIcon(bundleID: "com.spotify.client", fallbackPath: "/Applications/Spotify.app")

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
        RowRendering.relativeString(date)
    }

    private var highlightedSubtitle: AttributedString {
        // Sender prefix (Discord server channels) renders brighter and
        // heavier than the body so the eye lands on it first.
        RowRendering.highlightedSubtitle(
            result.subtitle, sender: result.senderName, query: highlightQuery
        )
    }
}

private struct FileIconView: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        // Read through IconCache so a path that's been drawn before
        // reuses its decoded image instead of decoding again.
        view.image = IconCache.shared.icon(forPath: path)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = IconCache.shared.icon(forPath: path)
    }
}
