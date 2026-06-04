@preconcurrency import AVFoundation
import Foundation

/// Bag of dependencies a `DictationController` needs to run a capture cycle.
///
/// Production wires the live components (`AudioPipeline`, `ASRRouter` /
/// streaming backend, `ModelRouter`, `AccessibilityPaste`, `FrontmostAppMonitor`).
/// Tests provide scripted doubles via `ScriptedPipelineDeps` so the whole flow
/// can be exercised without audio hardware.
public protocol PipelineDependencies: Sendable {
    var modeRegistry: ModeRegistry { get }
    var modeResolver: ModeResolver { get }
    var personalDictionary: PersonalDictionary { get }
    var historyStore: DictationHistoryStore? { get }

    var audio: PipelineAudioSource { get }
    var asr: PipelineASR { get }
    var cleanup: PipelineCleanup { get }
    var paste: PipelinePaste { get }

    /// Returns a wall-clock seconds value. Provided so tests can freeze time.
    func now() -> TimeInterval
}

/// Mic-capture facade narrowed to what the controller actually needs.
public protocol PipelineAudioSource: Sendable {
    func startCapture() async throws
    func stopCapture() async
    /// AsyncStream of buffers in the canonical 16 kHz mono Float32 format.
    nonisolated func buffers() -> AsyncStream<AVAudioPCMBuffer>
}

/// Streaming ASR contract.
///
/// The implementation owns its audio subscription: `beginCycle()` is expected
/// to attach to the same mic stream the controller started, accumulate
/// `ASRDelta`s, and finalize on `finishCycle()`. The controller doesn't pump
/// buffers itself because doing so would force `AVAudioPCMBuffer` (non-Sendable
/// under strict concurrency) through actor boundaries on the hot path.
public protocol PipelineASR: Sendable {
    func beginCycle() async throws
    /// Flushes the streaming state and returns the assembled text. After this
    /// call, the backend is expected to be idle and ready for the next cycle.
    func finishCycle() async throws -> String
}

/// LLM cleanup contract.
///
/// The controller hands raw + mode + the LLM route
/// override and gets back the cleaned text.
public protocol PipelineCleanup: Sendable {
    func clean(rawText: String, systemPrompt: String, routeOverride: LLMRoute?) async throws -> String
}

/// Paste-back contract.
///
/// Returns the concrete strategy that landed (AX,
/// clipboard, copy-only) so the controller can log it.
public protocol PipelinePaste: Sendable {
    func insert(_ text: String, behavior: InsertBehavior) async throws -> PasteResult
}

/// Outcome of a single capture cycle.
public struct PipelineResult: Sendable, Hashable, Codable {
    public let id: String
    public let modeName: String
    public let bundleID: String?
    public let rawText: String
    public let cleanedText: String
    public let pasted: Bool
    public let pasteStrategy: PasteResult?
    public let durationMs: Int
    public let startedAt: TimeInterval

    public init(
        id: String,
        modeName: String,
        bundleID: String?,
        rawText: String,
        cleanedText: String,
        pasted: Bool,
        pasteStrategy: PasteResult?,
        durationMs: Int,
        startedAt: TimeInterval
    ) {
        self.id = id
        self.modeName = modeName
        self.bundleID = bundleID
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.pasted = pasted
        self.pasteStrategy = pasteStrategy
        self.durationMs = durationMs
        self.startedAt = startedAt
    }
}
