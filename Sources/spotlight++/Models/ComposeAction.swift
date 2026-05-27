import Foundation

/// Where the composed message will go. Each platform has its own deep-link
/// scheme (we don't actually send in v1 — the Send button is animation-only).
enum ComposePlatform: String, Equatable, Decodable {
    case whatsapp
    case imessage
    case discord
    case mail

    var displayName: String {
        switch self {
        case .whatsapp: return "WhatsApp"
        case .imessage: return "Messages"
        case .discord:  return "Discord"
        case .mail:     return "Mail"
        }
    }

    /// SF Symbol shown as a badge on the contact card.
    var badgeIcon: String {
        switch self {
        case .whatsapp: return "message.fill"
        case .imessage: return "bubble.left.fill"
        case .discord:  return "bubble.left.and.bubble.right.fill"
        case .mail:     return "envelope.fill"
        }
    }
}

/// Two flavours of compose action the planner can return.
enum ComposeKind: Equatable {
    case sendMessage(MessageAction)
    case createEvent(EventAction)
}

/// "send drishtu a message on whatsapp about this" → MessageAction.
struct MessageAction: Equatable {
    let platform: ComposePlatform
    let recipientName: String     // contact's name as the user said it
    var content: String           // editable message body; pre-populated
    var contactAvatar: Data?      // resolved later from the matching service
}

/// "set up a 30-min meeting with drishtu tomorrow at 3pm about the address"
/// → EventAction. All fields editable in the compose UI before saving.
struct EventAction: Equatable {
    var title: String
    var startDate: Date
    var durationMinutes: Int
    var attendees: [String]       // names as the user said them
    var location: String          // empty = none
    var notes: String             // pre-populated from source content
}

/// Back-compat alias so any leftover ComposeAction references compile
/// while the refactor is in flight. Remove once everything is migrated.
typealias ComposeAction = MessageAction

/// Tracks the lifecycle of an in-progress compose. UI flips through these.
enum ComposeStage: Equatable {
    case planning   // waiting for OpenAI to return the structured action
    case ready      // panel visible, user editing
    case sending    // Send tapped — paper-plane animation in flight
    case sent       // checkmark, brief pause before reset to nil
}

struct ComposeState: Equatable {
    /// Snippet from the result the user was acting on. Shown as small
    /// "based on..." context above the editable content.
    var sourceSnippet: String
    var stage: ComposeStage
    var kind: ComposeKind?       // populated when stage >= .ready
}
