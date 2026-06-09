import Foundation

/// Payload for the calendar verb. "set up a 30-min meeting with drishtu
/// tomorrow at 3pm about the address" → EventAction. All fields editable
/// in the compose UI before saving.
struct EventAction: Equatable {
    var title: String
    var startDate: Date
    var durationMinutes: Int
    var attendees: [String]       // names as the user said them
    var location: String          // empty = none
    var notes: String             // pre-populated from source content
}
