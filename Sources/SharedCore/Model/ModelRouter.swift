import Foundation
import os

public actor ModelRouter {
    private var llmRoutes: [LLMTaskClass: LLMRoute]
    private var embeddingRoutes: [EmbeddingTaskClass: EmbeddingRoute]
    private var llmProviders: [LLMProviderKind: any LLMProvider] = [:]
    private var embeddingProviders: [EmbeddingProviderKind: any EmbeddingProvider] = [:]
    /// Per-project LLM route overrides (BAS-23). A project's route for a task
    /// wins over the global preset; mirrors `ASRRouter`'s project overrides.
    private var projectLLMOverrides: [UUID: [LLMTaskClass: LLMRoute]] = [:]

    public init(
        llmRoutes: [LLMTaskClass: LLMRoute] = ModelRouter.defaultLLMRoutes,
        embeddingRoutes: [EmbeddingTaskClass: EmbeddingRoute] = ModelRouter.defaultEmbeddingRoutes
    ) {
        self.llmRoutes = llmRoutes
        self.embeddingRoutes = embeddingRoutes
    }

    public func route(forLLM task: LLMTaskClass) throws -> LLMRoute {
        guard let route = llmRoutes[task] else {
            throw TraceError.modelRouteUnresolved(taskClass: task.rawValue)
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled && route.provider != .appleFM {
            Loggers.model.info("Low-power mode biasing \(task.rawValue, privacy: .public) toward Apple FM")
        }
        return route
    }

    public func route(forEmbedding task: EmbeddingTaskClass) throws -> EmbeddingRoute {
        guard let route = embeddingRoutes[task] else {
            throw TraceError.modelRouteUnresolved(taskClass: task.rawValue)
        }
        return route
    }

    public func setRoute(_ route: LLMRoute, for task: LLMTaskClass) {
        llmRoutes[task] = route
    }

    /// Resolve a task's route honoring a project's override (BAS-23): the
    /// project's route for the task wins over the global preset; falls back to
    /// `route(forLLM:)` when there's no project or no override.
    public func route(forLLM task: LLMTaskClass, projectID: UUID?) throws -> LLMRoute {
        if let projectID, let route = projectLLMOverrides[projectID]?[task] {
            return route
        }
        return try route(forLLM: task)
    }

    /// Replace a project's full set of LLM route overrides (empty clears it).
    public func setProjectLLMOverrides(_ overrides: [LLMTaskClass: LLMRoute], projectID: UUID) {
        if overrides.isEmpty {
            projectLLMOverrides[projectID] = nil
        } else {
            projectLLMOverrides[projectID] = overrides
        }
    }

    /// Drop all of a project's LLM route overrides (e.g. on project delete).
    public func clearProjectLLMOverrides(projectID: UUID) {
        projectLLMOverrides[projectID] = nil
    }

    /// The per-project route override for a task, or nil to use the global
    /// preset.
    ///
    /// Lets `MergeEngine` apply a project's route without exposing the
    /// override table.
    public func projectRoute(forLLM task: LLMTaskClass, projectID: UUID?) -> LLMRoute? {
        guard let projectID else { return nil }
        return projectLLMOverrides[projectID]?[task]
    }

    public func setRoute(_ route: EmbeddingRoute, for task: EmbeddingTaskClass) {
        embeddingRoutes[task] = route
    }

    public func register(provider: any LLMProvider) {
        llmProviders[provider.kind] = provider
    }

    public func register(provider: any EmbeddingProvider) {
        embeddingProviders[provider.embeddingKind] = provider
    }

    public func llmProvider(for kind: LLMProviderKind) -> (any LLMProvider)? {
        llmProviders[kind]
    }

    public func embeddingProvider(for kind: EmbeddingProviderKind) -> (any EmbeddingProvider)? {
        embeddingProviders[kind]
    }

    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        let route = try self.route(forLLM: request.taskClass)
        guard let provider = llmProviders[route.provider] else {
            throw TraceError.modelProviderFailed(
                provider: route.provider.rawValue,
                underlying: TraceError.configInvalid(field: "provider", reason: "not registered")
            )
        }
        return try await provider.generate(request, route: route)
    }

    public func embed(texts: [String], task: EmbeddingTaskClass) async throws -> [[Float]] {
        let route = try self.route(forEmbedding: task)
        guard let provider = embeddingProviders[route.provider] else {
            throw TraceError.modelProviderFailed(
                provider: route.provider.rawValue,
                underlying: TraceError.configInvalid(field: "provider", reason: "not registered")
            )
        }
        return try await provider.embed(texts, route: route)
    }

    // Default routes read endpoints/accounts from `ModelProvider` (the catalog) —
    // no hardcoded base URLs / Keychain accounts here. Local stages → Apple FM;
    // notes + library Q&A → OpenRouter with an explicit model.
    public static let defaultLLMRoutes: [LLMTaskClass: LLMRoute] = [
        .dictationCleanup: ModelProvider.appleFM.route(model: "apple-fm-default"),
        .titleGeneration: ModelProvider.appleFM.route(model: "apple-fm-default"),
        .projectCategorization: ModelProvider.appleFM.route(model: "apple-fm-default"),
        .meetingSummary: ModelProvider.openRouter.route(model: "openai/gpt-5"),
        .meetingAugmentedMerge: ModelProvider.openRouter.route(model: "openai/gpt-5"),
        // Retired task class (the old coach gatekeeper pipeline). The case
        // survives only for persistence compatibility — per-project override
        // JSON may still carry it; nothing calls through it any more.
        .coachSmartRouting: ModelProvider.appleFM.route(model: "apple-fm-default"),
        // The coach is cloud-only by design (it needs a capable model). Default
        // is Flash LITE by the owner's explicit cost call: the coach bench
        // (BenchScenarios/coach) scored it 9/10 with the code gates policing
        // its eagerness (duplicates + unverifiable recalls die mechanically);
        // its one residual habit is restating settled moments. 3.5-flash
        // scored 10/10 on its own judgement and sits in the Settings picker
        // for whenever the trade is worth a few pence per meeting.
        .coachCardContent: ModelProvider.openRouter.route(model: "google/gemini-3.1-flash-lite"),
        .libraryQA: ModelProvider.openRouter.route(model: "google/gemini-3.1-flash-lite"),
        .conversationStateExtractor: ModelProvider.appleFM.route(model: "apple-fm-default"),
    ]

    public static let defaultEmbeddingRoutes: [EmbeddingTaskClass: EmbeddingRoute] = [
        .embeddingsIndex: EmbeddingRoute(
            provider: .ollama, model: "nomic-embed-text", baseURL: URL(string: "http://localhost:11434")),
        .embeddingsLive: EmbeddingRoute(
            provider: .ollama, model: "nomic-embed-text", baseURL: URL(string: "http://localhost:11434")),
    ]
}
