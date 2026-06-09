import Foundation

/// Payload for the message verb. "send drishtu a message on whatsapp about
/// this" → MessageAction.
struct MessageAction: Equatable {
    let platform: ComposePlatform
    let recipientName: String     // contact's name as the user said it
    var content: String           // editable message body; pre-populated
    var contactAvatar: Data?      // resolved later from the matching service
}
