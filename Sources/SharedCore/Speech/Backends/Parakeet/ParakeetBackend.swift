@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// One-shot (batch) Parakeet TDT backend backed by FluidAudio's `AsrManager`.
///
/// FluidAudio ships several Parakeet model versions under one `AsrModelVersion`
/// enum. This backend is generalized over that enum so it can load any of the
/// batch TDT models instead of always pulling the v3 default:
///
///   - `.v3`  — Parakeet TDT 0.6B v3, **multilingual** (25 European langs).
///   - `.v2`  — Parakeet TDT 0.6B v2, **English-only**.
///   - `.tdtJa` — Parakeet TDT 0.6B, **Japanese** (hybrid CTC frontend + TDT decoder).
///
/// The streaming "EOU 120M" end-of-utterance model is intentionally NOT one of
/// these: it is a different FluidAudio pipeline (`StreamingEouAsrManager`, keyed
/// by `StreamingChunkSize` rather than `AsrModelVersion`) and has no one-shot
/// `transcribe`. See `KnownVersion.eou120m` and the note on `transcribe` below.
public actor ParakeetBackend: TranscriptionBackend {
    public nonisolated let displayName: String

    /// Which FluidAudio TDT model this instance loads.
    private let version: AsrModelVersion

    private var status: BackendStatus = .ready
    private var manager: AsrManager?
    private var decoderState: TdtDecoderState?

    /// - Parameter version: FluidAudio TDT model version to load. Defaults to
    ///   `.v3` (multilingual Parakeet TDT 0.6B v3) — the FluidAudio default.
    ///   `.v2` is the English-only TDT; `.tdtJa` is the Japanese TDT.
    ///   CTC-only / fused-encoder versions (`.ctcZhCn`, `.tdtCtc110m`) are not
    ///   supported here — FluidAudio routes those through dedicated managers.
    public init(version: AsrModelVersion = .v3) {
        self.version = version
        self.displayName = Self.displayName(for: version)
    }

    public func checkStatus() async -> BackendStatus { status }

    public func prepare(
        onStatus: @escaping @Sendable (BackendStatus) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Readiness is tracked per loaded version: a populated `manager` always
        // corresponds to `self.version`, so a non-nil manager means this exact
        // version is already loaded and ready.
        if manager != nil {
            status = .loaded
            onStatus(.loaded)
            onProgress(1)
            return
        }
        status = .downloading(progress: 0)
        onStatus(.downloading(progress: 0))
        onProgress(0)
        // Reuse a process-wide WARM manager for this version when one already
        // exists (e.g. dictation already loaded it) instead of cold-loading a
        // second ~0.5 GB copy. The duplicate load is what intermittently failed
        // and used to silently downgrade meetings to Apple Speech. Download + load
        // THIS version (not FluidAudio's default): `version` is threaded into both
        // the download and the load so the cache directory, repo, and required
        // model set all resolve to the requested model.
        let version = self.version
        let asrManager = try await ParakeetManagerCache.shared.manager(
            forKey: String(describing: version)
        ) {
            let models = try await AsrModels.downloadAndLoad(
                version: version,
                progressHandler: { progress in
                    let fraction = progress.fractionCompleted
                    onProgress(fraction)
                    onStatus(.downloading(progress: fraction))
                }
            )
            let manager = AsrManager()
            try await manager.loadModels(models)
            return manager
        }
        self.manager = asrManager
        status = .loaded
        onStatus(.loaded)
        onProgress(1)
    }

    public func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
        guard let manager else {
            throw TraceError.asrInferenceFailed(
                engine: "parakeet",
                reason: "ParakeetBackend not prepared — call prepare() before transcribe()"
            )
        }
        var localState: TdtDecoderState
        if let existing = decoderState {
            localState = existing
        } else {
            localState = try TdtDecoderState()
        }
        // `language: nil` works for every TDT version: the language hint only
        // drives v3's script-aware token filtering and is silently ignored by
        // v2 / tdtJa. v3 still auto-detects language without the hint.
        let result = try await manager.transcribe(samples, decoderState: &localState, language: nil)
        decoderState = localState
        return result.text
    }

    public func transcribeStream(_ buffer: AVAudioPCMBuffer) async throws -> ASRDelta? {
        // EOU 120M streaming is a separate FluidAudio pipeline and is not wired
        // into this batch backend. See `KnownVersion.eou120m`.
        nil
    }

    public func clearModelCache() async {
        manager = nil
        decoderState = nil
        status = .ready
    }

    // MARK: - Known versions (catalog)

    /// A stable, catalog-facing descriptor for a selectable Parakeet model.
    ///
    /// `id` is a stable string the catalog/settings can persist (it never
    /// changes even if FluidAudio renames an enum case). `fluidVersion` is the
    /// FluidAudio `AsrModelVersion` to construct the backend with — or `nil`
    /// for EOU 120M, which is streaming-only and has no `AsrModelVersion`.
    public struct KnownVersion: Sendable, Identifiable, Hashable {
        public let id: String
        public let displayName: String
        /// FluidAudio enum case to pass to `ParakeetBackend(version:)`.
        /// `nil` ⇒ not constructible via this batch backend (EOU 120M).
        public let fluidVersion: AsrModelVersion?
        /// Approximate parameter count / on-disk footprint, human-readable.
        public let approxSize: String
        /// Languages covered, human-readable.
        public let languages: String
        /// Whether this model is streaming-only (no one-shot `transcribe`).
        public let isStreamingOnly: Bool

        /// Build a one-shot backend for this version.
        ///
        /// Returns `nil` for
        /// streaming-only entries (EOU 120M) that this backend can't run.
        public func makeBackend() -> ParakeetBackend? {
            guard let fluidVersion else { return nil }
            return ParakeetBackend(version: fluidVersion)
        }
    }

    /// Multilingual TDT 0.6B v3 — FluidAudio's default.
    ///
    /// 25 European languages.
    public static let tdtV3 = KnownVersion(
        id: "tdt-v3",
        displayName: "Parakeet TDT v3 (multilingual)",
        fluidVersion: .v3,
        approxSize: "0.6B",
        languages: "25 European languages",
        isStreamingOnly: false
    )

    /// English-only TDT 0.6B v2.
    public static let tdtV2 = KnownVersion(
        id: "tdt-v2",
        displayName: "Parakeet TDT v2 (English)",
        fluidVersion: .v2,
        approxSize: "0.6B",
        languages: "English",
        isStreamingOnly: false
    )

    /// Streaming end-of-utterance model.
    ///
    /// Streaming-only — runs through
    /// FluidAudio's `StreamingEouAsrManager`, NOT this batch backend, so its
    /// `fluidVersion` is `nil` and `makeBackend()` returns `nil`.
    public static let eou120m = KnownVersion(
        id: "eou-120m",
        displayName: "Parakeet EOU 120M (streaming)",
        fluidVersion: nil,
        approxSize: "120M",
        languages: "English (streaming)",
        isStreamingOnly: true
    )

    /// Catalog of selectable Parakeet models keyed by stable `id`.
    ///
    /// Order is the recommended display order (default first).
    public static let knownVersions: [KnownVersion] = [tdtV3, tdtV2, eou120m]

    /// Look up a known version by its stable `id` (e.g. persisted setting).
    public static func knownVersion(id: String) -> KnownVersion? {
        knownVersions.first { $0.id == id }
    }

    private static func displayName(for version: AsrModelVersion) -> String {
        switch version {
        case .v3: return "Parakeet TDT v3 (FluidAudio)"
        case .v2: return "Parakeet TDT v2 (FluidAudio)"
        case .tdtJa: return "Parakeet TDT JA (FluidAudio)"
        case .tdtCtc110m: return "Parakeet TDT-CTC 110M (FluidAudio)"
        case .ctcZhCn: return "Parakeet CTC zh-CN (FluidAudio)"
        @unknown default: return "Parakeet (FluidAudio)"
        }
    }
}

/// Process-wide cache of loaded FluidAudio Parakeet `AsrManager`s, keyed by model
/// version. The CoreML models are ~0.5 GB and slow to load, and `AsrManager` is a
/// FluidAudio actor (safe to share across callers — each `ParakeetBackend` keeps
/// its own `TdtDecoderState`, so streams don't collide). Dictation and meeting
/// capture therefore reuse ONE warm manager per version instead of each
/// cold-loading a duplicate — the duplicate load is what intermittently failed and
/// used to silently downgrade a meeting to Apple Speech. A single in-flight load is
/// coalesced so concurrent callers await the same task rather than racing two
/// downloads.
private actor ParakeetManagerCache {
    static let shared = ParakeetManagerCache()
    private var managers: [String: AsrManager] = [:]
    private var inflight: [String: Task<AsrManager, Error>] = [:]

    func manager(
        forKey key: String,
        load: @Sendable @escaping () async throws -> AsrManager
    ) async throws -> AsrManager {
        if let existing = managers[key] { return existing }
        if let task = inflight[key] { return try await task.value }
        let task = Task { try await load() }
        inflight[key] = task
        defer { inflight[key] = nil }
        let manager = try await task.value
        managers[key] = manager
        return manager
    }
}
