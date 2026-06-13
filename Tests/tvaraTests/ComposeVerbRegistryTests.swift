import XCTest
@testable import tvara

@MainActor
final class ComposeVerbRegistryTests: XCTestCase {

    func testRegistryIsNotEmpty() {
        XCTAssertFalse(ComposeVerbRegistry.all.isEmpty)
    }

    func testCalendarVerbRegistered() {
        XCTAssertNotNil(ComposeVerbRegistry.verb(withId: "calendar"))
    }

    func testMessageVerbRegistered() {
        XCTAssertNotNil(ComposeVerbRegistry.verb(withId: "message"))
    }

    func testUnknownIdReturnsNil() {
        XCTAssertNil(ComposeVerbRegistry.verb(withId: "definitely-not-a-verb"))
    }

    func testVerbIdsAreUnique() {
        let ids = ComposeVerbRegistry.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate verb ids in registry: \(ids)")
    }

    // MARK: - State routing

    func testCalendarStateRoutesToCalendarVerb() {
        let state = ComposeState(
            sourceSnippet: "",
            stage: .ready,
            kind: .createEvent(EventAction(
                title: "Test", startDate: Date(), durationMinutes: 30,
                attendees: [], location: "", notes: ""
            ))
        )
        XCTAssertEqual(ComposeVerbRegistry.verb(for: state)?.id, "calendar")
    }

    func testMessageStateRoutesToMessageVerb() {
        let state = ComposeState(
            sourceSnippet: "",
            stage: .ready,
            kind: .sendMessage(MessageAction(
                platform: .imessage, recipientName: "Test", content: "Hi"
            ))
        )
        XCTAssertEqual(ComposeVerbRegistry.verb(for: state)?.id, "message")
    }

    func testNilKindRoutesToNoVerb() {
        let state = ComposeState(sourceSnippet: "", stage: .planning, kind: nil)
        XCTAssertNil(ComposeVerbRegistry.verb(for: state))
    }
}
