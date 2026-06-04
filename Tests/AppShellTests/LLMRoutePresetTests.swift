import SharedCore
import XCTest

@testable import AppShell

/// BAS-6 / BAS-35 — the LLM Router "Advanced" panel is real: every LLM task
/// class routes from a generalized stage (including the two previously-unwired
/// coach stages), and the routing presets apply a whole route-set across stages.
///
/// Every persisted provider/model key across all route stages — file-scope so
/// the nonisolated XCTest setUp/tearDown can clear them without an actor hop.
private func bas635RouteKeys() -> [String] {
    LLMRouteStage.allCases.flatMap { [$0.providerKey, $0.modelsKey] }
}

@MainActor
final class LLMRoutePresetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        for key in bas635RouteKeys() { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in bas635RouteKeys() { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    // MARK: coach stages (BAS-35 — the previously-unwired task classes)

    func testCoachStagesWired() {
        XCTAssertEqual(LLMRouteStage.coachSmartRouting.taskClasses, [.coachSmartRouting])
        XCTAssertEqual(LLMRouteStage.coachCardContent.taskClasses, [.coachCardContent])
        XCTAssertEqual(LLMRouteStage.coachSmartRouting.providerKey, "app.trace.coach.smartRoutingProvider")
        XCTAssertEqual(LLMRouteStage.coachCardContent.providerKey, "app.trace.coach.cardContentProvider")
        XCTAssertEqual(LLMRouteStage.coachSmartRouting.configChangedNotification, .traceCoachConfigChanged)
        XCTAssertEqual(LLMRouteStage.coachCardContent.configChangedNotification, .traceCoachConfigChanged)
        XCTAssertEqual(LLMRouteStage.coachSmartRouting.offeredProviders, [.appleFM, .ollama])
        let state = AppStateModel()
        XCTAssertEqual(state.provider(for: .coachSmartRouting), .appleFM, "coach routing defaults local")
        XCTAssertEqual(state.provider(for: .coachCardContent), .appleFM, "coach card content defaults local")
    }

    func testEveryLLMTaskClassIsRoutableFromSomeStage() {
        let covered = Set(LLMRouteStage.allCases.flatMap(\.taskClasses))
        XCTAssertEqual(
            covered, Set(LLMTaskClass.allCases),
            "every LLM task class must be routable from a stage in the Advanced table")
    }

    // MARK: presets

    func testPresetProvidersRespectOfferedProviders() {
        // With every cloud credential present a stage offers its full provider set
        // (locals + all keyed cloud providers); no preset may assign a provider
        // outside it. (Cloud providers are gated out of `offeredProviders` until
        // keyed, so the preset check is against the fully-connected everyday set.)
        let allConnected = Set(ModelProvider.keyedCloudProviders)
        for preset in LLMRoutePreset.allCases {
            for stage in LLMRouteStage.allCases {
                XCTAssertTrue(
                    stage.everydayProviders(connected: allConnected).contains(preset.provider(for: stage)),
                    "\(preset.rawValue) assigns \(preset.provider(for: stage).rawValue) to \(stage.rawValue), not in its offered set"
                )
            }
        }
    }

    func testLocalFirstIsAllLocal() {
        for stage in LLMRouteStage.allCases {
            XCTAssertNotEqual(
                LLMRoutePreset.localFirst.provider(for: stage), .openRouter,
                "Local-first must never route \(stage.rawValue) to the cloud")
        }
    }

    func testLocalFirstMatchesShippedDefaults() {
        // Local-first must equal the all-local defaults so a fresh install reads
        // as "Local-first", not "Custom".
        for stage in LLMRouteStage.allCases {
            XCTAssertEqual(
                LLMRoutePreset.localFirst.provider(for: stage), stage.defaultProvider,
                "Local-first diverges from the default for \(stage.rawValue)")
        }
    }

    func testCloudHeavyRoutesGenerativeStagesToCloud() {
        XCTAssertEqual(LLMRoutePreset.cloudHeavy.provider(for: .meetingNotes), .openRouter)
        XCTAssertEqual(LLMRoutePreset.cloudHeavy.provider(for: .libraryQA), .openRouter)
        XCTAssertEqual(LLMRoutePreset.cloudHeavy.provider(for: .coachCardContent), .openRouter)
    }

    func testApplyPresetSetsAndPersistsEveryStage() {
        let state = AppStateModel()
        state.applyRoutePreset(.cloudHeavy)
        for stage in LLMRouteStage.allCases {
            XCTAssertEqual(state.provider(for: stage), LLMRoutePreset.cloudHeavy.provider(for: stage))
        }
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: LLMRouteStage.meetingNotes.providerKey),
            DictationCleanupProvider.openRouter.rawValue,
            "applying a preset persists each stage provider"
        )
    }

    func testActivePresetDetection() {
        let state = AppStateModel()
        // A fresh install (all defaults) reads as Local-first.
        XCTAssertEqual(state.activeRoutePreset, .localFirst)
        state.applyRoutePreset(.cloudHeavy)
        XCTAssertEqual(state.activeRoutePreset, .cloudHeavy)
        // A manual deviation from any preset → Custom (nil).
        state.setProvider(.ollama, for: .meetingTitle)
        XCTAssertNil(state.activeRoutePreset)
    }
}
