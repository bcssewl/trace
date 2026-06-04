@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class MicCaptureTests: XCTestCase {

    private var isMicAvailable: Bool {
        guard AVCaptureDevice.default(for: .audio) != nil else { return false }
        return AudioPermissions.currentMicStatus() == .granted
    }

    func testStartStopIsIdempotent() throws {
        try XCTSkipIf(!isMicAvailable, "Real mic not available")
        let capture = MicCapture()
        try capture.start()
        try capture.start()
        capture.stop()
        capture.stop()
    }

    func testDiagnosticsExposesState() throws {
        let capture = MicCapture()
        let diag = capture.diagnostics()
        XCTAssertFalse(diag.isRunning)
        XCTAssertEqual(diag.framesObserved, 0)
    }
}
