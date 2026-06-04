import FluidAudio
import Foundation

/// Produces a fixed-dimension speaker embedding for one mono speech segment.
///
/// The seam that lets the live labeler be unit-tested without CoreML models:
/// production uses `FluidAudioSpeechEmbedder`, tests script the vectors.
public protocol SpeechEmbedding: Sendable {
    /// A speaker embedding for the segment, or `nil` when one can't be produced
    /// (model unavailable, segment silent/too short, extraction failed).
    func embed(samples: [Float], sampleRate: Double) async -> [Float]?
}

/// The cheap, display-only live diarization pass. For each committed *remote*
/// speech segment it extracts a voice embedding and clusters it online (via
/// FluidAudio's `SpeakerManager`, the same proven cosine-distance tracker its
/// streaming diarizer uses), assigning a stable `remote_N` so the tri-column
/// transcript can distinguish participants as they take turns. The heavyweight
/// offline pass (`DiarizationRefiner`) later overwrites these with the
/// source-of-truth labels, so this only has to be good enough to read live.
///
/// Returns `nil` for segments too short to cluster reliably or when embedding
/// fails — the caller then keeps the coarse `system_audio` label, so live
/// diarization degrades gracefully to the previous behavior rather than guessing.
public actor LiveSpeakerLabeler {

    private let embedder: any SpeechEmbedding
    private var speakerManager: SpeakerManager
    private var allocator = SpeakerLabelAllocator()
    private let minDurationToLabel: TimeInterval

    public init(
        embedder: any SpeechEmbedding,
        speakerThreshold: Float = 0.7,
        minSpeechDuration: Float = 1.0,
        minDurationToLabel: TimeInterval = 0.6
    ) {
        self.embedder = embedder
        self.minDurationToLabel = minDurationToLabel
        self.speakerManager = SpeakerManager(
            speakerThreshold: speakerThreshold,
            embeddingThreshold: speakerThreshold * 0.7,
            minSpeechDuration: minSpeechDuration,
            minEmbeddingUpdateDuration: max(minSpeechDuration, 2.0)
        )
    }

    /// Label one committed remote speech segment, or `nil` to fall back to the
    /// coarse `system_audio` label.
    public func label(samples: [Float], sampleRate: Double, duration: TimeInterval) async -> String? {
        guard duration >= minDurationToLabel else { return nil }
        guard let embedding = await embedder.embed(samples: samples, sampleRate: sampleRate) else {
            return nil
        }
        guard
            let speaker = speakerManager.assignSpeaker(
                embedding, speechDuration: Float(duration), confidence: 1.0
            )
        else {
            return nil
        }
        return allocator.label(forEngineCluster: speaker.id)
    }

    /// Reset clustering + labels for a fresh meeting.
    public func reset() {
        speakerManager.reset()
        allocator = SpeakerLabelAllocator()
    }
}
