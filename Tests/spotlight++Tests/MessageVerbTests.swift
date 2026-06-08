import XCTest
@testable import spotlight__

@MainActor
final class MessageVerbTests: XCTestCase {

    private let verb = MessageVerb()

    func testStableId() {
        XCTAssertEqual(verb.id, "message")
    }

    func testHandlesSendMessageState() {
        let state = ComposeState(
            sourceSnippet: "",
            stage: .ready,
            kind: .sendMessage(MessageAction(
                platform: .imessage, recipientName: "Alice", content: "hi"
            ))
        )
        XCTAssertTrue(verb.handles(state))
    }

    func testHandlesAllPlatforms() {
        // The verb is platform-agnostic — every ComposePlatform should be
        // claimed. Per-platform routing happens inside the executor.
        for platform in [ComposePlatform.whatsapp, .imessage, .discord, .mail] {
            let state = ComposeState(
                sourceSnippet: "",
                stage: .ready,
                kind: .sendMessage(MessageAction(
                    platform: platform, recipientName: "X", content: "Y"
                ))
            )
            XCTAssertTrue(verb.handles(state), "should handle \(platform)")
        }
    }

    func testRejectsCreateEventState() {
        let state = ComposeState(
            sourceSnippet: "",
            stage: .ready,
            kind: .createEvent(EventAction(
                title: "T", startDate: Date(), durationMinutes: 30,
                attendees: [], location: "", notes: ""
            ))
        )
        XCTAssertFalse(verb.handles(state))
    }

    func testRejectsNilKind() {
        let state = ComposeState(sourceSnippet: "", stage: .planning, kind: nil)
        XCTAssertFalse(verb.handles(state))
    }

    // MARK: - MessageAction payload sanity

    func testMessageActionEquality() {
        let a = MessageAction(
            platform: .imessage, recipientName: "Alice", content: "hi"
        )
        let b = MessageAction(
            platform: .imessage, recipientName: "Alice", content: "hi"
        )
        XCTAssertEqual(a, b)
    }

    func testDifferentPlatformsAreNotEqual() {
        let a = MessageAction(
            platform: .imessage, recipientName: "Alice", content: "hi"
        )
        let b = MessageAction(
            platform: .whatsapp, recipientName: "Alice", content: "hi"
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Platform metadata

    func testPlatformDisplayNames() {
        XCTAssertEqual(ComposePlatform.whatsapp.displayName, "WhatsApp")
        XCTAssertEqual(ComposePlatform.imessage.displayName, "Messages")
        XCTAssertEqual(ComposePlatform.discord.displayName, "Discord")
        XCTAssertEqual(ComposePlatform.mail.displayName, "Mail")
    }
}
