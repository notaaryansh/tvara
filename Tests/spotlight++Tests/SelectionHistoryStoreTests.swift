import XCTest
@testable import spotlight__

final class SelectionHistoryStoreTests: XCTestCase {

    private var tempDB: String!

    override func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory()
        tempDB = dir + "selhist_\(UUID().uuidString).db"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDB)
        super.tearDown()
    }

    // MARK: - Recording basics

    func testFirstSelectionCreatesRowAtCountOne() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        await store.recordSelection(chosenId: "url:a.com", visibleIds: [])
        let got = await store.lookup(["url:a.com"])
        XCTAssertEqual(got["url:a.com"]?.count, 1)
    }

    func testCountCapsAtThree() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        for _ in 0..<10 {
            await store.recordSelection(chosenId: "app:chrome", visibleIds: [])
        }
        let got = await store.lookup(["app:chrome"])
        XCTAssertEqual(got["app:chrome"]?.count, 3, "should cap at 3 regardless of how many selections")
    }

    func testLastSelectedAtUpdatesOnEverySelection() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        await store.recordSelection(chosenId: "app:x", visibleIds: [])
        let first = await store.lookup(["app:x"])["app:x"]?.lastSelectedAt ?? 0

        // Sleep just enough for unix-second resolution to move.
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        await store.recordSelection(chosenId: "app:x", visibleIds: [])
        let second = await store.lookup(["app:x"])["app:x"]?.lastSelectedAt ?? 0

        XCTAssertGreaterThan(second, first)
    }

    // MARK: - Penalty mechanism

    func testVisibleCompetitorsGetDecremented() async {
        let store = SelectionHistoryStore(dbPath: tempDB)

        // Pre-seed: spotify and spotlight both at 2.
        for _ in 0..<2 {
            await store.recordSelection(chosenId: "app:spotify", visibleIds: [])
        }
        for _ in 0..<2 {
            await store.recordSelection(chosenId: "app:spotlight", visibleIds: [])
        }

        // Now select spotify with spotlight in the visible set.
        await store.recordSelection(
            chosenId: "app:spotify",
            visibleIds: ["app:spotify", "app:spotlight"]
        )

        let got = await store.lookup(["app:spotify", "app:spotlight"])
        // spotify capped at 3 (was 2, +1 = 3); spotlight loses 1 (was 2 → 1).
        XCTAssertEqual(got["app:spotify"]?.count, 3)
        XCTAssertEqual(got["app:spotlight"]?.count, 1)
    }

    func testCountFloorsAtZero() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        // Seed both at 1.
        await store.recordSelection(chosenId: "a", visibleIds: [])
        await store.recordSelection(chosenId: "b", visibleIds: [])

        // Now penalise b twice via a wins.
        await store.recordSelection(chosenId: "a", visibleIds: ["a", "b"])
        await store.recordSelection(chosenId: "a", visibleIds: ["a", "b"])
        await store.recordSelection(chosenId: "a", visibleIds: ["a", "b"])

        let got = await store.lookup(["a", "b"])
        XCTAssertEqual(got["a"]?.count, 3, "a capped at 3")
        XCTAssertEqual(got["b"]?.count, 0, "b floored at 0, never negative")
    }

    func testChosenIdNotPenalisedEvenWhenInVisibleIds() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        await store.recordSelection(chosenId: "a", visibleIds: [])  // a → 1
        await store.recordSelection(
            chosenId: "a",
            visibleIds: ["a", "b", "c"]   // a is both chosen and "visible"
        )
        let got = await store.lookup(["a"])
        XCTAssertEqual(got["a"]?.count, 2, "chosen should be +1, not +1 then -1 to itself")
    }

    func testUnknownVisibleIdsDoNotCreateRows() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        await store.recordSelection(
            chosenId: "winner",
            visibleIds: ["winner", "neverbefore-1", "neverbefore-2"]
        )
        let got = await store.lookup(["neverbefore-1", "neverbefore-2"])
        XCTAssertTrue(got.isEmpty, "penalising never-seen ids must not create rows at 0")
    }

    // MARK: - Recovery trace from the design doc

    func testTwoRoundLeadershipFlip() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        // Round 1: pick Spotify out of [Spotify, Spotlight].
        await store.recordSelection(chosenId: "spotify",
                                    visibleIds: ["spotify", "spotlight"])
        var got = await store.lookup(["spotify", "spotlight"])
        XCTAssertEqual(got["spotify"]?.count, 1)
        XCTAssertNil(got["spotlight"])

        // Round 2: correct to Spotlight.
        await store.recordSelection(chosenId: "spotlight",
                                    visibleIds: ["spotify", "spotlight"])
        got = await store.lookup(["spotify", "spotlight"])
        XCTAssertEqual(got["spotify"]?.count, 0)
        XCTAssertEqual(got["spotlight"]?.count, 1)
    }

    // MARK: - Lookup edge cases

    func testLookupEmptyInputReturnsEmpty() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        let got = await store.lookup([])
        XCTAssertTrue(got.isEmpty)
    }

    func testLookupForUnknownIdsReturnsEmpty() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        let got = await store.lookup(["ghost-1", "ghost-2"])
        XCTAssertTrue(got.isEmpty)
    }

    // MARK: - Clear

    func testClearEmptiesEverything() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        await store.recordSelection(chosenId: "a", visibleIds: [])
        await store.recordSelection(chosenId: "b", visibleIds: [])
        await store.clear()
        let got = await store.lookup(["a", "b"])
        XCTAssertTrue(got.isEmpty)
    }

    // MARK: - Persistence across instances

    func testHistorySurvivesReopen() async {
        let store1 = SelectionHistoryStore(dbPath: tempDB)
        await store1.recordSelection(chosenId: "persisted", visibleIds: [])

        let store2 = SelectionHistoryStore(dbPath: tempDB)
        let got = await store2.lookup(["persisted"])
        XCTAssertEqual(got["persisted"]?.count, 1)
    }

    // MARK: - Empty / pathological inputs

    func testEmptyChosenIdIsNoOp() async {
        let store = SelectionHistoryStore(dbPath: tempDB)
        await store.recordSelection(chosenId: "", visibleIds: ["a", "b"])
        let got = await store.lookup(["", "a", "b"])
        XCTAssertTrue(got.isEmpty)
    }
}
