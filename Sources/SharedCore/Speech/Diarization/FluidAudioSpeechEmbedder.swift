import FluidAudio
import Foundation

/// Production `SpeechEmbedding` backed by FluidAudio's on-device WeSpeaker
/// embedding model (the same one the diarizer uses).
///
/// Models download/compile
/// lazily on first use; any failure resolves to `nil` so live diarization
/// degrades to the coarse `system_audio` label rather than throwing into the
/// capture hot loop. On-device only — no network in the steady state, no cost.
public final class FluidAudioSpeechEmbedder: SpeechEmbedding, @unchecked Sendable {

    private let lock = NSLock()
    private var manager: DiarizerManager?

    public init() {}

    /// Download/compile + load the embedding model so the first live segment
    /// doesn't pay for it (and so readiness can be confirmed before a meeting).
    public func prepare() async throws {
        _ = try await ensureManager()
    }

    public func embed(samples: [Float], sampleRate: Double) async -> [Float]? {
        do {
            let manager = try await ensureManager()
            let normalized = try AudioResampler.resampleMono(samples, from: sampleRate)
            guard !normalized.isEmpty else { return nil }
            let embedding = try manager.extractSpeakerEmbedding(from: normalized)
            return embedding.isEmpty ? nil : embedding
        } catch {
            Loggers.meeting.error(
                "Live speaker embedding failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func ensureManager() async throws -> DiarizerManager {
        if let existing = lock.withLock({ manager }) { return existing }
        let models = try await DiarizerModels.downloadIfNeeded()
        let mgr = DiarizerManager()
        mgr.initialize(models: models)
        lock.withLock { manager = mgr }
        return mgr
    }
}
