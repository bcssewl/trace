@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// On-device Qwen3-ASR (multilingual, 30+ languages incl. Mandarin/Cantonese/Arabic)
/// via FluidAudio's CoreML pipeline (FluidAudio 0.14.7,
/// `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Qwen3/`).
///
/// Mirrors `ParakeetBackend`'s lazy "download + load on first prepare" pattern:
/// the 2-model CoreML pipeline (audio encoder + stateful decoder + embedding
/// weights + vocab) is fetched from Hugging Face on first use, cached on disk,
/// then reused for every transcription. Unlike Parakeet (English/European),
/// Qwen3 covers 30 languages, so it honours the requested `locale` as a hint.
///
/// Variants (`Qwen3AsrVariant`): `.f32` (full precision, ~1.75 GB, fastest) and
/// `.int8` (int8-quantized, ~900 MB RAM, same quality). Both are the 0.6B model.
public actor Qwen3Backend: TranscriptionBackend {
    public nonisolated let displayName = "Qwen3-ASR"

    /// Model precision variant.
    ///
    /// The 0.6B model ships in two flavours; `.f32` is
    /// the speed-optimal default, `.int8` halves RAM for memory-constrained use.
    private let variant: Qwen3AsrVariant

    /// Cached manager — `nil` until `prepare()` downloads + loads the models.
    private var manager: Qwen3AsrManager?

    /// Decoder token budget per utterance. 512 matches the model's KV-cache
    /// (`Qwen3AsrConfig.maxCacheSeqLen`) and the CLI's default.
    private static let maxNewTokens = 512

    /// - Parameter variant: model precision. Defaults to `.f32` (the 0.6B
    ///   full-precision build); pass `.int8` for the lower-RAM quantized build.
    public init(variant: Qwen3AsrVariant = .f32) {
        self.variant = variant
    }

    public func checkStatus() async -> BackendStatus {
        if manager != nil { return .loaded }
        // Probe the on-disk cache so a freshly-built backend (e.g. the readiness
        // probe) reports `.ready` without re-downloading. Mirrors WhisperKit.
        let cacheDir = Qwen3AsrModels.defaultCacheDirectory(variant: variant)
        return Qwen3AsrModels.modelsExist(at: cacheDir) ? .ready : .notDownloaded
    }

    public func prepare(
        onStatus: @escaping @Sendable (BackendStatus) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if manager != nil {
            onStatus(.loaded)
            onProgress(1)
            return
        }
        onStatus(.downloading(progress: 0))
        onProgress(0)

        // Download (no-op if already cached) with real progress, then load the
        // 2-model pipeline. `downloadAndLoad` chains both for us and surfaces the
        // HF download fraction via `DownloadUtils.ProgressHandler`.
        let asrManager = Qwen3AsrManager()
        do {
            try await asrManager.loadModels(
                from: try await Qwen3AsrModels.download(
                    variant: variant,
                    progressHandler: { progress in
                        let fraction = max(0, min(1, progress.fractionCompleted))
                        onProgress(fraction)
                        onStatus(.downloading(progress: fraction))
                    }
                )
            )
        } catch {
            throw TraceError.asrInferenceFailed(
                engine: "qwen3",
                reason: "failed to download/load Qwen3-ASR \(variant.rawValue) models: \(error.localizedDescription)"
            )
        }
        self.manager = asrManager
        onStatus(.loaded)
        onProgress(1)
    }

    public func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
        guard let manager else {
            throw TraceError.asrInferenceFailed(
                engine: "qwen3",
                reason: "Qwen3Backend not prepared — call prepare() before transcribe()"
            )
        }
        // `previousContext` is unused: Qwen3-ASR is a stateless per-utterance chat
        // template (it rebuilds the prompt each call and has no priming hook), so
        // there is nowhere to thread prior text — same as Parakeet/WhisperKit.
        do {
            return try await manager.transcribe(
                audioSamples: samples,
                language: Self.qwen3Language(for: locale),
                maxNewTokens: Self.maxNewTokens
            )
        } catch {
            throw TraceError.asrInferenceFailed(
                engine: "qwen3",
                reason: error.localizedDescription
            )
        }
    }

    public func transcribeStream(_ buffer: AVAudioPCMBuffer) async throws -> ASRDelta? {
        nil
    }

    public func clearModelCache() async {
        manager = nil
    }

    /// Map a requested `locale` to a Qwen3 language hint, or `nil` to let the
    /// model auto-detect.
    ///
    /// Honours our `.autoDetect` ("und") sentinel and only
    /// returns a hint for one of Qwen3's 30 supported languages — an unsupported
    /// locale falls back to auto-detect rather than a wrong hint.
    private static func qwen3Language(for locale: Locale) -> Qwen3AsrConfig.Language? {
        if locale.isAutoDetect { return nil }
        guard let code = locale.language.languageCode?.identifier else { return nil }
        return Qwen3AsrConfig.Language(from: code)
    }
}
