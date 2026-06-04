import Foundation

@testable import SharedCore

/// Content-sensitive, network-free embeddings for retrieval tests: a 32-dim
/// hashed bag-of-words so texts that share tokens score a higher cosine (unlike
/// the fixed-vector stubs used by pure persistence tests).
///
/// Registers under
/// `.ollama` to match the default embedding route.
struct BagOfWordsEmbeddingProvider: EmbeddingProvider {
    let embeddingKind: EmbeddingProviderKind = .ollama
    let dim = 32

    func embed(_ texts: [String], route: EmbeddingRoute) async throws -> [[Float]] {
        texts.map(vector(for:))
    }

    private func vector(for text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var h: UInt64 = 5381
            for byte in token.utf8 { h = (h &* 33) &+ UInt64(byte) }
            v[Int(h % UInt64(dim))] += 1
        }
        return v
    }
}

/// Scripted LLM provider that echoes a fixed answer.
///
/// Registers under
/// `.openAICompat` so the default `.libraryQA` route resolves to it.
struct StubLLMProvider: LLMProvider {
    let kind: LLMProviderKind
    let answer: String
    let model: String

    init(kind: LLMProviderKind = .openAICompat, answer: String, model: String = "stub-claude") {
        self.kind = kind
        self.answer = answer
        self.model = model
    }

    func generate(_ request: LLMRequest, route: LLMRoute) async throws -> LLMResponse {
        LLMResponse(
            text: answer, finishReason: .stop,
            usage: LLMUsage(promptTokens: 42, completionTokens: 17),
            provider: kind.rawValue, model: model
        )
    }

    func stream(_ request: LLMRequest, route: LLMRoute) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

func makeSavedMeeting(
    id: String = "session_test",
    projectId: String? = "P1",
    title: String = "Q2 Strategy",
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    utterances: [Utterance],
    notes: String = "",
    summary: String? = nil
) -> SavedMeeting {
    SavedMeeting(
        metadata: SessionMetadata(
            sessionId: id, projectId: projectId, title: title,
            startedAt: startedAt, sessionDirPath: "/tmp/\(id)"
        ),
        notes: notes, summary: summary, utterances: utterances
    )
}
