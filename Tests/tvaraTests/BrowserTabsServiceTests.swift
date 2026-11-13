import XCTest
@testable import tvara

final class BrowserTabsServiceTests: XCTestCase {

    private func tab(_ title: String, url: String = "") -> BrowserTab {
        BrowserTab(
            bundleID: "com.google.Chrome", pid: 1, browserName: "Google Chrome",
            windowID: 1, windowIndex: 0, tabIndex: 1, title: title, url: url
        )
    }

    private func rank(_ title: String, url: String = "", _ q: String, frontmost: Bool = false) -> Int? {
        BrowserTabsService.rank(tab: tab(title, url: url), query: q, browserIsFrontmost: frontmost)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(rank("Inbox – Gmail", url: "https://mail.google.com", "linear"))
    }

    func testTitlePrefixBeatsWordPrefixBeatsContainsBeatsURL() {
        let prefix = rank("GitHub pull requests", "git")!
        let word = rank("Pull requests · GitHub", "git")!
        let contains = rank("Legit docs", "git")!
        let url = rank("Pull requests", url: "https://github.com/pulls", "git")!
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, contains)
        XCTAssertGreaterThan(contains, url)
    }

    func testMatchIsCaseInsensitiveOnTitle() {
        XCTAssertNotNil(rank("YouTube", "youtube"))
    }

    /// Tabs of the browser the launcher was opened from outrank an ordinary
    /// app prefix match (500) but never an exact app name (1500).
    func testFrontmostBrowserTabsSitBetweenAppPrefixAndExactAppName() {
        for (title, url) in [("GitHub", ""), ("My GitHub", ""), ("Legit", ""), ("x", "https://github.com")] {
            let r = rank(title, url: url, "git", frontmost: true)!
            XCTAssertGreaterThan(r, 500)
            XCTAssertLessThan(r, 1500)
        }
    }

    /// Tabs of a browser in the background stay under the matching app tier.
    func testBackgroundBrowserTabsStayBelowAppPrefix() {
        XCTAssertLessThan(rank("GitHub", "git")!, 500)
    }
}

final class TabFaviconStoreTests: XCTestCase {

    /// "mozLz40\0" + little-endian size + a raw LZ4 block that is a single
    /// literal run: token 0x50 (5 literals, no match) then the bytes.
    func testMozLz4DecodesLiteralBlock() {
        var data = Data("mozLz40\0".utf8)
        data.append(contentsOf: [5, 0, 0, 0])
        data.append(0x50)
        data.append(Data("hello".utf8))
        XCTAssertEqual(TabFaviconStore.mozLz4Decode(data), Data("hello".utf8))
    }

    func testMozLz4RejectsWrongMagic() {
        XCTAssertNil(TabFaviconStore.mozLz4Decode(Data("notLz40\0\u{5}\0\0\0Phello".utf8)))
    }
}
