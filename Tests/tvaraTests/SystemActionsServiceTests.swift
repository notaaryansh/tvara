import XCTest
@testable import tvara

/// Pins the SystemActionsService alias-matching behaviour. We do NOT test
/// execute() here — that fires NSAppleScript against System Events and would
/// actually sleep the test machine.
final class SystemActionsServiceTests: XCTestCase {

    private var service: SystemActionsService!

    override func setUp() {
        super.setUp()
        service = SystemActionsService()
    }

    // MARK: - Minimum query length (anti-foot-gun)

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(service.match(query: "").isEmpty)
    }

    func testOneCharQueryReturnsNothing() {
        XCTAssertTrue(service.match(query: "s").isEmpty)
    }

    func testTwoCharQueryReturnsNothing() {
        XCTAssertTrue(service.match(query: "sl").isEmpty)
    }

    func testThreeCharQueryReturnsHits() {
        let hits = service.match(query: "sle")
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.title, "Sleep")
    }

    // MARK: - Prefix matching for each action

    func testSleepAlias() {
        let hits = service.match(query: "slee")
        XCTAssertEqual(hits.first?.title, "Sleep")
    }

    func testShutdownAlias() {
        let hits = service.match(query: "shut")
        XCTAssertEqual(hits.first?.title, "Shut Down")
    }

    func testRestartAlias() {
        let hits = service.match(query: "rest")
        XCTAssertEqual(hits.first?.title, "Restart")
    }

    func testRebootAliasMapsToRestart() {
        let hits = service.match(query: "reboot")
        XCTAssertEqual(hits.first?.title, "Restart")
    }

    func testLockAlias() {
        let hits = service.match(query: "lock")
        XCTAssertEqual(hits.first?.title, "Lock Screen")
    }

    func testLogoutAlias() {
        let hits = service.match(query: "logo")
        XCTAssertEqual(hits.first?.title, "Log Out")
    }

    // MARK: - No fuzzy fallback (deliberate — destructive actions)

    func testTypoDoesNotSurfaceDestructiveAction() {
        // "shtu" is one transposition from "shut" — must NOT route to Shut Down.
        let hits = service.match(query: "shtu")
        XCTAssertTrue(hits.isEmpty)
    }

    func testGarbageQueryReturnsNothing() {
        let hits = service.match(query: "xyzabc")
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - Deduplication across aliases

    func testMultipleAliasesForSameActionDeduplicate() {
        // "lo" wouldn't pass min length, "log" matches both "log out" and "logout"
        // and "lock"; same canonical actions should appear once each.
        let hits = service.match(query: "log")
        let titles = hits.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "duplicate canonical titles in: \(titles)")
    }

    // MARK: - Result wiring

    func testHitsCarrySystemActionOpenTarget() {
        let hits = service.match(query: "sleep")
        guard let first = hits.first else { return XCTFail("no hits") }
        if case .systemAction(let action) = first.openTarget {
            XCTAssertEqual(action, .sleep)
        } else {
            XCTFail("expected systemAction openTarget, got \(first.openTarget)")
        }
    }

    func testHitsUseSystemActionSource() {
        let hits = service.match(query: "sleep")
        XCTAssertEqual(hits.first?.source, .systemAction)
    }
}
