import Foundation

/// Where the composed message will go. Each platform has its own deep-link
/// scheme (we don't actually send in v1 — the Send button is animation-only
/// except for iMessage, which goes through IMessageSender).
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

/// One per verb. Today: sendMessage and createEvent. Adding a new verb
/// means appending a case here AND adding a verb to ComposeVerbRegistry.
/// The two-step coupling is intentional — the enum is the planner's
/// output type, which has to enumerate what it can produce.
enum ComposeKind: Equatable {
    case sendMessage(MessageAction)
    case createEvent(EventAction)
}

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
