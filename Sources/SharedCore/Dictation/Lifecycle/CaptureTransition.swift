import Foundation

/// Pure transition table for `CaptureState`.
///
/// Direct transitions follow the linear arc; every non-terminal state can also
/// transition to `cancelled` or `failed(_:)`. Anything else is rejected as a
/// `TraceError.configInvalid` from the state machine.
public enum CaptureTransition {
    /// Returns true iff transitioning `from → to` is permitted by the spec.
    public static func isPermitted(from: CaptureState, to: CaptureState) -> Bool {
        // Universal escape hatches from any active state.
        if case .cancelled = to, !from.isTerminal { return true }
        if case .failed = to, !from.isTerminal { return true }

        switch (from, to) {
        case (.idle, .arming): return true
        case (.arming, .recording): return true
        case (.recording, .finalizing): return true
        case (.finalizing, .cleaning): return true
        case (.cleaning, .pasting): return true
        case (.pasting, .done): return true
        // Reset after terminal state begins a new cycle.
        case (.done, .idle), (.cancelled, .idle), (.failed, .idle): return true
        default: return false
        }
    }
}
