import Foundation
import SwiftUI

struct SearchResult: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let source: Source
    let date: Date?
    let badge: String?
    let openTarget: OpenTarget
    let rank: Int
    let iconData: Data?
    /// For messages where the sender is distinct from the conversation
    /// partner (e.g. Discord server channels), this is the display name
    /// of the person who actually authored the message.
    let senderName: String?

    init(
        title: String,
        subtitle: String,
        source: Source,
        date: Date?,
        badge: String?,
        openTarget: OpenTarget,
        rank: Int,
        iconData: Data? = nil,
        senderName: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.date = date
        self.badge = badge
        self.openTarget = openTarget
        self.rank = rank
        self.iconData = iconData
        self.senderName = senderName
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? subtitle : trimmed
    }

    // Hash/equality intentionally exclude iconData — favicons are large and
    // would dominate the hash; identity comes from id alone anyway.
    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    enum OpenTarget: Hashable {
        case url(String)
        case file(String)
        /// Open a WhatsApp chat (individual via deep link, group falls back to
        /// the app), copying the message text to the clipboard so the user
        /// can ⌘F + ⌘V inside WhatsApp to find it.
        case whatsappChat(jid: String, messageText: String)
        /// Open an Apple Messages chat with the given handle (phone/email),
        /// copying the message text to the clipboard so ⌘F + ⌘V inside
        /// Messages finds the specific bubble. Apple doesn't expose a
        /// per-message URL.
        case imessageChat(handle: String, messageText: String)
    }

    enum Source: String, CaseIterable {
        case chrome   = "Chrome"
        case arc      = "Arc"
        case brave    = "Brave"
        case edge     = "Edge"
        case file     = "File"
        case folder   = "Folder"
        case app      = "App"
        case whatsapp = "WhatsApp"
        case discord  = "Discord"
        case imessage = "Messages"
        case mail     = "Mail"

        var icon: String {
            switch self {
            case .chrome:   return "globe"
            case .arc:      return "circle.hexagongrid.fill"
            case .brave:    return "shield.lefthalf.filled"
            case .edge:     return "globe.asia.australia.fill"
            case .file:     return "doc.fill"
            case .folder:   return "folder.fill"
            case .app:      return "app.fill"
            case .whatsapp: return "message.fill"
            case .discord:  return "bubble.left.and.bubble.right.fill"
            case .imessage: return "bubble.left.fill"
            case .mail:     return "envelope.fill"
            }
        }

        var tint: Color {
            switch self {
            case .chrome:   return Color(red: 0.26, green: 0.52, blue: 0.96)
            case .arc:      return Color(red: 0.95, green: 0.46, blue: 0.78)
            case .brave:    return Color(red: 1.00, green: 0.32, blue: 0.13)
            case .edge:     return Color(red: 0.00, green: 0.55, blue: 0.82)
            case .file:     return Color(red: 0.45, green: 0.50, blue: 0.60)
            case .folder:   return Color(red: 0.30, green: 0.62, blue: 0.95)
            case .app:      return Color(red: 0.55, green: 0.40, blue: 0.95)
            case .whatsapp: return Color(red: 0.15, green: 0.78, blue: 0.42)
            case .discord:  return Color(red: 0.35, green: 0.40, blue: 0.95)
            case .imessage: return Color(red: 0.16, green: 0.72, blue: 0.35)
            case .mail:     return Color(red: 0.16, green: 0.45, blue: 0.95)
            }
        }
    }
}
