import Foundation

@testable import SharedCore

actor ScriptedModelRouter: ModelRoutingFacade {
    private var scripted: [LLMDelta]
    private var failure: TraceError?
    /// When set, `projectRoute(forLLM:projectID:)` returns this for any non-nil
    /// projectID — lets a test assert MergeEngine applies the per-project route.
    private let projectRouteOverride: LLMRoute?
    var lastRequest: LLMRequest?
    var lastRouteOverride: LLMRoute?

    init(scripted: [LLMDelta], failure: TraceError? = nil, projectRouteOverride: LLMRoute? = nil) {
        self.scripted = scripted
        self.failure = failure
        self.projectRouteOverride = projectRouteOverride
    }

    func projectRoute(forLLM task: LLMTaskClass, projectID: UUID?) async -> LLMRoute? {
        projectID == nil ? nil : projectRouteOverride
    }

    func capture(request: LLMRequest, routeOverride: LLMRoute?) {
        self.lastRequest = request
        self.lastRouteOverride = routeOverride
    }

    nonisolated func stream(
        _ request: LLMRequest, routeOverride: LLMRoute?
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.capture(request: request, routeOverride: routeOverride)
                let snapshot = await self.snapshot()
                if let failure = snapshot.failure {
                    continuation.finish(throwing: failure)
                    return
                }
                for delta in snapshot.scripted {
                    continuation.yield(delta)
                }
                continuation.finish()
            }
        }
    }

    private func snapshot() -> (scripted: [LLMDelta], failure: TraceError?) {
        (scripted, failure)
    }
}
