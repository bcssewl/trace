import XCTest

@testable import SharedCore

/// `LiveSpeakerLabeler` is the cheap, display-only live pass.
///
/// For each committed
/// remote speech segment it extracts a voice embedding (behind the
/// `SpeechEmbedding` seam, faked here) and clusters it online so the tri-column
/// transcript can show `remote_1 / remote_2 / …` as people take turns — before
/// the heavyweight offline pass refines them. These tests pin the orchestration:
/// stable ids for the same voice, fresh ids for new voices, and graceful nil
/// (→ caller falls back to the coarse `system_audio` label) when embedding fails
/// or the segment is too short to cluster reliably.
final class LiveSpeakerLabelerTests: XCTestCase {

    /// Hands back scripted embeddings in call order; `nil` entries simulate a
    /// failed/again-unavailable extraction.
    private actor ScriptedEmbedder: SpeechEmbedding {
        private var queue: [[Float]?]
        private(set) var callCount = 0
        init(_ queue: [[Float]?]) { self.queue = queue }
        func embed(samples: [Float], sampleRate: Double) async -> [Float]? {
            callCount += 1
            guard !queue.isEmpty else { return nil }
            return queue.removeFirst()
        }
    }

    /// A 256-d one-hot vector — distinct indices are orthogonal (cosine distance
    /// 1.0 → different speakers); repeats are identical (distance 0 → same).
    /// 256 is FluidAudio's fixed speaker-embedding dimension.
    private func voice(_ index: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[index] = 1
        return v
    }

    private let dummySamples = [Float](repeating: 0.1, count: 16_000)

    private func makeLabeler(_ embedder: ScriptedEmbedder) -> LiveSpeakerLabeler {
        LiveSpeakerLabeler(
            embedder: embedder,
            speakerThreshold: 0.5,
            minSpeechDuration: 0.1,
            minDurationToLabel: 0.5
        )
    }

    func testFirstRemoteSegmentBecomesRemote1() async {
        let labeler = makeLabeler(ScriptedEmbedder([voice(0)]))
        let label = await labeler.label(samples: dummySamples, sampleRate: 16_000, duration: 1.5)
        XCTAssertEqual(label, "remote_1")
    }

    func testDistinctVoicesGetDistinctStableLabels() async {
        let labeler = makeLabeler(ScriptedEmbedder([voice(0), voice(1), voice(0)]))
        let a = await labeler.label(samples: dummySamples, sampleRate: 16_000, duration: 1.5)
        let b = await labeler.label(samples: dummySamples, sampleRate: 16_000, duration: 1.5)
        let aAgain = await labeler.label(samples: dummySamples, sampleRate: 16_000, duration: 1.5)
        XCTAssertEqual(a, "remote_1")
        XCTAssertEqual(b, "remote_2")
        XCTAssertEqual(aAgain, "remote_1", "Same voice must keep its remote id within a meeting")
    }

    func testNilEmbeddingFallsBackToNoLabel() async {
        let labeler = makeLabeler(ScriptedEmbedder([nil]))
        let label = await labeler.label(samples: dummySamples, sampleRate: 16_000, duration: 1.5)
        XCTAssertNil(label, "A failed embedding yields nil so the caller keeps system_audio")
    }

    func testShortSegmentIsNotLabeledAndSkipsEmbedding() async {
        let embedder = ScriptedEmbedder([voice(0)])
        let labeler = makeLabeler(embedder)
        let label = await labeler.label(samples: dummySamples, sampleRate: 16_000, duration: 0.2)
        XCTAssertNil(label)
        let calls = await embedder.callCount
        XCTAssertEqual(calls, 0, "Segments below the labeling floor must not invoke the embedder")
    }
}
