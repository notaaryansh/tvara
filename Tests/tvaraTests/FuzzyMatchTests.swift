import XCTest
@testable import spotlight__

final class FuzzyMatchTests: XCTestCase {

    // MARK: - Identity / trivial

    func testIdenticalStringsReturnZero() {
        XCTAssertEqual(FuzzyMatch.levenshtein("hello", "hello", budget: 2), 0)
    }

    func testEmptyAgainstEmptyReturnsZero() {
        XCTAssertEqual(FuzzyMatch.levenshtein("", "", budget: 0), 0)
    }

    func testEmptyAgainstNonEmptyEqualsLength() {
        XCTAssertEqual(FuzzyMatch.levenshtein("", "abc", budget: 5), 3)
        XCTAssertEqual(FuzzyMatch.levenshtein("xyz", "", budget: 5), 3)
    }

    // MARK: - Single-edit distances

    func testSingleSubstitution() {
        XCTAssertEqual(FuzzyMatch.levenshtein("cat", "car", budget: 2), 1)
    }

    func testSingleInsertion() {
        XCTAssertEqual(FuzzyMatch.levenshtein("cat", "cats", budget: 2), 1)
    }

    func testSingleDeletion() {
        XCTAssertEqual(FuzzyMatch.levenshtein("cats", "cat", budget: 2), 1)
    }

    // MARK: - Budget enforcement

    func testReturnsNilWhenDistanceExceedsBudget() {
        XCTAssertNil(FuzzyMatch.levenshtein("abc", "xyz", budget: 1))
    }

    func testReturnsValueWhenAtBudget() {
        XCTAssertEqual(FuzzyMatch.levenshtein("abc", "abd", budget: 1), 1)
    }

    func testLengthGapExceedingBudgetRejectsEarly() {
        // "a" and "abcdef" differ by 5 — budget of 2 must reject without DP work.
        XCTAssertNil(FuzzyMatch.levenshtein("a", "abcdef", budget: 2))
    }

    // MARK: - budget(for:) — scales with query length

    func testBudgetIsZeroForShortQueries() {
        XCTAssertEqual(FuzzyMatch.budget(for: ""), 0)
        XCTAssertEqual(FuzzyMatch.budget(for: "a"), 0)
        XCTAssertEqual(FuzzyMatch.budget(for: "ab"), 0)
        XCTAssertEqual(FuzzyMatch.budget(for: "abc"), 0)
    }

    func testBudgetIsOneForFourCharQueries() {
        XCTAssertEqual(FuzzyMatch.budget(for: "abcd"), 1)
    }

    func testBudgetIsTwoForLongerQueries() {
        XCTAssertEqual(FuzzyMatch.budget(for: "abcde"), 2)
        XCTAssertEqual(FuzzyMatch.budget(for: "abcdefghij"), 2)
    }
}
