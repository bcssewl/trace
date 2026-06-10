import Foundation
import XCTest

@testable import CoachModule
@testable import SharedCore

final class CoachModuleTests: XCTestCase {
    func testModuleNameIsCorrect() {
        XCTAssertEqual(CoachModule.moduleName, "CoachModule")
    }
}

final class CoachConfigCodableTests: XCTestCase {
    func testDefaults() {
        let cfg = CoachConfig()
        XCTAssertTrue(cfg.enabled)
        XCTAssertEqual(cfg.surfaceBudget, 4)
        XCTAssertEqual(cfg.surfaceWindowMinutes, 15)
        XCTAssertEqual(cfg.checkCadenceSeconds, 20)
        XCTAssertTrue(cfg.manualTrigger.enabled)
    }

    /// A config persisted by the OLD pipeline build — mode toggles, throttle,
    /// anti-fabrication, conversation-state ticker, concurrency cap — must still
    /// decode: known fields read, removed fields ignored, new fields defaulted.
    /// Failing to decode would silently reset the user's whole Coach config.
    func testDecodesOldPipelineJSONWithRemovedFields() throws {
        let legacy = """
            {"enabled":true,"surfaceBudget":5,"adaptiveThrottle":false,"antiFabricationPostCheck":true,
             "modes":{"grounded":false,"synthesized":true,"general":true,"reframe":true,"pacing":true,"agenda":true},
             "conversationStateEnabled":true,"conversationStateIntervalSeconds":45,"maxConcurrentIngests":3,
             "manualTrigger":{"enabled":true,"modifierKeyCode":54,"tapCount":4,"windowMilliseconds":700}}
            """
        let cfg = try JSONDecoder().decode(CoachConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(cfg.enabled)
        XCTAssertEqual(cfg.surfaceBudget, 5)
        XCTAssertEqual(cfg.checkCadenceSeconds, 20, "missing new field must default")
        XCTAssertEqual(cfg.surfaceWindowMinutes, 15, "missing new field must default")
        XCTAssertEqual(cfg.manualTrigger.modifierKeyCode, 54)
        XCTAssertEqual(cfg.manualTrigger.tapCount, 4)
        XCTAssertEqual(cfg.manualTrigger.windowMilliseconds, 700)
    }

    /// A config persisted by the LIFETIME-BUDGET listener build (it had
    /// `surfaceBudget` and `checkCadenceSeconds` but no `surfaceWindowMinutes`)
    /// must decode with the window defaulted — the user's stored budget and
    /// cadence survive untouched.
    func testDecodesPreWindowJSONWithoutSurfaceWindowMinutes() throws {
        let preWindow = """
            {"enabled":true,"surfaceBudget":8,"checkCadenceSeconds":25,
             "manualTrigger":{"enabled":true,"modifierKeyCode":61,"tapCount":3,"windowMilliseconds":500}}
            """
        let cfg = try JSONDecoder().decode(CoachConfig.self, from: Data(preWindow.utf8))
        XCTAssertEqual(cfg.surfaceBudget, 8, "the stored budget is preserved")
        XCTAssertEqual(cfg.checkCadenceSeconds, 25)
        XCTAssertEqual(cfg.surfaceWindowMinutes, 15, "the absent window falls back to the default")
    }

    /// Unknown keys — past (removed features) or future (fields this build
    /// doesn't know) — are ignored ON PURPOSE; known fields decode unaffected.
    func testUnknownKeysAreIgnoredOnPurpose() throws {
        let json = """
            {"enabled":false,"surfaceBudget":3,"checkCadenceSeconds":30,
             "someFutureTopLevelKey":42,"modes":{"grounded":true}}
            """
        let cfg = try JSONDecoder().decode(CoachConfig.self, from: Data(json.utf8))
        XCTAssertFalse(cfg.enabled)
        XCTAssertEqual(cfg.surfaceBudget, 3)
        XCTAssertEqual(cfg.checkCadenceSeconds, 30)
    }

    func testRoundTrips() throws {
        var cfg = CoachConfig()
        cfg.enabled = false
        cfg.surfaceBudget = 12
        cfg.surfaceWindowMinutes = 25
        cfg.checkCadenceSeconds = 40
        cfg.manualTrigger.tapCount = 2
        let decoded = try JSONDecoder().decode(CoachConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(decoded, cfg)
    }

    /// The cadence floor is a safety rail against a bad persisted value — each
    /// check is a paid cloud call.
    func testCadenceFloorClampsAtUse() throws {
        let json = #"{"checkCadenceSeconds":1}"#
        let cfg = try JSONDecoder().decode(CoachConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.checkCadenceSeconds, 1, "the stored value is preserved")
        XCTAssertEqual(cfg.effectiveCheckCadenceSeconds, 10, "the effective value is clamped")
    }

    /// A zero/negative persisted window would mean no card ever counts against
    /// the rolling budget — the floor clamps it at the point of use.
    func testSurfaceWindowFloorClampsAtUse() throws {
        let json = #"{"surfaceWindowMinutes":0}"#
        let cfg = try JSONDecoder().decode(CoachConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.surfaceWindowMinutes, 0, "the stored value is preserved")
        XCTAssertEqual(cfg.effectiveSurfaceWindowMinutes, 1, "the effective value is clamped")
    }
}
