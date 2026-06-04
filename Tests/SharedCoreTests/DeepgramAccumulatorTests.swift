import XCTest

@testable import SharedCore

/// BAS-7 — the pure de-chunking core of the cloud streaming transcriber.
///
/// Deepgram's realtime socket emits interim ("is_final": false) results that
/// REPLACE the current utterance, and final results that COMMIT it; the next
/// interim then starts fresh. The accumulator turns that frame stream into a
/// single cumulative transcript (same job Apple's chunk-merger does locally).
final class DeepgramTranscriptAccumulatorTests: XCTestCase {
    func testInterimReplacesThenFinalCommits() {
        var acc = DeepgramTranscriptAccumulator()
        XCTAssertEqual(acc.ingest(jsonFrame: frame("hel", final: false)), "hel")
        XCTAssertEqual(acc.ingest(jsonFrame: frame("hello", final: false)), "hello")
        XCTAssertEqual(acc.ingest(jsonFrame: frame("hello world", final: true)), "hello world")
    }

    func testNextInterimAppendsAfterCommittedFinal() {
        var acc = DeepgramTranscriptAccumulator()
        _ = acc.ingest(jsonFrame: frame("hello world", final: true))
        XCTAssertEqual(acc.ingest(jsonFrame: frame("goodbye", final: false)), "hello world goodbye")
    }

    func testTwoFinalsConcatenate() {
        var acc = DeepgramTranscriptAccumulator()
        _ = acc.ingest(jsonFrame: frame("one", final: true))
        XCTAssertEqual(acc.ingest(jsonFrame: frame("two", final: true)), "one two")
        XCTAssertEqual(acc.cumulative, "one two")
    }

    func testEmptyTranscriptFrameDoesNotChangeCumulative() {
        var acc = DeepgramTranscriptAccumulator()
        _ = acc.ingest(jsonFrame: frame("hello", final: true))
        XCTAssertNil(acc.ingest(jsonFrame: frame("", final: false)))
        XCTAssertEqual(acc.cumulative, "hello")
    }

    func testGarbageAndNonResultFramesIgnored() {
        var acc = DeepgramTranscriptAccumulator()
        XCTAssertNil(acc.ingest(jsonFrame: "not json at all"))
        XCTAssertNil(acc.ingest(jsonFrame: #"{"type":"Metadata","duration":1.0}"#))
        XCTAssertEqual(acc.cumulative, "")
    }

    private func frame(_ transcript: String, final: Bool) -> String {
        #"{"type":"Results","is_final":\#(final),"channel":{"alternatives":[{"transcript":"\#(transcript)"}]}}"#
    }
}
