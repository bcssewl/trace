import Foundation
import XCTest

@testable import CoachModule
@testable import SharedCore

/// Minimal scripted `LLMProvider` so we can drive `AppleFmAntiFabricationChecker`
/// through a real `ModelRouter` without any network/model dependency.
///
/// It answers
/// for the `.appleFM` kind, which is the default route for `.coachSmartRouting`.
private struct StubLLMProvider: LLMProvider {
    let kind: LLMProviderKind = .appleFM
    let responseText: String
    let shouldThrow: Bool

    init(responseText: String = "", shouldThrow: Bool = false) {
        self.responseText = responseText
        self.shouldThrow = shouldThrow
    }

    func generate(_ request: LLMRequest, route: LLMRoute) async throws -> LLMResponse {
        if shouldThrow {
            throw TraceError.modelProviderFailed(
                provider: route.provider.rawValue,
                underlying: TraceError.configInvalid(field: "test", reason: "scripted failure")
            )
        }
        return LLMResponse(
            text: responseText,
            finishReason: .stop,
            usage: .zero,
            provider: route.provider.rawValue,
            model: route.model
        )
    }

    nonisolated func stream(
        _ request: LLMRequest, route: LLMRoute
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private func makeRouter(_ provider: StubLLMProvider) async -> ModelRouter {
    let router = ModelRouter()
    await router.register(provider: provider)
    return router
}

final class ScriptedAntiFabricationCheckerTests: XCTestCase {
    func testScriptedGroundedFalseReturnsFalse() async {
        let checker = ScriptedAntiFabricationChecker(grounded: false)
        let result = await checker.verify(claim: "Annual is $9,999.", support: "Some support.")
        XCTAssertFalse(result)
    }

    func testScriptedGroundedTrueReturnsTrue() async {
        let checker = ScriptedAntiFabricationChecker(grounded: true)
        let result = await checker.verify(claim: "Annual is $1,200.", support: "Annual is $1,200.")
        XCTAssertTrue(result)
    }

    func testScriptedDefaultsToTrue() async {
        let checker = ScriptedAntiFabricationChecker()
        let result = await checker.verify(claim: "anything", support: "anything")
        XCTAssertTrue(result)
    }
}

final class AppleFmAntiFabricationCheckerTests: XCTestCase {
    func testGroundedFalseResponseYieldsFalse() async {
        let router = await makeRouter(StubLLMProvider(responseText: #"{"grounded": false}"#))
        let checker = AppleFmAntiFabricationChecker(router: router)
        let result = await checker.verify(
            claim: "We agreed to a 40% discount.",
            support: "We discussed pricing tiers."
        )
        XCTAssertFalse(result, "A {\"grounded\":false} response must report the claim as ungrounded.")
    }

    func testGroundedTrueResponseYieldsTrue() async {
        let router = await makeRouter(StubLLMProvider(responseText: #"{"grounded": true}"#))
        let checker = AppleFmAntiFabricationChecker(router: router)
        let result = await checker.verify(
            claim: "Annual is $1,200.",
            support: "Annual pricing is $1,200 per seat."
        )
        XCTAssertTrue(result)
    }

    func testMalformedResponseFailsOpen() async {
        let router = await makeRouter(StubLLMProvider(responseText: "not json at all"))
        let checker = AppleFmAntiFabricationChecker(router: router)
        let result = await checker.verify(
            claim: "We agreed to a 40% discount.",
            support: "We discussed pricing tiers."
        )
        XCTAssertTrue(result, "An unparseable response must fail open (true).")
    }

    func testMissingGroundedKeyFailsOpen() async {
        let router = await makeRouter(StubLLMProvider(responseText: #"{"other": false}"#))
        let checker = AppleFmAntiFabricationChecker(router: router)
        let result = await checker.verify(claim: "claim", support: "support")
        XCTAssertTrue(result, "A response without a grounded key must fail open (true).")
    }

    func testProviderErrorFailsOpen() async {
        let router = await makeRouter(StubLLMProvider(shouldThrow: true))
        let checker = AppleFmAntiFabricationChecker(router: router)
        let result = await checker.verify(claim: "claim", support: "support")
        XCTAssertTrue(result, "A provider error must fail open (true).")
    }

    func testEmptySupportShortCircuitsToTrue() async {
        // Provider would say false, but empty support must short-circuit to true
        // without ever calling the model.
        let router = await makeRouter(StubLLMProvider(responseText: #"{"grounded": false}"#))
        let checker = AppleFmAntiFabricationChecker(router: router)
        let result = await checker.verify(claim: "We agreed to a 40% discount.", support: "   \n  ")
        XCTAssertTrue(result, "Empty/whitespace support must fail open without checking.")
    }
}
