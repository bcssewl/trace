import Foundation

public enum ASRTaskClass: String, Sendable, Codable, Hashable, CaseIterable {
    case liveDictation
    case meetingCaptureLive
    case fileBatchEnglish
    case fileBatchMulti
    case fileBatchCJK
    case voiceMemo
    case sensitiveLocalOnly
    case qualityBatch
    case mandarinHighQuality
}

public struct ASRRoute: Sendable, Codable, Hashable {
    public let engineIdentifier: String
    public let modelIdentifier: String
    public let allowsCloud: Bool
    public init(engineIdentifier: String, modelIdentifier: String, allowsCloud: Bool) {
        self.engineIdentifier = engineIdentifier
        self.modelIdentifier = modelIdentifier
        self.allowsCloud = allowsCloud
    }
}

public actor ASRRouter {
    private var defaults: [ASRTaskClass: ASRRoute]
    private var overrides: [UUID: [ASRTaskClass: ASRRoute]]

    public init(
        defaults: [ASRTaskClass: ASRRoute] = ASRRouter.defaultRoutes,
        overrides: [UUID: [ASRTaskClass: ASRRoute]] = [:]
    ) {
        self.defaults = defaults
        self.overrides = overrides
    }

    public func route(for task: ASRTaskClass, projectID: UUID?) -> ASRRoute {
        if let projectID, let route = overrides[projectID]?[task] {
            if task == .sensitiveLocalOnly && route.allowsCloud {
                return defaults[.sensitiveLocalOnly]!
            }
            return route
        }
        return defaults[task]!
    }

    public func setOverride(_ route: ASRRoute, for task: ASRTaskClass, projectID: UUID) {
        overrides[projectID, default: [:]][task] = route
    }

    /// Replace a project's full set of ASR route overrides (empty clears it).
    ///
    /// Hydrated from `ProjectOverrides.asrRouteOverrides` at launch / on edit.
    public func setProjectOverrides(_ routes: [ASRTaskClass: ASRRoute], projectID: UUID) {
        if routes.isEmpty {
            overrides[projectID] = nil
        } else {
            overrides[projectID] = routes
        }
    }

    /// Drop all of a project's ASR route overrides (e.g. on project delete).
    public func clearProjectOverrides(projectID: UUID) {
        overrides[projectID] = nil
    }

    public static let defaultRoutes: [ASRTaskClass: ASRRoute] = [
        .liveDictation: .init(engineIdentifier: "parakeet", modelIdentifier: "eou-120m", allowsCloud: false),
        .meetingCaptureLive: .init(engineIdentifier: "parakeet", modelIdentifier: "tdt-v3", allowsCloud: false),
        .fileBatchEnglish: .init(engineIdentifier: "whisperkit", modelIdentifier: "large-v3-turbo", allowsCloud: false),
        .fileBatchMulti: .init(engineIdentifier: "parakeet", modelIdentifier: "tdt-v3", allowsCloud: false),
        .fileBatchCJK: .init(engineIdentifier: "qwen3", modelIdentifier: "qwen3-asr-0.6b-int8", allowsCloud: false),
        .voiceMemo: .init(engineIdentifier: "parakeet", modelIdentifier: "eou-120m", allowsCloud: false),
        .sensitiveLocalOnly: .init(engineIdentifier: "parakeet", modelIdentifier: "tdt-v3", allowsCloud: false),
        .qualityBatch: .init(engineIdentifier: "groq", modelIdentifier: "whisper-large-v3-turbo", allowsCloud: true),
        .mandarinHighQuality: .init(engineIdentifier: "volcengine", modelIdentifier: "bigmodel-asr", allowsCloud: true),
    ]
}
