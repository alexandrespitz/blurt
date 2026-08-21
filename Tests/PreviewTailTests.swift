import XCTest

final class PreviewTailTests: XCTestCase {

    func testShortTextPassesThrough() {
        XCTAssertEqual(PreviewTail.trim("Bonjour, je vous remercie beaucoup."),
                       "Bonjour, je vous remercie beaucoup.")
    }

    func testLongTextKeepsTheNewestWords() {
        let text = "The quick brown fox jumps over the lazy dog and runs into the forest "
            + "where it meets another fox entirely"
        let trimmed = PreviewTail.trim(text)
        XCTAssertTrue(trimmed.hasPrefix("…"), "the cut must be marked")
        XCTAssertTrue(trimmed.hasSuffix("another fox entirely"),
                      "the END of the dictation is what must stay visible")
        XCTAssertFalse(trimmed.contains("quick brown"),
                       "the oldest words are the ones that go")
        XCTAssertLessThanOrEqual(trimmed.count, 58)
    }

    func testCutLandsOnAWordBoundary() {
        let text = String(repeating: "palavra ", count: 20)
        let trimmed = PreviewTail.trim(text)
        XCTAssertTrue(trimmed.hasPrefix("…palavra "),
                      "no half-word right after the ellipsis")
    }

    func testUnbrokenTextStillTrims() {
        let text = String(repeating: "a", count: 200)
        let trimmed = PreviewTail.trim(text)
        XCTAssertTrue(trimmed.hasPrefix("…"))
        XCTAssertLessThanOrEqual(trimmed.count, 58)
    }
}
