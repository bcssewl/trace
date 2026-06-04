import XCTest

@testable import SharedCore

final class EmbeddingAvailabilityTests: XCTestCase {

    func testModelPresentMatchesExactLatestAndTag() {
        let models = [
            OllamaModel(name: "nomic-embed-text:latest", sizeBytes: 1, digest: nil),
            OllamaModel(name: "gemma4:e4b", sizeBytes: 2, digest: nil),
        ]
        XCTAssertTrue(EmbeddingAvailabilityChecker.modelPresent("nomic-embed-text", in: models))
        XCTAssertTrue(EmbeddingAvailabilityChecker.modelPresent("NOMIC-EMBED-TEXT", in: models))
        XCTAssertFalse(EmbeddingAvailabilityChecker.modelPresent("mxbai-embed-large", in: models))
    }

    func testModelPresentExactNoTag() {
        let models = [OllamaModel(name: "nomic-embed-text", sizeBytes: 1, digest: nil)]
        XCTAssertTrue(EmbeddingAvailabilityChecker.modelPresent("nomic-embed-text", in: models))
    }

    func testCheckOkWhenModelInstalled() async {
        let session = StubURLProtocol.session(status: 200, json: #"{"models":[{"name":"nomic-embed-text:latest"}]}"#)
        let result = await EmbeddingAvailabilityChecker(session: session).check(config: ollamaConfig())
        XCTAssertEqual(result, .ok(model: "nomic-embed-text"))
        XCTAssertFalse(result.needsAttention)
    }

    func testCheckModelMissingWhenOtherModelsPresent() async {
        let session = StubURLProtocol.session(status: 200, json: #"{"models":[{"name":"gemma4:e4b"}]}"#)
        let result = await EmbeddingAvailabilityChecker(session: session).check(config: ollamaConfig())
        XCTAssertEqual(result, .modelMissing(model: "nomic-embed-text"))
        XCTAssertTrue(result.needsAttention)
    }

    func testCheckOllamaUnreachable() async {
        let session = StubURLProtocol.session(status: 500, json: "")
        let result = await EmbeddingAvailabilityChecker(session: session).check(config: ollamaConfig())
        XCTAssertEqual(result, .ollamaUnreachable)
        XCTAssertTrue(result.needsAttention)
    }

    func testNonOllamaProviderIsNotApplicable() async {
        let cfg = EmbeddingConfig(
            provider: "openai", baseURL: URL(string: "https://api.openai.com"),
            model: "text-embedding-3-small", normalization: .unitL2
        )
        let result = await EmbeddingAvailabilityChecker().check(config: cfg)
        XCTAssertEqual(result, .notApplicable)
    }

    private func ollamaConfig() -> EmbeddingConfig {
        EmbeddingConfig(
            provider: "ollama", baseURL: URL(string: "http://localhost:11434"),
            model: "nomic-embed-text", normalization: .unitL2
        )
    }
}

/// Minimal canned-response URLProtocol for stubbing the Ollama `/api/tags` probe.
final class StubURLProtocol: URLProtocol {
    private struct Stub: Sendable {
        let status: Int
        let body: Data
    }
    nonisolated(unsafe) private static var stub = Stub(status: 200, body: Data())

    static func session(status: Int, json: String) -> URLSession {
        stub = Stub(status: status, body: Data(json.utf8))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let snapshot = Self.stub
        let url = request.url ?? URL(string: "http://localhost:11434/api/tags")!
        let response = HTTPURLResponse(url: url, statusCode: snapshot.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: snapshot.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
