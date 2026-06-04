import XCTest

@testable import MeetingModule

/// BAS-48: the compact one-line digest the coach overlay shows under the
/// metrics/talk-time strip, e.g. `Now: pricing · open: can we discount?`.
final class ConversationStateOverlayLineTests: XCTestCase {

    func testTopicAndOpenQuestion() {
        let state = ConversationStateModel(
            topic: "pricing", summary: "",
            openQuestions: ["can we discount?"], activeTensions: [], recentDecisions: []
        )
        XCTAssertEqual(state.overlayLine, "Now: pricing · open: can we discount?")
    }

    func testTopicOnly() {
        let state = ConversationStateModel(
            topic: "pricing", summary: "lots of detail",
            openQuestions: [], activeTensions: [], recentDecisions: []
        )
        XCTAssertEqual(state.overlayLine, "Now: pricing")
    }

    func testTensionFallbackWhenNoOpenQuestion() {
        let state = ConversationStateModel(
            topic: "pricing", summary: "",
            openQuestions: [], activeTensions: ["budget vs scope"], recentDecisions: []
        )
        XCTAssertEqual(state.overlayLine, "Now: pricing · tension: budget vs scope")
    }

    func testWhitespaceOnlyOpenQuestionFallsBackToTension() {
        // A blank/whitespace open question must not suppress the tension fallback.
        let state = ConversationStateModel(
            topic: "pricing", summary: "",
            openQuestions: ["   "], activeTensions: ["budget vs scope"], recentDecisions: []
        )
        XCTAssertEqual(state.overlayLine, "Now: pricing · tension: budget vs scope")
    }

    func testBlankFirstOpenQuestionSkipsToNextNonEmpty() {
        let state = ConversationStateModel(
            topic: "pricing", summary: "",
            openQuestions: ["", "can we discount?"], activeTensions: [], recentDecisions: []
        )
        XCTAssertEqual(state.overlayLine, "Now: pricing · open: can we discount?")
    }

    func testEmptyWithoutTopic() {
        XCTAssertEqual(ConversationStateModel.empty.overlayLine, "")
        let noTopic = ConversationStateModel(
            topic: "", summary: "stuff",
            openQuestions: ["q?"], activeTensions: [], recentDecisions: []
        )
        XCTAssertEqual(noTopic.overlayLine, "")
    }

    func testLongFieldsAreCondensed() {
        let long = String(repeating: "word ", count: 40)
        let state = ConversationStateModel(
            topic: long, summary: "",
            openQuestions: [long], activeTensions: [], recentDecisions: []
        )
        let line = state.overlayLine
        XCTAssertTrue(line.hasPrefix("Now: "))
        XCTAssertTrue(line.contains("…"))
        // Topic + open both clipped to ~48 chars, plus the "Now: " / " · open: " labels.
        XCTAssertLessThan(line.count, 120)
    }
}
