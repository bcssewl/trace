import FluidAudio
import Foundation

/// One user-selectable on-device ASR model.
///
/// Single source of truth read by the
/// Settings "Local" catalog UI, the per-model downloader, and the engine→backend
/// router — so the available local models can't drift between them.
///
/// Only models whose backend is actually implemented + whose weights the pinned
/// packages ship are listed (e.g. Distil-Medium/Small aren't in WhisperKit 0.9,
/// so they're absent rather than dead rows). `streamingOnly` models (Parakeet
/// EOU) are surfaced but have no one-shot batch backend yet.
public struct ASRModelEntry: Sendable, Hashable, Identifiable {
    /// Which backend runs this model + the variant/version it loads.
    public enum Engine: Sendable, Hashable {
        case parakeet(versionID: String)  // ParakeetBackend.KnownVersion.id
        case qwen3(int8: Bool)  // FluidAudio f32 vs int8
        case whisperKit(model: String)  // WhisperKit model name
        case appleSpeech  // system, no download
    }

    public let id: String
    public let displayName: String
    /// Brand slug for the logo (the UI maps it to its BrandLogo): apple, openai,
    /// nvidia, qwen.
    public let brand: String
    public let blurb: String
    public let accuracy: Double  // 1–5
    public let speed: Double  // 1–5
    public let approxSizeMB: Int  // 0 = system model, no download
    public let languages: String
    public let engine: Engine
    /// True for models with no one-shot `transcribe` path yet (Parakeet EOU).
    public let streamingOnly: Bool

    public init(
        id: String, displayName: String, brand: String, blurb: String,
        accuracy: Double, speed: Double, approxSizeMB: Int, languages: String,
        engine: Engine, streamingOnly: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.brand = brand
        self.blurb = blurb
        self.accuracy = accuracy
        self.speed = speed
        self.approxSizeMB = approxSizeMB
        self.languages = languages
        self.engine = engine
        self.streamingOnly = streamingOnly
    }

    /// Construct the (un-prepared) backend for this model, or nil if it has no
    /// one-shot backend yet (streaming-only).
    public func makeBackend() -> (any TranscriptionBackend)? {
        switch engine {
        case .parakeet(let versionID):
            return ParakeetBackend.knownVersion(id: versionID)?.makeBackend()
        case .qwen3(let int8):
            return Qwen3Backend(variant: int8 ? .int8 : .f32)
        case .whisperKit(let model):
            return WhisperKitBackend(variant: model)
        case .appleSpeech:
            return AppleSpeechBackend()
        }
    }
}

public enum ASRModelCatalog {
    /// The full local catalog, ordered the way the Settings list shows it
    /// (fastest/most-recommended first).
    public static let all: [ASRModelEntry] = [
        ASRModelEntry(
            id: "parakeet-tdt-v3", displayName: "NVIDIA Parakeet TDT 0.6B v3", brand: "nvidia",
            blurb: "Ultra-fast NVIDIA FastConformer for conversational speech and voice commands.",
            accuracy: 4.5, speed: 4.5, approxSizeMB: 496, languages: "Multilingual",
            engine: .parakeet(versionID: "tdt-v3")
        ),
        ASRModelEntry(
            id: "parakeet-tdt-v2", displayName: "NVIDIA Parakeet TDT 0.6B v2", brand: "nvidia",
            blurb: "Ultra-fast English-only transcription on NVIDIA FastConformer v2.",
            accuracy: 4.5, speed: 4.5, approxSizeMB: 496, languages: "English",
            engine: .parakeet(versionID: "tdt-v2")
        ),
        ASRModelEntry(
            id: "apple-speech", displayName: "Apple Speech Analyzer", brand: "apple",
            blurb: "Next-generation on-device speech recognition. Requires macOS 26+.",
            accuracy: 4.0, speed: 5.0, approxSizeMB: 0, languages: "Real-time",
            engine: .appleSpeech
        ),
        ASRModelEntry(
            id: "qwen3-asr-0.6b", displayName: "Qwen3-ASR 0.6B", brand: "qwen",
            blurb: "Qwen3-ASR multilingual transcription, 30+ languages with excellent accuracy.",
            accuracy: 4.5, speed: 3.5, approxSizeMB: 1750, languages: "Multilingual",
            engine: .qwen3(int8: false)
        ),
        ASRModelEntry(
            id: "qwen3-asr-0.6b-int8", displayName: "Qwen3-ASR 0.6B Int8", brand: "qwen",
            blurb: "Compact Qwen3-ASR Int8 with 30+ languages and a smaller model size.",
            accuracy: 4.0, speed: 3.0, approxSizeMB: 900, languages: "Multilingual",
            engine: .qwen3(int8: true)
        ),
        ASRModelEntry(
            id: "parakeet-eou-120m", displayName: "NVIDIA Parakeet EOU 120M", brand: "nvidia",
            blurb: "Real-time streaming with end-of-utterance detection and ~320 ms updates.",
            accuracy: 3.5, speed: 5.0, approxSizeMB: 85, languages: "English",
            engine: .parakeet(versionID: "eou-120m"), streamingOnly: true
        ),
        ASRModelEntry(
            id: "whisper-large-v3-turbo", displayName: "Whisper Large V3 Turbo", brand: "openai",
            blurb: "Argmax CoreML port of Whisper Large v3 Turbo — 90+ languages incl. Mandarin.",
            // Derive the variant from the ONE source of truth (WhisperKitBackend's
            // default), never a hard-coded copy — so this catalog row, the coarse
            // `.whisperKit` engine default, the downloader, and the on-disk detector
            // all use the identical string and can't drift. On any fresh machine,
            // downloading this row fetches exactly the variant the default engine
            // loads, and checkStatus then recognizes it. (Previously this row and
            // `defaultVariant` were two hand-kept copies that silently diverged.)
            accuracy: 4.5, speed: 3.5, approxSizeMB: 626, languages: "Multilingual",
            engine: .whisperKit(model: WhisperKitBackend.defaultVariant)
        ),
        ASRModelEntry(
            id: "whisper-large-v3", displayName: "Whisper Large V3", brand: "openai",
            blurb: "Maximum offline accuracy. Slow and resource-intensive on complex speech.",
            accuracy: 4.5, speed: 2.5, approxSizeMB: 2900, languages: "Multilingual",
            engine: .whisperKit(model: "openai_whisper-large-v3")
        ),
        ASRModelEntry(
            id: "whisper-large-v2", displayName: "Whisper Large V2", brand: "openai",
            blurb: "High offline accuracy. Slow and resource-intensive but captures details well.",
            accuracy: 4.0, speed: 2.5, approxSizeMB: 2900, languages: "Multilingual",
            engine: .whisperKit(model: "openai_whisper-large-v2")
        ),
        ASRModelEntry(
            id: "distil-whisper-large-v3", displayName: "Distil-Whisper Large V3 (English)", brand: "openai",
            blurb: "~1.5× faster than Whisper Large v3 Turbo. English only.",
            accuracy: 4.0, speed: 3.5, approxSizeMB: 1500, languages: "English",
            engine: .whisperKit(model: "distil-whisper_distil-large-v3")
        ),
        ASRModelEntry(
            id: "whisper-small", displayName: "Whisper Small", brand: "openai",
            blurb: "Balanced on-device dictation model for everyday use.",
            accuracy: 3.0, speed: 4.0, approxSizeMB: 244, languages: "Multilingual",
            engine: .whisperKit(model: "openai_whisper-small")
        ),
        ASRModelEntry(
            id: "whisper-base", displayName: "Whisper Base", brand: "openai",
            blurb: "Quick offline model for memos and everyday dictation.",
            accuracy: 2.0, speed: 4.5, approxSizeMB: 466, languages: "Multilingual",
            engine: .whisperKit(model: "openai_whisper-base")
        ),
        ASRModelEntry(
            id: "whisper-tiny", displayName: "Whisper Tiny", brand: "openai",
            blurb: "Tiniest multilingual model for instant voice notes. Limited on complex speech.",
            accuracy: 1.0, speed: 5.0, approxSizeMB: 75, languages: "Multilingual",
            engine: .whisperKit(model: "openai_whisper-tiny")
        ),
    ]

    /// Catalog entry for an id, or nil.
    public static func entry(id: String) -> ASRModelEntry? {
        all.first { $0.id == id }
    }
}
