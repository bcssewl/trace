import Foundation

/// Anthropic Messages API wire format (`POST https://api.anthropic.com/v1/messages`).
///
/// Shared request/response/SSE coding for the Anthropic-direct provider (BAS-37).
/// Kept separate + fixture-tested because the app now speaks two LLM wire formats
/// (OpenAI Chat Completions and Anthropic Messages).
public enum AnthropicMessagesWire {

    /// Builds the Anthropic request body.
    ///
    /// The `system` turn is lifted to the
    /// top-level `system` field (Anthropic keeps it out of `messages`); the rest
    /// stay as `{role, content}`. `max_tokens` is required by the API, so an
    /// absent `LLMRequest.maxTokens` falls back to `defaultMaxTokens`.
    public static func requestBody(
        _ request: LLMRequest,
        model: String,
        stream: Bool,
        defaultMaxTokens: Int = 4096
    ) throws -> Data {
        let system = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let turns = request.messages
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = [
            "model": model,
            "messages": turns,
            "max_tokens": request.maxTokens ?? defaultMaxTokens,
            "temperature": request.temperature,
            "stream": stream,
        ]
        if !system.isEmpty { body["system"] = system }
        if !request.stopSequences.isEmpty { body["stop_sequences"] = request.stopSequences }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Decodes a non-streaming Anthropic Messages response into an `LLMResponse`,
    /// concatenating all `text` content blocks.
    public static func decodeResponse(_ data: Data, model: String) throws -> LLMResponse {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        let reason: LLMResponse.FinishReason
        switch decoded.stop_reason ?? "end_turn" {
        case "end_turn", "stop_sequence": reason = .stop
        case "max_tokens": reason = .length
        default: reason = .other
        }
        return LLMResponse(
            text: text,
            finishReason: reason,
            usage: LLMUsage(
                promptTokens: decoded.usage?.input_tokens ?? 0,
                completionTokens: decoded.usage?.output_tokens ?? 0
            ),
            provider: "anthropic",
            model: model
        )
    }

    /// The text increment from an Anthropic SSE event, or `nil` for any
    /// non-text event (`message_start`/`message_stop`/`ping`/tool-use deltas).
    ///
    /// Reads the `delta.text` of a `content_block_delta` whose `delta.type` is
    /// `text_delta`; the event's `data` JSON carries the type, so the `event:`
    /// line is not required.
    public static func textDelta(from event: SSEEvent) -> String? {
        guard let data = event.data.data(using: .utf8),
            let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
            chunk.delta?.type == "text_delta",
            let text = chunk.delta?.text, !text.isEmpty
        else { return nil }
        return text
    }

    struct Response: Codable {
        struct Block: Codable {
            let type: String
            let text: String?
        }
        struct Usage: Codable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
        let content: [Block]
        let stop_reason: String?
        let usage: Usage?
    }

    struct StreamChunk: Codable {
        struct Delta: Codable {
            let type: String?
            let text: String?
        }
        let delta: Delta?
    }
}
