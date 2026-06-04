import XCTest

@testable import AppShell

/// `DiarizationActivation` is the single rule that decides whether a meeting
/// runs speaker diarization.
///
/// It must collapse to the standard You / Others
/// behavior unless the (beta) feature is explicitly on AND the on-device models
/// are confirmed ready — so a not-ready or disabled state never half-runs.
final class DiarizationActivationTests: XCTestCase {

    func testFeatureOffDisablesEverything() {
        let a = DiarizationActivation.resolve(
            featureEnabled: false, modelsReady: true, liveEnabled: true, offlineEnabled: true
        )
        XCTAssertFalse(a.useLive)
        XCTAssertFalse(a.useOffline)
    }

    func testModelsNotReadyFallsBackToYouOthersEvenWhenFeatureOn() {
        let a = DiarizationActivation.resolve(
            featureEnabled: true, modelsReady: false, liveEnabled: true, offlineEnabled: true
        )
        XCTAssertFalse(a.useLive, "no labeling until models are ready")
        XCTAssertFalse(a.useOffline, "no recording/refinement until models are ready")
    }

    func testFeatureOnAndReadyMirrorsSubToggles() {
        XCTAssertEqual(
            DiarizationActivation.resolve(
                featureEnabled: true, modelsReady: true, liveEnabled: true, offlineEnabled: false
            ),
            DiarizationActivation(useLive: true, useOffline: false)
        )
        XCTAssertEqual(
            DiarizationActivation.resolve(
                featureEnabled: true, modelsReady: true, liveEnabled: false, offlineEnabled: true
            ),
            DiarizationActivation(useLive: false, useOffline: true)
        )
        XCTAssertEqual(
            DiarizationActivation.resolve(
                featureEnabled: true, modelsReady: true, liveEnabled: true, offlineEnabled: true
            ),
            DiarizationActivation(useLive: true, useOffline: true)
        )
    }

    /// Whether *any* model needs preparing (drives the background prepare): only
    /// when the feature is on and at least one sub-pass is enabled.
    func testNeedsModelsReflectsEnabledSubPasses() {
        XCTAssertTrue(DiarizationActivation.needsModels(featureEnabled: true, liveEnabled: true, offlineEnabled: false))
        XCTAssertTrue(DiarizationActivation.needsModels(featureEnabled: true, liveEnabled: false, offlineEnabled: true))
        XCTAssertFalse(
            DiarizationActivation.needsModels(featureEnabled: false, liveEnabled: true, offlineEnabled: true))
        XCTAssertFalse(
            DiarizationActivation.needsModels(featureEnabled: true, liveEnabled: false, offlineEnabled: false))
    }
}
