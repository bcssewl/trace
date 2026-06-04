import XCTest

@testable import AppShell

/// The shared block parser extracted from `BrutalistMarkdownView` +
/// `CitedAnswerView` (BAS-32).
///
/// Both views consume the same block model; only the
/// inline rendering differs, so the block split must stay byte-for-byte the
/// behavior the two views previously implemented in lock-step.
final class BrutalistMarkdownParserTests: XCTestCase {

    func testHeadingLevelsOneThroughFour() {
        XCTAssertEqual(BrutalistMarkdownParser.parse("# One"), [.heading(level: 1, text: "One")])
        XCTAssertEqual(BrutalistMarkdownParser.parse("## Two"), [.heading(level: 2, text: "Two")])
        XCTAssertEqual(BrutalistMarkdownParser.parse("### Three"), [.heading(level: 3, text: "Three")])
        XCTAssertEqual(BrutalistMarkdownParser.parse("#### Four"), [.heading(level: 4, text: "Four")])
    }

    func testLongestHeadingPrefixWins() {
        // "### x" must parse as level 3, not level 1 with "## x" text.
        XCTAssertEqual(BrutalistMarkdownParser.parse("### Deep"), [.heading(level: 3, text: "Deep")])
    }

    func testHashWithoutSpaceIsParagraphNotHeading() {
        XCTAssertEqual(BrutalistMarkdownParser.parse("#NotAHeading"), [.paragraph(text: "#NotAHeading")])
    }

    func testBulletStarAndDash() {
        XCTAssertEqual(BrutalistMarkdownParser.parse("* Star item"), [.bullet(text: "Star item")])
        XCTAssertEqual(BrutalistMarkdownParser.parse("- Dash item"), [.bullet(text: "Dash item")])
    }

    func testPlainParagraph() {
        XCTAssertEqual(
            BrutalistMarkdownParser.parse("Just a sentence."),
            [.paragraph(text: "Just a sentence.")]
        )
    }

    func testBlankLinesSkippedAndWhitespaceTrimmed() {
        let blocks = BrutalistMarkdownParser.parse("\n   \n  # Title  \n\n  Body line  \n")
        XCTAssertEqual(blocks, [.heading(level: 1, text: "Title"), .paragraph(text: "Body line")])
    }

    func testMixedDocumentPreservesOrder() {
        let md = """
            # Summary
            Intro paragraph.
            ## Decisions
            * First
            - Second
            Closing remark.
            """
        XCTAssertEqual(
            BrutalistMarkdownParser.parse(md),
            [
                .heading(level: 1, text: "Summary"),
                .paragraph(text: "Intro paragraph."),
                .heading(level: 2, text: "Decisions"),
                .bullet(text: "First"),
                .bullet(text: "Second"),
                .paragraph(text: "Closing remark."),
            ]
        )
    }
}
