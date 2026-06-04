import Foundation

public enum LLMRole: String, Sendable, Codable, Hashable {
    case system
    case user
    case assistant
}

public struct LLMMessage: Sendable, Codable, Hashable {
    public let role: LLMRole
    public let content: String
    public init(role: LLMRole, content: String) {
        self.role = role
        self.content = content
    }
}

public struct LLMRequest: Sendable, Hashable {
    public let messages: [LLMMessage]
    public let taskClass: LLMTaskClass
    public let temperature: Double
    public let maxTokens: Int?
    public let stopSequences: [String]
    public let responseFormat: ResponseFormat

    public enum ResponseFormat: Sendable, Hashable {
        case text
        case json
    }

    public init(
        messages: [LLMMessage],
        taskClass: LLMTaskClass,
        temperature: Double = 0.2,
        maxTokens: Int? = nil,
        stopSequences: [String] = [],
        responseFormat: ResponseFormat = .text
    ) {
        self.messages = messages
        self.taskClass = taskClass
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.responseFormat = responseFormat
    }
}

public struct LLMUsage: Sendable, Hashable, Codable {
    public let promptTokens: Int
    public let completionTokens: Int
    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
    public static let zero = LLMUsage(promptTokens: 0, completionTokens: 0)
}

public struct LLMResponse: Sendable, Hashable {
    public let text: String
    public let finishReason: FinishReason
    public let usage: LLMUsage
    public let provider: String
    public let model: String

    public enum FinishReason: String, Sendable, Codable, Hashable {
        case stop
        case length
        case contentFilter
        case error
        case other
    }

    public init(text: String, finishReason: FinishReason, usage: LLMUsage, provider: String, model: String) {
        self.text = text
        self.finishReason = finishReason
        self.usage = usage
        self.provider = provider
        self.model = model
    }
}

public struct LLMDelta: Sendable, Hashable {
    public let textIncrement: String
    public let isFinal: Bool
    public init(textIncrement: String, isFinal: Bool = false) {
        self.textIncrement = textIncrement
        self.isFinal = isFinal
    }
}

public enum LLMTaskClass: String, Sendable, Codable, Hashable, CaseIterable {
    case dictationCleanup
    case titleGeneration
    case projectCategorization
    case meetingSummary
    case meetingAugmentedMerge
    case coachSmartRouting
    case coachCardContent
    case libraryQA
    case conversationStateExtractor
}

public enum EmbeddingTaskClass: String, Sendable, Codable, Hashable, CaseIterable {
    case embeddingsIndex
    case embeddingsLive
    case embeddingsRerank
}

public enum LLMProviderKind: String, Sendable, Codable, Hashable, CaseIterable {
    case appleFM
    case ollama
    case openAICompat
    /// Anthropic Messages wire (`/v1/messages`, `x-api-key`) — Anthropic direct (BAS-37).
    case anthropicMessages
    /// ChatGPT/Codex OAuth subscription → the ChatGPT-backend Responses API (BAS-37).
    case codexSubscription
}

public enum EmbeddingProviderKind: String, Sendable, Codable, Hashable, CaseIterable {
    case ollama
    case openAICompat
    case voyageAI
}

public struct LLMRoute: Sendable, Codable, Hashable {
    public let provider: LLMProviderKind
    public let model: String
    public let baseURL: URL?
    public let keychainAccount: String?

    public init(provider: LLMProviderKind, model: String, baseURL: URL? = nil, keychainAccount: String? = nil) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.keychainAccount = keychainAccount
    }
}

public struct EmbeddingRoute: Sendable, Codable, Hashable {
    public let provider: EmbeddingProviderKind
    public let model: String
    public let baseURL: URL?
    public let keychainAccount: String?

    public init(provider: EmbeddingProviderKind, model: String, baseURL: URL? = nil, keychainAccount: String? = nil) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.keychainAccount = keychainAccount
    }
}

public protocol LLMProvider: Sendable {
    var kind: LLMProviderKind { get }
    func generate(_ request: LLMRequest, route: LLMRoute) async throws -> LLMResponse
    func stream(_ request: LLMRequest, route: LLMRoute) -> AsyncThrowingStream<LLMDelta, Error>
}

public protocol EmbeddingProvider: Sendable {
    var embeddingKind: EmbeddingProviderKind { get }
    func embed(_ texts: [String], route: EmbeddingRoute) async throws -> [[Float]]
}
