import XCTest

@testable import SharedCore

/// `DiarizationRefiner` is the pure offline "source of truth" pass: given the
/// utterances captured live (mic tagged `.you`, the remote stream tagged
/// `system_audio`/best-effort live labels) plus the speaker segments produced by
/// re-diarizing the recorded system audio, it re-attributes every remote
/// utterance to a stable `remote_N` speaker, merging same-speaker runs separated
/// by tiny gaps. `.you` (mic) utterances are never touched.
final class DiarizationRefinerTests: XCTestCase {

    private func you(_ t: Double, _ text: String) -> Utterance {
        Utterance(t: t, speaker: .you, text: text, conf: 0.6, diar: "mic-stream")
    }

    private func remote(_ t: Double, _ text: String, id: String = "system_audio") -> Utterance {
        Utterance(t: t, speaker: .other(id: id), text: text, conf: 0.6, diar: "system-stream")
    }

    private func seg(_ start: Double, _ end: Double, _ speaker: String) -> DiarizedSegment {
        DiarizedSegment(startTime: start, endTime: end, speakerLabel: speaker)
    }

    func testNoSegmentsLeavesUtterancesUnchanged() {
        let refiner = DiarizationRefiner()
        let input = [you(0, "hi"), remote(1, "hello")]
        let out = refiner.refine(utterances: input, segments: [])
        XCTAssertEqual(out, input)
    }

    func testYouUtterancesAreNeverReattributed() {
        let refiner = DiarizationRefiner()
        let input = [you(0, "mine"), remote(2, "theirs")]
        let segments = [seg(1.5, 5.0, "0")]
        let out = refiner.refine(utterances: input, segments: segments)
        let mine = out.first { $0.text == "mine" }
        XCTAssertEqual(mine?.speaker, .you)
        XCTAssertEqual(mine?.diar, "mic-stream")
    }

    func testSingleSpeakerMapsAllRemoteToRemote1() {
        let refiner = DiarizationRefiner()
        let input = [remote(1, "a"), remote(4, "b"), remote(7, "c")]
        let segments = [seg(0, 10, "3")]  // one speaker, engine id "3"
        let out = refiner.refine(utterances: input, segments: segments)
        XCTAssertEqual(out.map(\.speaker), Array(repeating: .other(id: "remote_1"), count: 3))
    }

    func testTwoAlternatingSpeakersGetDistinctStableLabels() {
        let refiner = DiarizationRefiner()
        let input = [
            remote(1, "first"),
            remote(6, "second"),
            remote(11, "third"),
        ]
        // Speaker "0" owns [0,5] and [10,15]; speaker "1" owns [5,10].
        let segments = [
            seg(0, 5, "0"),
            seg(5, 10, "1"),
            seg(10, 15, "0"),
        ]
        let out = refiner.refine(utterances: input, segments: segments)
        XCTAssertEqual(out[0].speaker, .other(id: "remote_1"))  // "first" in speaker 0
        XCTAssertEqual(out[1].speaker, .other(id: "remote_2"))  // "second" in speaker 1
        XCTAssertEqual(out[2].speaker, .other(id: "remote_1"))  // "third" back to speaker 0
    }

    func testLabelNumberingFollowsRunStartOrderNotEngineId() {
        let refiner = DiarizationRefiner()
        let input = [remote(1, "early"), remote(6, "late")]
        // Engine id "9" appears first in time → must become remote_1.
        let segments = [seg(0, 5, "9"), seg(5, 10, "2")]
        let out = refiner.refine(utterances: input, segments: segments)
        XCTAssertEqual(out[0].speaker, .other(id: "remote_1"))
        XCTAssertEqual(out[1].speaker, .other(id: "remote_2"))
    }

    func testTinyGapSameSpeakerMergesIntoOneRun() {
        let refiner = DiarizationRefiner(config: .init(mergeGapSeconds: 0.8))
        // Same speaker "0" split by a 0.5s gap — should be ONE speaker (remote_1),
        // and the utterance falling inside the gap still attributes to remote_1.
        let segments = [seg(0, 3.0, "0"), seg(3.5, 6.0, "0")]
        let input = [remote(3.2, "in the gap")]
        let out = refiner.refine(utterances: input, segments: segments)
        XCTAssertEqual(out[0].speaker, .other(id: "remote_1"))
    }

    func testRefinedUtterancesCarryProvenanceDiarTag() {
        let refiner = DiarizationRefiner(config: .init(provenancePrefix: "pyannote"))
        let input = [remote(1, "x")]
        let segments = [seg(0, 5, "4")]
        let out = refiner.refine(utterances: input, segments: segments)
        XCTAssertEqual(out[0].diar, "pyannote:4")
    }

    func testUtteranceTextAndTimeArePreserved() {
        let refiner = DiarizationRefiner()
        let input = [remote(2.5, "keep me exactly")]
        let segments = [seg(0, 5, "0")]
        let out = refiner.refine(utterances: input, segments: segments)
        XCTAssertEqual(out[0].text, "keep me exactly")
        XCTAssertEqual(out[0].t, 2.5)
    }

    func testOutputIsSortedByTimeAcrossStreams() {
        let refiner = DiarizationRefiner()
        let input = [remote(5, "late-remote"), you(1, "early-you")]
        let segments = [seg(0, 10, "0")]
        let out = refiner.refine(utterances: input, segments: segments)
        XCTAssertEqual(out.map(\.t), [1, 5])
    }

    func testUtteranceWithNoOverlapAttachesToNearestSpeaker() {
        let refiner = DiarizationRefiner()
        // Utterance at t=20 lies after all diarized runs; nearest is speaker "1"
        // (its run ends at 12, vs speaker 0 ending at 6).
        let segments = [seg(0, 6, "0"), seg(8, 12, "1")]
        let input = [remote(20, "trailing")]
        let out = refiner.refine(utterances: input, segments: segments)
        XCTAssertEqual(out[0].speaker, .other(id: "remote_2"))
    }

    // MARK: - refineDetailed: per-speaker mean embeddings (BAS-11)

    /// The detailed pass exposes a mean voiceprint per allocated `remote_N`,
    /// averaged element-wise over that cluster's segment embeddings.
    ///
    /// This is the
    /// raw material the cross-meeting speaker memory matches against — without it
    /// the embeddings the diarizer produces are silently discarded.
    func testRefineDetailedReturnsMeanEmbeddingPerRemoteLabel() {
        let refiner = DiarizationRefiner()
        let input = [remote(1, "a"), remote(6, "b")]
        let segments = [
            DiarizedSegment(startTime: 0, endTime: 3, speakerLabel: "0", embedding: [1, 0, 0]),
            DiarizedSegment(startTime: 3, endTime: 5, speakerLabel: "0", embedding: [3, 0, 0]),
            DiarizedSegment(startTime: 5, endTime: 9, speakerLabel: "1", embedding: [0, 4, 0]),
        ]
        let result = refiner.refineDetailed(utterances: input, segments: segments)
        XCTAssertEqual(result.speakerEmbeddings["remote_1"], [2, 0, 0])
        XCTAssertEqual(result.speakerEmbeddings["remote_2"], [0, 4, 0])
    }

    /// Clusters whose segments carried no embedding produce no entry (rather than
    /// a zero vector that would spuriously match everything / nothing).
    func testRefineDetailedOmitsLabelsWithoutEmbeddings() {
        let refiner = DiarizationRefiner()
        let segments = [seg(0, 5, "0")]  // seg() builds a segment with nil embedding
        let result = refiner.refineDetailed(utterances: [remote(1, "x")], segments: segments)
        XCTAssertNil(result.speakerEmbeddings["remote_1"])
    }

    /// `refine` is just `refineDetailed(...).utterances` — the re-attribution
    /// behaviour is identical; the detailed variant only adds the embedding map.
    func testRefineDetailedUtterancesEqualRefine() {
        let refiner = DiarizationRefiner()
        let input = [you(0, "mine"), remote(2, "theirs")]
        let segments = [seg(1.5, 5.0, "0")]
        let result = refiner.refineDetailed(utterances: input, segments: segments)
        XCTAssertEqual(result.utterances, refiner.refine(utterances: input, segments: segments))
    }
}
