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

    // MARK: coach stage (cloud-only listener redesign)

    /// The coach is ONE stage now (`.coachCardContent`), cloud-only:
    /// - it defaults to OpenRouter (the catalogue default model),
    /// - its picker offers NO local providers (only connected clouds), and
    /// - `.coachSmartRouting` is retired: kept as a case for persistence
    ///   compatibility, excluded from the user-configurable stage list.
    func testCoachStageIsCloudOnly() {
        XCTAssertEqual(LLMRouteStage.coachCardContent.taskClasses, [.coachCardContent])
        XCTAssertEqual(LLMRouteStage.coachCardContent.providerKey, "app.trace.coach.cardContentProvider")
        XCTAssertEqual(LLMRouteStage.coachCardContent.configChangedNotification, .traceCoachConfigChanged)
        XCTAssertEqual(LLMRouteStage.coachCardContent.defaultProvider, .openRouter)
        XCTAssertEqual(LLMRouteStage.coachCardContent.offeredProviders, [], "no always-on local providers")
        // The everyday picker list is exactly the CONNECTED cloud set.
        XCTAssertEqual(LLMRouteStage.coachCardContent.everydayProviders(connected: []), [])
        XCTAssertEqual(
            LLMRouteStage.coachCardContent.everydayProviders(connected: [.openRouter, .anthropic]),
            [.openRouter, .anthropic]
        )
        let state = AppStateModel()
        XCTAssertEqual(state.provider(for: .coachCardContent), .openRouter, "cloud catalogue default")
        XCTAssertEqual(
            state.model(for: .coachCardContent, provider: .openRouter), "google/gemini-3.1-flash-lite",
            "OpenRouter's catalogue default model")
    }

    func testCoachSmartRoutingIsRetired() {
        XCTAssertTrue(LLMRouteStage.allCases.contains(.coachSmartRouting), "case kept for persistence")
        XCTAssertFalse(
            LLMRouteStage.userConfigurable.contains(.coachSmartRouting),
            "retired: not offered anywhere user-facing")
        XCTAssertEqual(
            Set(LLMRouteStage.userConfigurable + [.coachSmartRouting]), Set(LLMRouteStage.allCases),
            "userConfigurable is allCases minus exactly the retired stage")
    }

    /// A coach provider persisted by the OLD build (Apple FM / Ollama) coerces
    /// to the cloud default on restore — the coach can't run locally, so an
    /// upgrade must land on a runnable route instead of a guaranteed refusal.
    func testCoachLocalProviderCoercesToCloudOnRestore() {
        UserDefaults.standard.set(
            DictationCleanupProvider.appleFM.rawValue, forKey: LLMRouteStage.coachCardContent.providerKey)
        let state = AppStateModel()
        XCTAssertEqual(state.provider(for: .coachCardContent), .openRouter)
        // A persisted CLOUD choice is kept.
        UserDefaults.standard.set(
            DictationCleanupProvider.anthropic.rawValue, forKey: LLMRouteStage.coachCardContent.providerKey)
        let state2 = AppStateModel()
        XCTAssertEqual(state2.provider(for: .coachCardContent), .anthropic)
    }

    func testEveryLLMTaskClassIsRoutableFromSomeStage() {
        let covered = Set(LLMRouteStage.allCases.flatMap(\.taskClasses))
        XCTAssertEqual(
            covered, Set(LLMTaskClass.allCases),
            "every LLM task class must be routable from a stage (the retired one included, for persistence)")
    }

    // MARK: presets

    func testPresetProvidersRespectOfferedProviders() {
        // With every cloud credential present a stage offers its full provider set
        // (locals + all keyed cloud providers); no preset may assign a provider
        // outside it. (Cloud providers are gated out of `offeredProviders` until
        // keyed, so the preset check is against the fully-connected everyday set.)
        let allConnected = Set(ModelProvider.keyedCloudProviders)
        for preset in LLMRoutePreset.allCases {
            for stage in LLMRouteStage.userConfigurable {
                XCTAssertTrue(
                    stage.everydayProviders(connected: allConnected).contains(preset.provider(for: stage)),
                    "\(preset.rawValue) assigns \(preset.provider(for: stage).rawValue) to \(stage.rawValue), not in its offered set"
                )
            }
        }
    }

    func testLocalFirstIsAllLocalExceptTheCloudOnlyCoach() {
        for stage in LLMRouteStage.userConfigurable where stage != .coachCardContent {
            XCTAssertNotEqual(
                LLMRoutePreset.localFirst.provider(for: stage), .openRouter,
                "Local-first must never route \(stage.rawValue) to the cloud")
        }
        // The coach is cloud-only by design — even Local-first leaves it on
        // OpenRouter (it is opt-in/off by default, so nothing calls out).
        XCTAssertEqual(LLMRoutePreset.localFirst.provider(for: .coachCardContent), .openRouter)
    }

    func testLocalFirstMatchesShippedDefaults() {
        // Local-first must equal the shipped defaults so a fresh install reads
        // as "Local-first", not "Custom".
        for stage in LLMRouteStage.userConfigurable {
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

    func testApplyPresetSetsAndPersistsEveryConfigurableStage() {
        let state = AppStateModel()
        state.applyRoutePreset(.cloudHeavy)
        for stage in LLMRouteStage.userConfigurable {
            XCTAssertEqual(state.provider(for: stage), LLMRoutePreset.cloudHeavy.provider(for: stage))
        }
        // The retired stage is untouched by presets.
        XCTAssertNil(UserDefaults.standard.string(forKey: LLMRouteStage.coachSmartRouting.providerKey))
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
