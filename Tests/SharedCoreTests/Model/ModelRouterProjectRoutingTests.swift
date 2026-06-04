import XCTest

@testable import SharedCore

final class ModelRouterProjectRoutingTests: XCTestCase {

    func testProjectOverrideWinsOverGlobalPreset() async throws {
        let router = ModelRouter()
        let pid = UUID()
        let override = LLMRoute(provider: .ollama, model: "llama3.2", baseURL: URL(string: "http://localhost:11434"))
        await router.setProjectLLMOverrides([.meetingSummary: override], projectID: pid)

        let routed = try await router.route(forLLM: .meetingSummary, projectID: pid)
        XCTAssertEqual(routed, override)
        // Exercise the production dispatch path: MergeEngine asks via the facade.
        let facade: any ModelRoutingFacade = router
        let peek = await facade.projectRoute(forLLM: .meetingSummary, projectID: pid)
        XCTAssertEqual(peek, override)
    }

    func testFallsBackToGlobalWhenNoOverride() async throws {
        let router = ModelRouter()
        let pid = UUID()
        let global = try await router.route(forLLM: .meetingSummary)
        let routed = try await router.route(forLLM: .meetingSummary, projectID: pid)
        XCTAssertEqual(routed, global)
        let facade: any ModelRoutingFacade = router
        let peekProject = await facade.projectRoute(forLLM: .meetingSummary, projectID: pid)
        XCTAssertNil(peekProject)
        let peekNil = await facade.projectRoute(forLLM: .meetingSummary, projectID: nil)
        XCTAssertNil(peekNil)
    }

    func testOnlyOverriddenTaskIsAffected() async throws {
        let router = ModelRouter()
        let pid = UUID()
        let override = LLMRoute(provider: .ollama, model: "x")
        await router.setProjectLLMOverrides([.titleGeneration: override], projectID: pid)
        // A different task with no per-project override falls through to global.
        let global = try await router.route(forLLM: .meetingSummary)
        let routed = try await router.route(forLLM: .meetingSummary, projectID: pid)
        XCTAssertEqual(routed, global)
    }

    func testClearAndEmptyRemoveOverrides() async throws {
        let router = ModelRouter()
        let pid = UUID()
        let facade: any ModelRoutingFacade = router

        await router.setProjectLLMOverrides([.titleGeneration: LLMRoute(provider: .ollama, model: "x")], projectID: pid)
        await router.clearProjectLLMOverrides(projectID: pid)
        let afterClear = await facade.projectRoute(forLLM: .titleGeneration, projectID: pid)
        XCTAssertNil(afterClear)

        await router.setProjectLLMOverrides([.titleGeneration: LLMRoute(provider: .ollama, model: "x")], projectID: pid)
        await router.setProjectLLMOverrides([:], projectID: pid)  // empty clears
        let afterEmpty = await facade.projectRoute(forLLM: .titleGeneration, projectID: pid)
        XCTAssertNil(afterEmpty)
    }
}
