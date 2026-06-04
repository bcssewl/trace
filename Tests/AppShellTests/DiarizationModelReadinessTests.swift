import XCTest

@testable import AppShell

/// `DiarizationModelReadiness` is the observable gate the rest of the app checks
/// before turning on speaker diarization for a meeting.
///
/// It seeds from a
/// persisted "prepared before" flag (the on-device model cache survives
/// launches), and `ready` is sticky so a late re-prepare can't briefly demote a
/// meeting back to You / Others mid-session.
@MainActor
final class DiarizationModelReadinessTests: XCTestCase {

    func testSeedsReadyFromPriorPreparation() {
        XCTAssertTrue(DiarizationModelReadiness(preparedBefore: true).isReady)
        XCTAssertFalse(DiarizationModelReadiness(preparedBefore: false).isReady)
    }

    func testPreparingThenReady() {
        let r = DiarizationModelReadiness(preparedBefore: false)
        XCTAssertEqual(r.status, .unprepared)

        r.markPreparing()
        XCTAssertEqual(r.status, .preparing)
        XCTAssertFalse(r.isReady)

        r.markReady()
        XCTAssertEqual(r.status, .ready)
        XCTAssertTrue(r.isReady)
    }

    func testReadyIsSticky() {
        let r = DiarizationModelReadiness(preparedBefore: false)
        r.markReady()
        // A later prepare attempt or failure must not demote an already-ready gate.
        r.markPreparing()
        XCTAssertTrue(r.isReady)
        r.markFailed()
        XCTAssertTrue(r.isReady)
    }

    func testFailureFromPreparing() {
        let r = DiarizationModelReadiness(preparedBefore: false)
        r.markPreparing()
        r.markFailed()
        XCTAssertEqual(r.status, .failed)
        XCTAssertFalse(r.isReady)
    }
}
