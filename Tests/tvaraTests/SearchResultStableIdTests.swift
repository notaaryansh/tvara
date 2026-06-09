import XCTest
@testable import spotlight__

final class SearchResultStableIdTests: XCTestCase {

    // MARK: - per openTarget case (non-blacklisted sources)

    func testUrlOpenTarget() {
        let r = make(source: .chrome, openTarget: .url("https://example.com"))
        XCTAssertEqual(r.stableId, "url:https://example.com")
    }

    func testFileOpenTarget() {
        let r = make(source: .file, openTarget: .file("/Users/me/notes.md"))
        XCTAssertEqual(r.stableId, "file:/Users/me/notes.md")
    }

    func testWhatsappChatOpenTarget() {
        let r = make(source: .whatsapp,
                     openTarget: .whatsappChat(jid: "12345@s.whatsapp.net", messageText: ""))
        XCTAssertEqual(r.stableId, "whatsapp:12345@s.whatsapp.net")
    }

    func testImessageChatOpenTarget() {
        let r = make(source: .imessage,
                     openTarget: .imessageChat(handle: "+15551234567", messageText: ""))
        XCTAssertEqual(r.stableId, "imessage:+15551234567")
    }

    func testClipboardOpenTarget() {
        let r = make(source: .clipboard, openTarget: .copyToClipboard("hello world"))
        XCTAssertEqual(r.stableId, "clip:hello world")
    }

    func testNotesOpenTarget() {
        let r = make(source: .notes, openTarget: .notesNote(title: "Project ideas"))
        XCTAssertEqual(r.stableId, "notes:Project ideas")
    }

    func testSpotifyOpenTarget() {
        let r = make(source: .spotify,
                     openTarget: .spotifyPlay(uri: "spotify:playlist:abc", shuffle: false))
        XCTAssertEqual(r.stableId, "spotify:spotify:playlist:abc")
    }

    // MARK: - blacklisted sources return nil

    func testSystemActionSourceReturnsNil() {
        let r = make(source: .systemAction, openTarget: .systemAction(.sleep))
        XCTAssertNil(r.stableId)
    }

    func testWindowSourceReturnsNil() {
        let r = make(source: .window, openTarget: .windowAction(.leftHalf))
        XCTAssertNil(r.stableId)
    }

    func testImagesSourceReturnsNil() {
        // Images use .file openTarget but the source is blacklisted.
        let r = make(source: .images, openTarget: .file("/path/to/image.jpg"))
        XCTAssertNil(r.stableId)
    }

    // MARK: - openTarget-level blacklist (defence in depth)

    func testWindowActionOpenTargetWithNonWindowSourceStillReturnsNil() {
        // Defensive: even if some bug constructs a result with .windowAction
        // payload but a non-window source, we shouldn't track it.
        let r = make(source: .app, openTarget: .windowAction(.maximize))
        XCTAssertNil(r.stableId)
    }

    func testSystemActionOpenTargetWithNonSystemSourceStillReturnsNil() {
        let r = make(source: .app, openTarget: .systemAction(.lockScreen))
        XCTAssertNil(r.stableId)
    }

    // MARK: - same conceptual result → same id

    func testSameUrlAcrossRebuildsHasSameId() {
        let r1 = make(source: .chrome, openTarget: .url("https://x.com"), rank: 100)
        let r2 = make(source: .chrome, openTarget: .url("https://x.com"), rank: 200)
        XCTAssertEqual(r1.stableId, r2.stableId)
    }

    func testDifferentUrlsHaveDifferentIds() {
        let r1 = make(source: .chrome, openTarget: .url("https://a.com"))
        let r2 = make(source: .chrome, openTarget: .url("https://b.com"))
        XCTAssertNotEqual(r1.stableId, r2.stableId)
    }

    // MARK: - helper

    private func make(source: SearchResult.Source,
                      openTarget: SearchResult.OpenTarget,
                      rank: Int = 0) -> SearchResult {
        SearchResult(
            title: "T", subtitle: "S", source: source,
            date: nil, badge: nil, openTarget: openTarget, rank: rank
        )
    }
}
