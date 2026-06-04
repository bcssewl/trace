import Foundation

/// Actor-isolated owner of the current `CaptureState`.
///
/// Mediates every transition through `CaptureTransition.isPermitted(from:to:)`.
/// Rejected transitions throw `TraceError.configInvalid` so callers see a
/// loud failure instead of silently corrupting the lifecycle.
public actor CaptureStateMachine {
    public private(set) var state: CaptureState
    private var observers: [@Sendable (CaptureState) -> Void] = []

    public init(initial: CaptureState = .idle) {
        self.state = initial
    }

    /// Advances to `next` if the transition is permitted; throws otherwise.
    public func transition(to next: CaptureState) throws {
        guard CaptureTransition.isPermitted(from: state, to: next) else {
            throw TraceError.configInvalid(
                field: "CaptureStateMachine",
                reason: "illegal transition: \(state) -> \(next)"
            )
        }
        let previous = state
        state = next
        Loggers.dictation.debug(
            "CaptureState \(String(describing: previous), privacy: .public) -> \(String(describing: next), privacy: .public)"
        )
        for observer in observers {
            observer(next)
        }
    }

    /// Registers an observer invoked on every transition (including the
    /// terminal ones).
    ///
    /// Observers run inside the actor — they must finish
    /// quickly or dispatch their own `Task`.
    public func addObserver(_ observer: @escaping @Sendable (CaptureState) -> Void) {
        observers.append(observer)
    }

    public func resetToIdle() throws {
        guard state.isTerminal else { return }
        try transition(to: .idle)
    }
}
