import XCTest

@testable import SharedCore

final class TraceErrorTests: XCTestCase {
    func testModuleNameIsCorrect() {
        XCTAssertEqual(SharedCore.moduleName, "SharedCore")
    }

    func testAudioCaptureErrorHasLocalizedDescription() {
        let err = TraceError.audioCaptureFailed(reason: "device unplugged")
        XCTAssertEqual(err.localizedDescription, "Audio capture failed: device unplugged")
        XCTAssertEqual(err.category, .audio)
    }

    func testModelProviderErrorWraps() {
        let underlying = NSError(domain: "test", code: 42, userInfo: nil)
        let err = TraceError.modelProviderFailed(provider: "appleFM", underlying: underlying)
        XCTAssertTrue(err.localizedDescription.contains("appleFM"))
        XCTAssertEqual(err.category, .model)
    }

    func testPermissionErrorIsRecoverable() {
        let err = TraceError.permissionDenied(kind: .microphone)
        XCTAssertTrue(err.isRecoverable)
        XCTAssertEqual(err.recoveryAction, .openSystemSettings(pane: "Privacy_Microphone"))
    }

    func testStorageErrorNonRecoverable() {
        let err = TraceError.storageFailed(reason: "disk full")
        XCTAssertFalse(err.isRecoverable)
    }
}
