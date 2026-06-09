import Foundation

/// Actor-isolated owner of the current `CaptureState`.
///
/// Mediates every transition through `CaptureTransition.isPermitted(from:to:)`.
/// Rejected transitions throw `TraceError.configInvalid` so callers see a
/// loud failure instead of silently corrupting the lifecycle.
public actor CaptureStateMachine {
    public private(set) var state: CaptureState
    private var observers: [@Sendable (CaptureState) -> Void] = []
    /// Continuations suspended in `waitForQuiescence(timeout:)`, resumed when
    /// the machine settles (terminal or idle).
    private var quiescenceWaiters: [UUID: CheckedContinuation<CaptureState?, Never>] = [:]

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
        if next.isTerminal || next == .idle {
            let waiters = quiescenceWaiters
            quiescenceWaiters.removeAll()
            for (_, waiter) in waiters {
                waiter.resume(returning: next)
            }
        }
    }

    /// Suspends until the machine settles — reaches a terminal state or `idle`
    /// — and returns that state, or returns immediately if already settled.
    /// Returns `nil` when `timeout` elapses first.
    ///
    /// Event-driven (no polling): `transition(to:)` resumes the waiters the
    /// instant the cycle completes, which is what lets a queued `startCapture`
    /// chain onto the previous cycle's tail with zero added latency.
    public func waitForQuiescence(timeout: Duration) async -> CaptureState? {
        if state.isTerminal || state == .idle { return state }
        let id = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireWaiter(id: id)
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { continuation in
            quiescenceWaiters[id] = continuation
        }
    }

    private func expireWaiter(id: UUID) {
        if let waiter = quiescenceWaiters.removeValue(forKey: id) {
            waiter.resume(returning: nil)
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
