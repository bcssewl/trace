import Foundation
import XCTest

@testable import SharedCore

/// BAS-37 — Anthropic Messages wire (request body, response decode, SSE text
/// deltas) + the provider's request headers.
///
/// Fixture-pinned so a wire change is
/// caught (the plan flags two wire formats now; keep decoders tested).
final class AnthropicMessagesWireTests: XCTestCase {

    func testRequestBodyLiftsSystemAndKeepsTurns() throws {
        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: "You are helpful."),
                LLMMessage(role: .user, content: "Hi"),
                LLMMessage(role: .assistant, content: "Hello"),
                LLMMessage(role: .user, content: "More?"),
            ],
            taskClass: .libraryQA, temperature: 0.3, maxTokens: 100, stopSequences: ["STOP"]
        )
        let data = try AnthropicMessagesWire.requestBody(request, model: "claude-sonnet-4-6", stream: true)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(json["system"] as? String, "You are helpful.")
        XCTAssertEqual(json["max_tokens"] as? Int, 100)
        XCTAssertEqual(json["temperature"] as? Double, 0.3)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["stop_sequences"] as? [String], ["STOP"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3, "the system turn is lifted out of the messages array")
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "Hi")
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
    }

    func testRequestBodyDefaultsMaxTokensAndOmitsAbsentSystem() throws {
        let request = LLMRequest(messages: [LLMMessage(role: .user, content: "Hi")], taskClass: .libraryQA)
        let data = try AnthropicMessagesWire.requestBody(request, model: "m", stream: false, defaultMaxTokens: 2048)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["max_tokens"] as? Int, 2048, "Anthropic requires max_tokens")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertNil(json["system"], "no system turn ⇒ no system field")
    }

    func testDecodeResponseExtractsTextStopAndUsage() throws {
        let fixture = Data(
            #"""
            {"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Hello there"}],"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":4}}
            """#.utf8)
        let resp = try AnthropicMessagesWire.decodeResponse(fixture, model: "claude")
        XCTAssertEqual(resp.text, "Hello there")
        XCTAssertEqual(resp.finishReason, .stop)
        XCTAssertEqual(resp.usage.promptTokens, 12)
        XCTAssertEqual(resp.usage.completionTokens, 4)
        XCTAssertEqual(resp.provider, "anthropic")
    }

    func testDecodeResponseConcatenatesBlocksAndMapsMaxTokens() throws {
        let fixture = Data(
            #"{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}],"stop_reason":"max_tokens","usage":{"input_tokens":1,"output_tokens":2}}"#
                .utf8)
        let resp = try AnthropicMessagesWire.decodeResponse(fixture, model: "claude")
        XCTAssertEqual(resp.text, "AB")
        XCTAssertEqual(resp.finishReason, .length)
    }

    func testSSETextDelta() {
        let event = SSEEvent(
            event: "content_block_delta",
            data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#)
        XCTAssertEqual(AnthropicMessagesWire.textDelta(from: event), "Hel")
    }

    func testSSEIgnoresNonTextEvents() {
        XCTAssertNil(
            AnthropicMessagesWire.textDelta(from: SSEEvent(event: "message_start", data: #"{"type":"message_start"}"#)))
        XCTAssertNil(
            AnthropicMessagesWire.textDelta(from: SSEEvent(event: "message_stop", data: #"{"type":"message_stop"}"#)))
        XCTAssertNil(
            AnthropicMessagesWire.textDelta(
                from: SSEEvent(
                    event: "content_block_delta", data: #"{"delta":{"type":"input_json_delta","partial_json":"{"}}"#)),
            "tool-use deltas are not text")
    }

    func testProviderRequestUsesAnthropicHeaders() {
        let route = LLMRoute(
            provider: .anthropicMessages, model: "claude",
            baseURL: URL(string: "https://api.anthropic.com/v1"), keychainAccount: "anthropic")
        let req = AnthropicMessagesProvider.makeRequest(route: route, apiKey: "sk-ant-123", body: Data("{}".utf8))
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.httpMethod, "POST")
    }
}
