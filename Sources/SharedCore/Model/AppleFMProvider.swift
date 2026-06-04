import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public actor AppleFMProvider: LLMProvider {
    public nonisolated var kind: LLMProviderKind { .appleFM }

    public init() {}

    public func generate(_ request: LLMRequest, route: LLMRoute) async throws -> LLMResponse {
        #if canImport(FoundationModels)
        return try await runFoundationModels(request: request, model: route.model)
        #else
        throw TraceError.modelProviderFailed(
            provider: "apple-fm",
            underlying: TraceError.configInvalid(
                field: "FoundationModels",
                reason: "FoundationModels framework not available — build against macOS 26 SDK"
            )
        )
        #endif
    }

    public nonisolated func stream(_ request: LLMRequest, route: LLMRoute) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let response = try await self.generate(request, route: route)
                    continuation.yield(LLMDelta(textIncrement: response.text))
                    continuation.yield(LLMDelta(textIncrement: "", isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(FoundationModels)
    private func runFoundationModels(request: LLMRequest, model: String) async throws -> LLMResponse {
        guard #available(macOS 26.0, *) else {
            throw TraceError.modelProviderFailed(
                provider: "apple-fm",
                underlying: TraceError.configInvalid(
                    field: "FoundationModels",
                    reason: "FoundationModels requires macOS 26 or later"
                )
            )
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw TraceError.modelProviderFailed(
                provider: "apple-fm",
                underlying: TraceError.configInvalid(
                    field: "FoundationModels",
                    reason: "SystemLanguageModel unavailable: \(String(describing: reason))"
                )
            )
        }

        let systemPrompt = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let userPrompt = request.messages
            .filter { $0.role != .system }
            .map { msg -> String in
                switch msg.role {
                case .user: return msg.content
                case .assistant: return "[assistant prior turn]\n\(msg.content)"
                case .system: return ""
                }
            }
            .joined(separator: "\n\n")

        let session: LanguageModelSession
        if systemPrompt.isEmpty {
            session = LanguageModelSession()
        } else {
            session = LanguageModelSession(instructions: systemPrompt)
        }

        let options = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: request.maxTokens
        )

        let response = try await session.respond(to: userPrompt, options: options)
        let text = response.content
        let promptApprox = (systemPrompt.count + userPrompt.count) / 4
        let completionApprox = text.count / 4
        return LLMResponse(
            text: text,
            finishReason: .stop,
            usage: LLMUsage(promptTokens: promptApprox, completionTokens: completionApprox),
            provider: "apple-fm",
            model: model.isEmpty ? "apple-fm-default" : model
        )
    }
    #endif
}
