import XCTest

@testable import SharedCore

final class TranscriptChunkerTests: XCTestCase {

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(TranscriptChunker.chunk(lines: [], meetingTitle: "T").isEmpty)
    }

    func testSkipsBlankUtterances() {
        let lines = [
            TranscriptChunker.Line(t: 0, speaker: "You", text: "   "),
            TranscriptChunker.Line(t: 1, speaker: "You", text: "real content here"),
        ]
        let out = TranscriptChunker.chunk(lines: lines, meetingTitle: "T")
        XCTAssertEqual(out.count, 1)
        XCTAssertFalse(out[0].text.contains("You:   "))
        XCTAssertTrue(out[0].text.contains("real content here"))
    }

    func testSingleChunkCapturesProvenance() {
        let lines = [
            TranscriptChunker.Line(t: 12, speaker: "You", text: "hi sarah"),
            TranscriptChunker.Line(t: 18, speaker: "Sarah", text: "hey ready to start"),
            TranscriptChunker.Line(t: 25, speaker: "You", text: "let's go"),
        ]
        let out = TranscriptChunker.chunk(lines: lines, meetingTitle: "Q2 Strategy")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].tsStart, 12)
        XCTAssertEqual(out[0].speakers, ["You", "Sarah"])  // first-seen order, deduped
        XCTAssertTrue(out[0].breadcrumb.hasPrefix("Q2 Strategy · "))
        XCTAssertTrue(out[0].text.contains("Sarah: hey ready to start"))
    }

    func testWindowingWithOverlap() {
        // 120 lines × 10 words = 1200 words; budget 500 → multiple overlapping windows.
        let lines = (0..<120).map { i in
            TranscriptChunker.Line(
                t: Double(i),
                speaker: i.isMultiple(of: 2) ? "You" : "Sarah",
                text: "u\(i) " + Array(repeating: "x", count: 9).joined(separator: " ")
            )
        }
        let out = TranscriptChunker.chunk(lines: lines, meetingTitle: "M")
        XCTAssertGreaterThanOrEqual(out.count, 3)
        // tsStart is non-decreasing and strictly advances (termination).
        for i in 1..<out.count {
            XCTAssertGreaterThan(out[i].tsStart, out[i - 1].tsStart)
        }
        // A boundary line appears in two consecutive windows (overlap continuity):
        // window 0 covers lines 0..49, window 1 starts at line 40 → "u40" in both.
        XCTAssertTrue(out[0].text.contains("u40"))
        XCTAssertTrue(out[1].text.contains("u40"))
        // No window grossly exceeds the budget. The word budget is on transcript
        // content; the rendered text adds a "Speaker:" token per line, so allow
        // headroom over targetMax (500) while staying well under the 1200 total.
        for chunk in out {
            let words = chunk.text.split(whereSeparator: \.isWhitespace).count
            XCTAssertLessThanOrEqual(words, 620)
        }
    }

    func testOverLongSingleUtteranceIsNotSplit() {
        let big = (0..<800).map { "w\($0)" }.joined(separator: " ")
        let out = TranscriptChunker.chunk(
            lines: [TranscriptChunker.Line(t: 3, speaker: "You", text: big)],
            meetingTitle: "M"
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].tsStart, 3)
    }

    func testTimeLabelFormats() {
        XCTAssertEqual(TranscriptChunker.timeLabel(0), "00:00")
        XCTAssertEqual(TranscriptChunker.timeLabel(68), "01:08")
        XCTAssertEqual(TranscriptChunker.timeLabel(3661), "1:01:01")
    }
}
