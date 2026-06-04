import Foundation

/// The ChatGPT-backend Responses API wire (`POST https://chatgpt.com/backend-api/
/// codex/responses`) used by the Codex subscription provider (BAS-37).
///
/// The body
/// must set `store:false`, `stream:true`, a non-empty `instructions`, an `input`
/// message array, and `include:["reasoning.encrypted_content"]`. Fixture-tested.
public enum ResponsesAPI {
    static let defaultInstructions = "You are a helpful assistant."

    public static func requestBody(_ request: LLMRequest, model: String) throws -> Data {
        let system = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let input: [[String: Any]] = request.messages
            .filter { $0.role != .system }
            .map { message in
                // Assistant turns use `output_text`; user turns use `input_text`.
                let contentType = message.role == .assistant ? "output_text" : "input_text"
                return [
                    "type": "message",
                    "role": message.role.rawValue,
                    "content": [["type": contentType, "text": message.content]],
                ]
            }
        let body: [String: Any] = [
            "model": model,
            "instructions": system.isEmpty ? defaultInstructions : system,
            "input": input,
            "store": false,
            "stream": true,
            "include": ["reasoning.encrypted_content"],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// The text increment from a `response.output_text.delta` event, else `nil`.
    public static func textDelta(from event: SSEEvent) -> String? {
        guard let obj = decode(event),
            (obj["type"] as? String) == "response.output_text.delta",
            let delta = obj["delta"] as? String, !delta.isEmpty
        else { return nil }
        return delta
    }

    public static func isCompleted(_ event: SSEEvent) -> Bool {
        (decode(event)?["type"] as? String) == "response.completed"
    }

    /// An error message if this event reports a Responses failure, else `nil`.
    public static func error(from event: SSEEvent) -> String? {
        guard let obj = decode(event) else { return nil }
        let type = obj["type"] as? String ?? ""
        guard type == "response.failed" || type == "error" else { return nil }
        if let response = obj["response"] as? [String: Any],
            let error = response["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }
        if let error = obj["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return "Responses API error"
    }

    private static func decode(_ event: SSEEvent) -> [String: Any]? {
        guard let data = event.data.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
