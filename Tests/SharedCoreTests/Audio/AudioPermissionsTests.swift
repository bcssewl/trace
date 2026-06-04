@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class AudioPermissionsTests: XCTestCase {

    func testCurrentMicStatusMaps() {
        let status = AudioPermissions.currentMicStatus()
        switch status {
        case .notDetermined, .granted, .denied, .restricted:
            break
        }
    }

    func testMapAvCaptureToOurStatus() {
        XCTAssertEqual(AudioPermissions.mapStatus(.notDetermined), .notDetermined)
        XCTAssertEqual(AudioPermissions.mapStatus(.authorized), .granted)
        XCTAssertEqual(AudioPermissions.mapStatus(.denied), .denied)
        XCTAssertEqual(AudioPermissions.mapStatus(.restricted), .restricted)
    }
}
