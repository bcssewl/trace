@preconcurrency import AVFoundation
import Foundation

#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

/// On-device Whisper (multilingual, incl. Mandarin) via WhisperKit (BAS-74).
///
/// Mirrors `ParakeetBackend`'s lazy "download + load on first prepare" pattern:
/// the chosen CoreML model is fetched from Hugging Face on first use, cached,
/// then reused for every transcription. Unlike Parakeet (English/European),
/// Whisper covers 90+ languages, so it honours the requested `locale`.
///
/// Generalised (BAS-74 follow-up): a single backend instance is bound to ONE
/// WhisperKit model variant — Tiny / Base / Small / Large V2 / V3 /
/// V3-Turbo / Distil-Large-V3, or a user-supplied fine-tuned model folder.
/// Pick the variant at construction time; download/load/status all key off it,
/// so multiple variants coexist on disk and track readiness independently.
public actor WhisperKitBackend: TranscriptionBackend {
    public nonisolated let displayName = "WhisperKit"

    // MARK: - Variant catalogue

    /// Default variant: multilingual large-v3 turbo-class (~626 MB) — strong
    /// Mandarin + 90+ languages, fast enough for on-device meeting capture.
    ///
    /// This is the bare WhisperKit "variant" string (without the `openai_` repo
    /// prefix); `WhisperKit.download(variant:)` resolves it by glob-matching the
    /// suffix, and `WhisperKitConfig(model:)` accepts the same form. Kept exactly
    /// as the previous hard-coded value so existing installs don't re-download.
    public static let defaultVariant = "large-v3-v20240930_626MB"

    /// Known WhisperKit model variants, paired with a stable UI id.
    ///
    /// `whisperKitModel` values are the *canonical, fully-qualified* names from
    /// the `argmaxinc/whisperkit-coreml` repo as listed in WhisperKit 0.9.0's
    /// `Constants.fallbackModelSupportConfig`
    /// (`.build/checkouts/WhisperKit/Sources/WhisperKit/Core/Models.swift`,
    /// lines ~1567–1739). They feed straight into `WhisperKit.download(variant:)`
    /// and `WhisperKitConfig(model:)`.
    ///
    /// Note on Distil-Whisper: WhisperKit 0.9.0's bundled config only ships
    /// `distil-whisper_distil-large-v3` (and its `_turbo` form). There is NO
    /// Distil-Whisper "V3.5", "Medium", or "Small" variant in the pinned
    /// package — those names are not present anywhere in the vendored source, so
    /// they are deliberately omitted rather than invented. If Argmax publishes
    /// them later, `fetchAvailableVariants()` (below) will surface them live from
    /// the HF repo's `config.json` without a code change.
    public static let knownVariants: [(id: String, whisperKitModel: String)] = [
        // OpenAI Whisper — multilingual + English-only
        ("tiny", "openai_whisper-tiny"),
        ("tiny.en", "openai_whisper-tiny.en"),
        ("base", "openai_whisper-base"),
        ("base.en", "openai_whisper-base.en"),
        ("small", "openai_whisper-small"),
        ("small.en", "openai_whisper-small.en"),
        ("large-v2", "openai_whisper-large-v2"),
        ("large-v2-turbo", "openai_whisper-large-v2_turbo"),
        ("large-v3", "openai_whisper-large-v3"),
        ("large-v3-turbo", "openai_whisper-large-v3_turbo"),
        // large-v3 fine-tune snapshot (2024-09-30) — the default below maps here.
        ("large-v3-626", "openai_whisper-large-v3-v20240930_626MB"),
        ("large-v3-turbo-632", "openai_whisper-large-v3-v20240930_turbo_632MB"),
        // Distil-Whisper Large V3 (the only distilled family in WhisperKit 0.9.0)
        ("distil-large-v3", "distil-whisper_distil-large-v3"),
        ("distil-large-v3-turbo", "distil-whisper_distil-large-v3_turbo"),
    ]

    // MARK: - Instance configuration

    /// The WhisperKit variant string this instance downloads + loads, e.g.
    /// `"large-v3-v20240930_626MB"` or `"openai_whisper-tiny"`.
    ///
    /// Ignored when
    /// `customModelFolder` is set.
    public nonisolated let variant: String

    /// When non-nil, load a user-supplied model directly from this local folder
    /// (a directory containing the `.mlmodelc` files) instead of downloading.
    ///
    /// Wired through `WhisperKitConfig.modelFolder`.
    public nonisolated let customModelFolder: URL?

    /// Construct a backend for a specific WhisperKit variant.
    ///
    /// Pass any `knownVariants[].whisperKitModel`, or any other valid
    /// `argmaxinc/whisperkit-coreml` variant string.
    public init(variant: String = WhisperKitBackend.defaultVariant) {
        self.variant = variant
        self.customModelFolder = nil
    }

    /// Construct a backend that loads a custom / fine-tuned model from a local
    /// folder (e.g. an exported `.mlmodelc` directory).
    ///
    /// No download occurs.
    public init(customModelFolder: URL) {
        self.variant = customModelFolder.lastPathComponent
        self.customModelFolder = customModelFolder
    }

    /// UserDefaults key tracking whether *this variant* has been downloaded,
    /// suffixed by the variant so each model tracks independently.
    ///
    /// The legacy
    /// unsuffixed key (`app.trace.whisperkit.downloaded`) is intentionally not
    /// reused; the on-disk probe below covers already-downloaded installs.
    private nonisolated var downloadedKey: String {
        "app.trace.whisperkit.downloaded.\(variant)"
    }

    #if canImport(WhisperKit)
    private var pipe: WhisperKit?

    public func checkStatus() async -> BackendStatus {
        if pipe != nil { return .loaded }
        // A custom folder is "ready" iff the folder exists on disk.
        if let customModelFolder {
            return FileManager.default.fileExists(atPath: customModelFolder.path) ? .ready : .notDownloaded
        }
        // Ready if either the per-variant flag is set OR the model is already on
        // disk in the default Hugging Face cache (robust against the readiness
        // probe building a fresh backend that never saw the download succeed).
        if UserDefaults.standard.bool(forKey: downloadedKey) || Self.isVariantCachedOnDisk(variant) {
            return .ready
        }
        return .notDownloaded
    }

    public func prepare(
        onStatus: @escaping @Sendable (BackendStatus) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if pipe != nil {
            onStatus(.loaded)
            onProgress(1)
            return
        }

        let folderPath: String

        if let customModelFolder {
            // Custom / fine-tuned model: no download, load straight from disk.
            guard FileManager.default.fileExists(atPath: customModelFolder.path) else {
                throw TraceError.configInvalid(
                    field: "whisperkit.customModelFolder",
                    reason: "No model folder at \(customModelFolder.path)"
                )
            }
            folderPath = customModelFolder.path
            onStatus(.downloading(progress: 1))
            onProgress(1)
        } else {
            onStatus(.downloading(progress: 0))
            onProgress(0)
            // Fetch the CoreML model (no-op if already cached) with real progress.
            let folder = try await WhisperKit.download(
                variant: variant,
                progressCallback: { progress in
                    let fraction = max(0, min(1, progress.fractionCompleted))
                    onProgress(fraction)
                    onStatus(.downloading(progress: fraction))
                }
            )
            folderPath = folder.path
        }

        // Load + prewarm (compiles the CoreML graph so the first utterance isn't slow).
        // Passing `modelFolder` makes WhisperKit load from this exact directory and
        // skips any remote lookup; `model` stays informative for logging.
        let config = WhisperKitConfig(
            model: customModelFolder == nil ? variant : nil,
            modelFolder: folderPath,
            prewarm: true,
            load: true,
            download: false
        )
        self.pipe = try await WhisperKit(config)
        if customModelFolder == nil {
            UserDefaults.standard.set(true, forKey: downloadedKey)
        }
        onStatus(.loaded)
        onProgress(1)
    }

    public func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
        guard let pipe else {
            throw TraceError.asrInferenceFailed(
                engine: "whisperkit",
                reason: "WhisperKitBackend not prepared — call prepare() before transcribe()"
            )
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: Self.whisperLanguageCode(for: locale)
        )
        // Two `transcribe(audioArray:)` overloads exist; annotate the array form.
        let results: [TranscriptionResult] = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper's language code for a locale, or `nil` to auto-detect — our
    /// `.autoDetect` ("und") sentinel, or a locale with no language code.
    private static func whisperLanguageCode(for locale: Locale) -> String? {
        if locale.isAutoDetect { return nil }
        return locale.language.languageCode?.identifier
    }

    public func clearModelCache() async {
        pipe = nil
        if customModelFolder == nil {
            UserDefaults.standard.set(false, forKey: downloadedKey)
        }
    }

    // MARK: - Live variant discovery

    /// Models available right now from the WhisperKit model repo for this device
    /// (fetched from `argmaxinc/whisperkit-coreml`'s `config.json`). Use this to
    /// surface variants beyond `knownVariants` (e.g. newer distilled models) in
    /// settings UI. Falls back to the bundled config offline.
    public static func fetchAvailableVariants() async -> [String] {
        (try? await WhisperKit.fetchAvailableModels()) ?? recommendedVariants()
    }

    /// The variants Argmax recommends for this specific device, from the bundled
    /// (offline) support table.
    public static func recommendedVariants() -> [String] {
        WhisperKit.recommendedModels().supported
    }

    /// Whether `variant` already exists in the default Hugging Face cache
    /// (`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<variant>`).
    ///
    /// WhisperKit's `download(variant:)` glob-matches the suffix, so a folder
    /// whose name *ends with* the variant counts as present.
    private static func isVariantCachedOnDisk(_ variant: String) -> Bool {
        guard let repoDir = whisperKitRepoCacheDir() else { return false }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: repoDir.path) else {
            return false
        }
        // `download(variant:)` glob-matches `*<variant>/*`, so a cached folder
        // whose name equals or ends with the variant string counts as present.
        return entries.contains { $0 == variant || $0.hasSuffix(variant) }
    }

    /// `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml` — the
    /// `HubApi` default `downloadBase` (`Documents/huggingface`) joined with the
    /// repo path used by `WhisperKit.download`.
    private static func whisperKitRepoCacheDir() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return
            documents
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }
    #else
    public func checkStatus() async -> BackendStatus {
        .unavailable(reason: "WhisperKit dependency not linked; add to Package.swift to enable")
    }

    public func prepare(
        onStatus: @escaping @Sendable (BackendStatus) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        throw TraceError.configInvalid(field: "whisperkit", reason: "WhisperKit not linked")
    }

    public func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
        throw TraceError.configInvalid(field: "whisperkit", reason: "WhisperKit not linked")
    }

    public func clearModelCache() async {}

    public static func fetchAvailableVariants() async -> [String] {
        knownVariants.map(\.whisperKitModel)
    }

    public static func recommendedVariants() -> [String] {
        knownVariants.map(\.whisperKitModel)
    }
    #endif

    public func transcribeStream(_ buffer: AVAudioPCMBuffer) async throws -> ASRDelta? {
        nil
    }
}
