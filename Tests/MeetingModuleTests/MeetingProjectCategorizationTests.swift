import SharedCore
import XCTest

@testable import MeetingModule

/// Covers the BAS-9 smart categorization additions.
/// - `MeetingProjectClassifier` — the configurable LLM "final classifier" (§8.2)
///   that picks the best project for a meeting (tested via a scripted router).
/// - `RoutedProjectCategorizer.merge` — the pure step that folds the LLM pick into
///   the deterministic signal scores and re-derives the confidence bucket.
final class MeetingProjectCategorizationTests: XCTestCase {

    // A minimal scripted ModelRoutingFacade (MeetingModuleTests can't see the one
    // in SharedCoreTests).
    private actor ScriptedRouter: ModelRoutingFacade {
        let scripted: String
        let fail: Bool
        var lastRequest: LLMRequest?
        init(_ scripted: String, fail: Bool = false) {
            self.scripted = scripted
            self.fail = fail
        }
        func capture(_ request: LLMRequest) { lastRequest = request }
        nonisolated func stream(_ request: LLMRequest, routeOverride: LLMRoute?) -> AsyncThrowingStream<LLMDelta, Error>
        {
            AsyncThrowingStream { continuation in
                Task {
                    await self.capture(request)
                    if await self.fail {
                        continuation.finish(
                            throwing: TraceError.modelRouteUnresolved(taskClass: "projectCategorization"))
                        return
                    }
                    continuation.yield(LLMDelta(textIncrement: await self.scripted))
                    continuation.finish()
                }
            }
        }
    }

    private let projectA = ProjectCandidate(id: UUID(), name: "Optivise")
    private let projectB = ProjectCandidate(id: UUID(), name: "Acme Redesign")
    private let transcript = "We need to finalize the Optivise pricing tiers before the launch next week"

    // MARK: - MeetingProjectClassifier

    func testClassifyReturnsPickedProjectAndConfidence() async {
        let router = ScriptedRouter(#"{"index": 1, "confidence": 0.9}"#)
        let pick = await MeetingProjectClassifier(router: router)
            .classify(transcriptPrefix: transcript, calendarTitle: nil, projects: [projectA, projectB])
        XCTAssertEqual(pick?.projectID, projectA.id)
        XCTAssertEqual(pick?.confidence ?? 0, 0.9, accuracy: 0.0001)
    }

    func testClassifyAbstainReturnsNil() async {
        let router = ScriptedRouter(#"{"index": 0, "confidence": 0.0}"#)
        let pick = await MeetingProjectClassifier(router: router)
            .classify(transcriptPrefix: transcript, calendarTitle: nil, projects: [projectA, projectB])
        XCTAssertNil(pick)
    }

    func testClassifyOutOfRangeIndexReturnsNil() async {
        let router = ScriptedRouter(#"{"index": 9, "confidence": 0.8}"#)
        let pick = await MeetingProjectClassifier(router: router)
            .classify(transcriptPrefix: transcript, calendarTitle: nil, projects: [projectA, projectB])
        XCTAssertNil(pick)
    }

    func testClassifyToleratesFencedJsonFromNonAppleModels() async {
        let router = ScriptedRouter("Sure! ```json\n{\"index\": 2, \"confidence\": 0.7}\n``` hope that helps")
        let pick = await MeetingProjectClassifier(router: router)
            .classify(transcriptPrefix: transcript, calendarTitle: nil, projects: [projectA, projectB])
        XCTAssertEqual(pick?.projectID, projectB.id)
    }

    func testClassifyWithNoProjectsDoesNotCallModel() async {
        let router = ScriptedRouter(#"{"index": 1, "confidence": 0.9}"#)
        let pick = await MeetingProjectClassifier(router: router)
            .classify(transcriptPrefix: transcript, calendarTitle: nil, projects: [])
        XCTAssertNil(pick)
        let captured = await router.lastRequest
        XCTAssertNil(captured)
    }

    func testClassifyUsesProjectCategorizationTaskClassAndAntiInjectionWrap() async {
        let router = ScriptedRouter(#"{"index": 1, "confidence": 0.5}"#)
        _ = await MeetingProjectClassifier(router: router)
            .classify(transcriptPrefix: transcript, calendarTitle: "Pricing sync", projects: [projectA, projectB])
        let request = await router.lastRequest
        XCTAssertEqual(request?.taskClass, .projectCategorization)
        let user = request?.messages.first { $0.role == .user }?.content ?? ""
        XCTAssertTrue(user.contains("<UNTRUSTED-DATA source=\"transcript\">"))
    }

    // MARK: - RoutedProjectCategorizer.merge (pure)

    private func result(_ bucket: CategorizationBucket, _ scores: [(ProjectCandidate, Double)]) -> CategorizationResult
    {
        CategorizationResult(
            bucket: bucket, scores: scores.map { CategorizationScore(project: $0.0, confidence: $0.1) })
    }

    func testMergeManualOverridePassesThroughIgnoringPick() {
        let base = result(.manualOverride, [])
        let merged = RoutedProjectCategorizer.merge(
            base: base, pick: .init(projectID: projectA.id, confidence: 0.99),
            autoAssignThreshold: 0.75, askUserThreshold: 0.4
        )
        XCTAssertEqual(merged.bucket, .manualOverride)
    }

    func testMergeNilPickLeavesBaseUnchanged() {
        let base = result(.inbox, [(projectA, 0.2), (projectB, 0.1)])
        let merged = RoutedProjectCategorizer.merge(
            base: base, pick: nil, autoAssignThreshold: 0.75, askUserThreshold: 0.4
        )
        XCTAssertEqual(merged, base)
    }

    func testMergeLlmPickBoostsProjectToAutoAssign() {
        // Deterministic signals only weakly matched B; the LLM is confident it's B.
        let base = result(.inbox, [(projectA, 0.3), (projectB, 0.2)])
        let merged = RoutedProjectCategorizer.merge(
            base: base, pick: .init(projectID: projectB.id, confidence: 0.92),
            autoAssignThreshold: 0.75, askUserThreshold: 0.4
        )
        XCTAssertEqual(merged.bucket, .autoAssign)
        XCTAssertEqual(merged.scores.first?.project.id, projectB.id)
        XCTAssertEqual(merged.scores.first?.confidence ?? 0, 0.92, accuracy: 0.0001)
    }

    func testMergeNeverDowngradesAStrongSignalScore() {
        let base = result(.autoAssign, [(projectA, 0.95)])
        let merged = RoutedProjectCategorizer.merge(
            base: base, pick: .init(projectID: projectA.id, confidence: 0.5),
            autoAssignThreshold: 0.75, askUserThreshold: 0.4
        )
        XCTAssertEqual(merged.scores.first?.confidence ?? 0, 0.95, accuracy: 0.0001)
        XCTAssertEqual(merged.bucket, .autoAssign)
    }
}
