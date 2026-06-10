import XCTest

@testable import SharedCore

final class BootstrapConfigTests: XCTestCase {

    func testBundledConfigHasEveryLLMTaskClass() {
        let cfg = BootstrapConfig.bundled
        for task in LLMTaskClass.allCases {
            XCTAssertNotNil(cfg.llmRoutes[task], "missing LLM route for \(task)")
        }
    }

    func testBundledConfigHasEveryEmbeddingTaskClass() {
        let cfg = BootstrapConfig.bundled
        for task in EmbeddingTaskClass.allCases {
            XCTAssertNotNil(cfg.embeddingRoutes[task], "missing embedding route for \(task)")
        }
    }

    func testBundledConfigEmbeddingTasksNeverResolveToAppleFM() {
        let cfg = BootstrapConfig.bundled
        for (task, route) in cfg.embeddingRoutes {
            XCTAssertNotEqual(
                route.provider.rawValue,
                "appleFM",
                "embedding task \(task) must not route to Apple FM"
            )
        }
    }

    func testLLMRouteDefaultsMatchSpec() {
        let cfg = BootstrapConfig.bundled
        XCTAssertEqual(cfg.llmRoutes[.dictationCleanup]?.provider, .appleFM)
        XCTAssertEqual(cfg.llmRoutes[.titleGeneration]?.provider, .appleFM)
        XCTAssertEqual(cfg.llmRoutes[.projectCategorization]?.provider, .appleFM)
        XCTAssertEqual(cfg.llmRoutes[.coachSmartRouting]?.provider, .appleFM)  // retired task class
        // The coach is cloud-only, on Flash Lite by the owner's cost call —
        // 3.5-flash (the bench's 10/10 pick) stays available in Settings.
        XCTAssertEqual(cfg.llmRoutes[.coachCardContent]?.provider, .openAICompat)
        XCTAssertEqual(cfg.llmRoutes[.coachCardContent]?.model, "google/gemini-3.1-flash-lite")
        XCTAssertEqual(cfg.llmRoutes[.coachCardContent]?.keychainAccount, "openrouter")
        XCTAssertEqual(cfg.llmRoutes[.conversationStateExtractor]?.provider, .appleFM)
        XCTAssertEqual(cfg.llmRoutes[.meetingSummary]?.provider, .openAICompat)
        XCTAssertEqual(cfg.llmRoutes[.meetingAugmentedMerge]?.provider, .openAICompat)
        XCTAssertEqual(cfg.llmRoutes[.libraryQA]?.provider, .openAICompat)
    }

    func testRoundTripsThroughJSON() throws {
        let original = BootstrapConfig.bundled
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BootstrapConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLoadReturnsNilForMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")
        XCTAssertNil(BootstrapConfig.load(from: missing))
    }

    func testLoadParsesValidJSONFromDisk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(BootstrapConfig.bundled)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loaded = BootstrapConfig.load(from: tmp)
        XCTAssertEqual(loaded, BootstrapConfig.bundled)
    }

    func testResolvedUsesOverrideWhenProvided() {
        let custom = BootstrapConfig(
            llmRoutes: [.dictationCleanup: LLMRoute(provider: .ollama, model: "qwen3:1.7b")],
            embeddingRoutes: [.embeddingsIndex: EmbeddingRoute(provider: .ollama, model: "nomic-embed-text")],
            hotkeys: BootstrapConfig.bundled.hotkeys,
            sparkle: BootstrapConfig.bundled.sparkle,
            storage: BootstrapConfig.bundled.storage,
            modelCaches: BootstrapConfig.bundled.modelCaches,
            diagnostics: BootstrapConfig.bundled.diagnostics
        )
        let resolved = BootstrapConfig.resolved(override: custom)
        XCTAssertEqual(resolved.llmRoutes[.dictationCleanup]?.provider, .ollama)
    }
}
