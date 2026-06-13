import XCTest
@testable import tvara

final class FrequencyRerankerTests: XCTestCase {

    // MARK: - No-op cases

    func testEmptyResultsReturnsEmpty() {
        let out = FrequencyReranker.apply(to: [], history: [:])
        XCTAssertTrue(out.isEmpty)
    }

    func testEmptyHistoryReturnsUnchanged() {
        let results = [
            makeUrl("a.com", rank: 100),
            makeUrl("b.com", rank: 90),
            makeUrl("c.com", rank: 80),
        ]
        let out = FrequencyReranker.apply(to: results, history: [:])
        XCTAssertEqual(out.map(\.title), results.map(\.title))
        XCTAssertEqual(out.map(\.rank), [100, 90, 80])
    }

    // MARK: - Frequency reorders within a source band

    func testHigherCountWinsWithinBand() {
        let results = [
            makeUrl("a.com", rank: 100),  // history: 0
            makeUrl("b.com", rank: 90),   // history: 3
            makeUrl("c.com", rank: 80),   // history: 1
        ]
        let history: [String: SelectionHistoryEntry] = [
            "url:b.com": .init(count: 3, lastSelectedAt: 1000),
            "url:c.com": .init(count: 1, lastSelectedAt: 1000),
        ]
        let out = FrequencyReranker.apply(to: results, history: history)
        // Sorted by rank desc after rewrite: b (100), c (90), a (80).
        let byRank = out.sorted { $0.rank > $1.rank }
        XCTAssertEqual(byRank.map(\.title), ["url:b.com", "url:c.com", "url:a.com"])
        XCTAssertEqual(byRank.map(\.rank), [100, 90, 80])
    }

    func testRecencyTiebreaksEqualCounts() {
        let results = [
            makeUrl("a.com", rank: 100),
            makeUrl("b.com", rank: 90),
        ]
        let history: [String: SelectionHistoryEntry] = [
            "url:a.com": .init(count: 2, lastSelectedAt: 100),   // older
            "url:b.com": .init(count: 2, lastSelectedAt: 200),   // more recent
        ]
        let out = FrequencyReranker.apply(to: results, history: history)
        // Equal counts; b is more recent so b wins.
        let byRank = out.sorted { $0.rank > $1.rank }
        XCTAssertEqual(byRank.first?.title, "url:b.com")
    }

    func testBaseRankTiebreaksEqualCountAndRecency() {
        let results = [
            makeUrl("a.com", rank: 100),   // higher base rank
            makeUrl("b.com", rank: 90),
        ]
        let history: [String: SelectionHistoryEntry] = [
            "url:a.com": .init(count: 2, lastSelectedAt: 100),
            "url:b.com": .init(count: 2, lastSelectedAt: 100),
        ]
        let out = FrequencyReranker.apply(to: results, history: history)
        // All tied; higher base rank wins → a stays on top.
        let byRank = out.sorted { $0.rank > $1.rank }
        XCTAssertEqual(byRank.first?.title, "url:a.com")
    }

    // MARK: - Band preservation

    func testNeverCrossesBandBoundaries() {
        // Two bands: window actions (rank 800-810) and apps (rank 100-110).
        // Even a heavily-clicked app should not leapfrog any window action.
        let results = [
            makeWindow(.leftHalf, rank: 810),
            makeWindow(.rightHalf, rank: 805),
            makeApp("AppA", rank: 110),  // heavy history
            makeApp("AppB", rank: 105),
        ]
        let history: [String: SelectionHistoryEntry] = [
            "url:AppA": .init(count: 3, lastSelectedAt: 999),  // shouldn't matter — stableId is different
            "file:AppA": .init(count: 3, lastSelectedAt: 999),
            "url:AppB": .init(count: 0, lastSelectedAt: 0),
        ]
        let out = FrequencyReranker.apply(to: results, history: history)
        let byRank = out.sorted { $0.rank > $1.rank }
        // Window actions (band 800+) must still be top two.
        XCTAssertEqual(byRank[0].source, .window)
        XCTAssertEqual(byRank[1].source, .window)
        // Apps come after, regardless of history.
        XCTAssertEqual(byRank[2].source, .app)
        XCTAssertEqual(byRank[3].source, .app)
    }

    // MARK: - Blacklisted sources skipped

    func testWindowSourceUnchangedByHistory() {
        // Window results have nil stableId — group is skipped entirely.
        let results = [
            makeWindow(.leftHalf, rank: 800),
            makeWindow(.rightHalf, rank: 790),
        ]
        // History map has bogus entries pretending these are tracked.
        // They should have no effect.
        let history: [String: SelectionHistoryEntry] = [:]
        let out = FrequencyReranker.apply(to: results, history: history)
        XCTAssertEqual(out.map(\.rank), [800, 790])
    }

    func testSystemActionSourceUnchangedByHistory() {
        let results = [
            makeSystemAction(.sleep, rank: 920),
            makeSystemAction(.shutDown, rank: 919),
        ]
        let out = FrequencyReranker.apply(to: results, history: [:])
        XCTAssertEqual(out.map(\.rank), [920, 919])
    }

    func testImagesSourceUnchangedByHistory() {
        let results = [
            makeImage("/photos/a.jpg", rank: 500),
            makeImage("/photos/b.jpg", rank: 490),
        ]
        // Even with bogus history entries, images are skipped.
        let history: [String: SelectionHistoryEntry] = [:]
        let out = FrequencyReranker.apply(to: results, history: history)
        XCTAssertEqual(out.map(\.rank), [500, 490])
    }

    // MARK: - Multi-source: each band reordered independently

    func testTwoSourcesEachReorderedWithinTheirBand() {
        // Apps band: 110, 100; URLs band: 50, 40.
        // History: AppB and url:b.com get a boost in their respective bands.
        let results = [
            makeApp("AppA", rank: 110),
            makeApp("AppB", rank: 100),
            makeUrl("a.com", rank: 50),
            makeUrl("b.com", rank: 40),
        ]
        let history: [String: SelectionHistoryEntry] = [
            "url:AppB": .init(count: 2, lastSelectedAt: 100),  // file: prefix actually, since app uses .file openTarget
            "file:AppB": .init(count: 2, lastSelectedAt: 100),
            "url:b.com": .init(count: 2, lastSelectedAt: 100),
        ]
        let out = FrequencyReranker.apply(to: results, history: history)
        let byRank = out.sorted { $0.rank > $1.rank }
        // Apps band: AppB now top (rank 110), AppA (100).
        XCTAssertEqual(byRank[0].title, "file:AppB")
        XCTAssertEqual(byRank[0].rank, 110)
        XCTAssertEqual(byRank[1].title, "file:AppA")
        XCTAssertEqual(byRank[1].rank, 100)
        // URLs band: b now top (rank 50), a (40).
        XCTAssertEqual(byRank[2].title, "url:b.com")
        XCTAssertEqual(byRank[2].rank, 50)
        XCTAssertEqual(byRank[3].title, "url:a.com")
        XCTAssertEqual(byRank[3].rank, 40)
    }

    // MARK: - helpers

    private func makeUrl(_ host: String, rank: Int) -> SearchResult {
        SearchResult(
            title: "url:\(host)", subtitle: "", source: .chrome,
            date: nil, badge: nil,
            openTarget: .url(host), rank: rank
        )
    }

    private func makeApp(_ name: String, rank: Int) -> SearchResult {
        SearchResult(
            title: "file:\(name)", subtitle: "", source: .app,
            date: nil, badge: nil,
            openTarget: .file(name), rank: rank
        )
    }

    private func makeImage(_ path: String, rank: Int) -> SearchResult {
        SearchResult(
            title: path, subtitle: "", source: .images,
            date: nil, badge: nil,
            openTarget: .file(path), rank: rank
        )
    }

    private func makeWindow(_ action: WindowAction, rank: Int) -> SearchResult {
        SearchResult(
            title: String(describing: action), subtitle: "", source: .window,
            date: nil, badge: nil,
            openTarget: .windowAction(action), rank: rank
        )
    }

    private func makeSystemAction(_ action: SystemAction, rank: Int) -> SearchResult {
        SearchResult(
            title: String(describing: action), subtitle: "", source: .systemAction,
            date: nil, badge: nil,
            openTarget: .systemAction(action), rank: rank
        )
    }
}
