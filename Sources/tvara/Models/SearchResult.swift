import Foundation
import SwiftUI

struct SearchResult: Identifiable, Hashable {
    let id: UUID
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
    /// HTTPS URL of cover art for sources like Spotify where we have the
    /// CDN URL but no local image bytes. Row view does an async download.
    let remoteArtURL: String?
    /// True when this row was produced via Levenshtein fuzzy fallback
    /// (typo-tolerant match) rather than a literal prefix / exact /
    /// contains match. Used by the ViewModel to suppress fuzzy guesses
    /// when any "proper" match exists anywhere in the merged set —
    /// avoids `shirim` showing Siri alongside the real shirim folder.
    let isFuzzyMatch: Bool

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        source: Source,
        date: Date?,
        badge: String?,
        openTarget: OpenTarget,
        rank: Int,
        iconData: Data? = nil,
        senderName: String? = nil,
        remoteArtURL: String? = nil,
        isFuzzyMatch: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.date = date
        self.badge = badge
        self.openTarget = openTarget
        self.rank = rank
        self.iconData = iconData
        self.senderName = senderName
        self.remoteArtURL = remoteArtURL
        self.isFuzzyMatch = isFuzzyMatch
    }

    /// Sentinel id for the synthetic "photo collection" row that the
    /// blended view substitutes in place of N individual photo rows.
    /// Stable across renders so SwiftUI keeps the same view identity even
    /// as the underlying photo set updates.
    static let photoCollectionRowId = UUID(uuidString: "00000000-0000-0000-0000-000000000B01")!

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? subtitle : trimmed
    }

    /// Return a copy with a different rank. Used by the semantic reranker
    /// to encode its ordering into the `rank` field so downstream merge
    /// sorts in the ViewModel preserve it (they sort by rank, not by the
    /// array position the reranker produces).
    func withRank(_ newRank: Int) -> SearchResult {
        SearchResult(
            id: id,
            title: title, subtitle: subtitle, source: source, date: date,
            badge: badge, openTarget: openTarget, rank: newRank,
            iconData: iconData, senderName: senderName,
            remoteArtURL: remoteArtURL, isFuzzyMatch: isFuzzyMatch
        )
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
        /// Just copy a string to the system clipboard. Used for terminal
        /// commands and prior clipboard entries.
        case copyToClipboard(String)
        /// Open Apple Notes.app and copy the note title to the clipboard so
        /// the user can ⌘F + ⌘V to find it. Apple doesn't expose a stable
        /// per-note deep link from outside the app.
        case notesNote(title: String)
        /// Drive Spotify.app via AppleScript: set shuffle on, then play the
        /// given URI (typically `spotify:playlist:...`).
        case spotifyPlay(uri: String, shuffle: Bool)
        /// Snap/move/resize the previously-frontmost app's focused window via
        /// the macOS Accessibility API. Target PID is captured by
        /// SearchWindowController before the panel steals focus.
        case windowAction(WindowAction)
        /// System-level action — sleep / shut down / restart / lock screen /
        /// log out. Executed via NSAppleScript off the main thread.
        case systemAction(SystemAction)
        /// Synthetic "many photos matched" row used in the blended view.
        /// Enter on the row zooms into the images category; left/right
        /// scrubs across the inline thumb strip and Enter on a focused
        /// thumb opens that specific photo. Payload is the photo results
        /// the row stands in for (preserves their individual openTargets).
        case imagesCollection(photos: [SearchResult])
        /// Synthetic footer row appended to a capped blended section
        /// (one of the per-platform messaging sections currently).
        /// Enter toggles the section's expanded state in the view
        /// model so the rest of the items render inline. `kindRawValue`
        /// is `BlendedSection.Kind.rawValue` — stringly typed so this
        /// model file doesn't depend on the ViewModel.
        case expandSection(kindRawValue: String, hiddenCount: Int)
    }

    enum Source: String, CaseIterable {
        case chrome    = "Chrome"
        case arc       = "Arc"
        case brave     = "Brave"
        case edge      = "Edge"
        case file      = "File"
        case folder    = "Folder"
        case app       = "App"
        case whatsapp  = "WhatsApp"
        case discord   = "Discord"
        case imessage  = "Messages"
        case mail      = "Mail"
        case terminal  = "Terminal"
        case clipboard = "Clipboard"
        case notes     = "Notes"
        case notion    = "Notion"
        case linear    = "Linear"
        case spotify   = "Spotify"
        case images    = "Images"
        case window    = "Window"
        case settings  = "Settings"
        case systemAction = "System"

        var icon: String {
            switch self {
            case .chrome:    return "globe"
            case .arc:       return "circle.hexagongrid.fill"
            case .brave:     return "shield.lefthalf.filled"
            case .edge:      return "globe.asia.australia.fill"
            case .file:      return "doc.fill"
            case .folder:    return "folder.fill"
            case .app:       return "app.fill"
            case .whatsapp:  return "message.fill"
            case .discord:   return "bubble.left.and.bubble.right.fill"
            case .imessage:  return "bubble.left.fill"
            case .mail:      return "envelope.fill"
            case .terminal:  return "terminal.fill"
            case .clipboard: return "doc.on.clipboard.fill"
            case .notes:     return "note.text"
            case .notion:    return "doc.richtext"
            case .linear:    return "checklist"
            case .spotify:   return "music.note"
            case .images:    return "photo.fill"
            case .window:    return "macwindow"
            case .settings:  return "gearshape.fill"
            case .systemAction: return "power"
            }
        }

        var tint: Color {
            switch self {
            case .chrome:    return Color(red: 0.26, green: 0.52, blue: 0.96)
            case .arc:       return Color(red: 0.95, green: 0.46, blue: 0.78)
            case .brave:     return Color(red: 1.00, green: 0.32, blue: 0.13)
            case .edge:      return Color(red: 0.00, green: 0.55, blue: 0.82)
            case .file:      return Color(red: 0.45, green: 0.50, blue: 0.60)
            case .folder:    return Color(red: 0.30, green: 0.62, blue: 0.95)
            case .app:       return Color(red: 0.55, green: 0.40, blue: 0.95)
            case .whatsapp:  return Color(red: 0.15, green: 0.78, blue: 0.42)
            case .discord:   return Color(red: 0.35, green: 0.40, blue: 0.95)
            case .imessage:  return Color(red: 0.16, green: 0.72, blue: 0.35)
            case .mail:      return Color(red: 0.16, green: 0.45, blue: 0.95)
            case .terminal:  return Color(red: 0.20, green: 0.20, blue: 0.22)
            case .clipboard: return Color(red: 0.55, green: 0.55, blue: 0.60)
            case .notes:     return Color(red: 0.98, green: 0.78, blue: 0.27)   // Notes yellow
            case .notion:    return Color(red: 0.18, green: 0.18, blue: 0.20)   // Notion dark
            case .linear:    return Color(red: 0.36, green: 0.42, blue: 0.97)   // Linear indigo
            case .spotify:   return Color(red: 0.12, green: 0.84, blue: 0.38)   // Spotify green
            case .images:    return Color(red: 0.93, green: 0.55, blue: 0.20)   // warm orange (photo)
            case .window:    return Color(red: 0.35, green: 0.55, blue: 0.75)   // calm steel-blue
            case .settings:  return Color(red: 0.55, green: 0.58, blue: 0.62)   // gunmetal gray
            case .systemAction: return Color(red: 0.85, green: 0.32, blue: 0.30) // power-button red
            }
        }
    }
}
