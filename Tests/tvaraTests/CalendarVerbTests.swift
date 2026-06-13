import XCTest
@testable import tvara

@MainActor
final class CalendarVerbTests: XCTestCase {

    private let verb = CalendarVerb()

    func testStableId() {
        XCTAssertEqual(verb.id, "calendar")
    }

    func testHandlesCreateEventState() {
        let state = ComposeState(
            sourceSnippet: "",
            stage: .ready,
            kind: .createEvent(EventAction(
                title: "Lunch", startDate: Date(), durationMinutes: 60,
                attendees: [], location: "", notes: ""
            ))
        )
        XCTAssertTrue(verb.handles(state))
    }

    func testRejectsSendMessageState() {
        let state = ComposeState(
            sourceSnippet: "",
            stage: .ready,
            kind: .sendMessage(MessageAction(
                platform: .imessage, recipientName: "X", content: "Y"
            ))
        )
        XCTAssertFalse(verb.handles(state))
    }

    func testRejectsNilKind() {
        let state = ComposeState(sourceSnippet: "", stage: .planning, kind: nil)
        XCTAssertFalse(verb.handles(state))
    }

    // MARK: - EventAction payload sanity

    func testEventActionEquality() {
        let date = Date()
        let a = EventAction(
            title: "Meet", startDate: date, durationMinutes: 30,
            attendees: ["Alice"], location: "HQ", notes: "agenda"
        )
        let b = EventAction(
            title: "Meet", startDate: date, durationMinutes: 30,
            attendees: ["Alice"], location: "HQ", notes: "agenda"
        )
        XCTAssertEqual(a, b)
    }

    func testEventActionMutationChangesEquality() {
        let date = Date()
        var a = EventAction(
            title: "Meet", startDate: date, durationMinutes: 30,
            attendees: [], location: "", notes: ""
        )
        let original = a
        a.title = "Meet — moved"
        XCTAssertNotEqual(a, original)
    }
}
