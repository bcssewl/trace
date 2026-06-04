@preconcurrency import CoreAudio
import XCTest

@testable import SharedCore

final class DeviceWatcherTests: XCTestCase {

    func testCurrentDefaultsAreFetchable() throws {
        let inID = try DeviceWatcher.currentDefaultInputDeviceID()
        let outID = try DeviceWatcher.currentDefaultOutputDeviceID()
        XCTAssertNotEqual(inID, kAudioObjectUnknown)
        XCTAssertNotEqual(outID, kAudioObjectUnknown)
    }

    func testStopIsIdempotent() throws {
        let watcher = DeviceWatcher()
        try watcher.start()
        watcher.stop()
        watcher.stop()
    }

    func testDeviceNameLookupReturnsString() throws {
        let id = try DeviceWatcher.currentDefaultInputDeviceID()
        let name = try DeviceWatcher.deviceName(for: id)
        XCTAssertFalse(name.isEmpty)
    }
}
