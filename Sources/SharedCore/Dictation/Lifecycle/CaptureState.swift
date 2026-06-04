import Foundation

/// Discrete states of a single dictation capture cycle.
///
/// The state machine flows linearly: `idle → arming → recording → finalizing →
/// cleaning → pasting → done`. The `cancelled` and `failed` terminals can be
/// entered from any non-terminal state.
public enum CaptureState: Sendable, Hashable, Codable {
    /// No capture in progress. Default state at boot and after `done`/`cancelled`/`failed`.
    case idle
    /// Hotkey down received; permissions checked; mode resolved; audio chain warming.
    case arming
    /// Audio capture active; ASR streaming.
    case recording
    /// Capture ended; flushing final ASR delta and awaiting full transcript.
    case finalizing
    /// Raw ASR text passed through the personal dictionary; awaiting LLM cleanup.
    case cleaning
    /// Cleaned text dispatched to the Accessibility paste actor.
    case pasting
    /// Successful insert. Persisted to history. Terminal.
    case done
    /// User cancelled (hotkey released too early, escape, etc.). Terminal.
    case cancelled
    /// Pipeline failed. Carries a category for the UI to render. Terminal.
    case failed(reason: FailureReason)

    /// Concrete failure categories the pipeline distinguishes.
    public enum FailureReason: String, Sendable, Hashable, Codable {
        case permissionMissing
        case audioCaptureFailed
        case asrFailed
        case cleanupFailed
        case pasteFailed
        case storageFailed
        case unexpected
    }

    /// True when no further transitions are valid for the cycle.
    public var isTerminal: Bool {
        switch self {
        case .done, .cancelled, .failed: return true
        case .idle, .arming, .recording, .finalizing, .cleaning, .pasting: return false
        }
    }
}
