import EventKit
import Foundation

/// Save an EventAction into the user's default calendar via EventKit.
/// First call triggers the Calendar TCC prompt; subsequent calls reuse
/// the granted access. EventKit doesn't currently support adding
/// attendees from third-party apps (Apple gates that to Calendar.app
/// itself) — we capture attendees in the event notes so the user can
/// invite them manually from Calendar.app afterwards.
enum CalendarEventSaver {
    enum SaveError: Error, CustomStringConvertible {
        case accessDenied
        case noDefaultCalendar
        case underlying(Error)

        var description: String {
            switch self {
            case .accessDenied:        return "Calendar access denied"
            case .noDefaultCalendar:   return "No default calendar configured"
            case .underlying(let e):   return "Calendar error: \(e.localizedDescription)"
            }
        }
    }

    /// Pre-prompt for Calendar access at app launch so the TCC dialog
    /// fires alongside the other permission prompts, not when the user
    /// first clicks Create Event.
    static func warmAccess() async {
        let store = EKEventStore()
        _ = await withCheckedContinuation { cont in
            store.requestFullAccessToEvents { granted, _ in
                cont.resume(returning: granted)
            }
        }
    }

    static func save(_ action: EventAction) async throws {
        let store = EKEventStore()
        try await requestAccess(store: store)

        guard let cal = store.defaultCalendarForNewEvents else {
            throw SaveError.noDefaultCalendar
        }

        let event = EKEvent(eventStore: store)
        event.calendar = cal
        event.title = action.title
        event.startDate = action.startDate
        event.endDate = action.startDate.addingTimeInterval(
            TimeInterval(action.durationMinutes * 60)
        )
        if !action.location.isEmpty {
            event.location = action.location
        }

        // Compose the notes body: planner-provided notes, then an
        // "Attendees" line so the user knows who to invite when they
        // open the event in Calendar.app.
        var bodyLines: [String] = []
        if !action.notes.isEmpty {
            bodyLines.append(action.notes)
        }
        if !action.attendees.isEmpty {
            bodyLines.append("")
            bodyLines.append("Attendees: " + action.attendees.joined(separator: ", "))
        }
        event.notes = bodyLines.joined(separator: "\n")

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw SaveError.underlying(error)
        }
    }

    private static func requestAccess(store: EKEventStore) async throws {
        // macOS 14+: requestFullAccessToEvents. Older fallback omitted —
        // tvara targets macOS 14 minimum (per Info.plist).
        let granted: Bool = await withCheckedContinuation { cont in
            store.requestFullAccessToEvents { granted, _ in
                cont.resume(returning: granted)
            }
        }
        if !granted { throw SaveError.accessDenied }
    }
}
