import XCTest

@testable import SharedCore

final class BridgesAppActivityMonitorTests: XCTestCase {
    func testAnyTwoSignalsForFiveSecondsStartsMeeting() {
        var reducer = MeetingActivityReducer(config: .default)
        XCTAssertNil(reducer.ingest(.init(time: 0, active: [.appLaunch])))
        XCTAssertNil(reducer.ingest(.init(time: 1, active: [.appLaunch, .systemAudioEnergy])))
        XCTAssertNil(reducer.ingest(.init(time: 5.9, active: [.appLaunch, .systemAudioEnergy])))

        let event = reducer.ingest(.init(time: 6.1, active: [.appLaunch, .systemAudioEnergy]))
        XCTAssertEqual(event, .meetingLikelyStarted)
    }

    func testDisabledSignalDoesNotCount() {
        var config = MeetingActivityConfig.default
        config.enabledSignals.remove(.browserTab)
        var reducer = MeetingActivityReducer(config: config)

        XCTAssertNil(reducer.ingest(.init(time: 0, active: [.browserTab, .micActivity])))
        XCTAssertNil(reducer.ingest(.init(time: 6, active: [.browserTab, .micActivity])))
    }

    func testGapResetsTimer() {
        var reducer = MeetingActivityReducer(config: .default)
        XCTAssertNil(reducer.ingest(.init(time: 0, active: [.appLaunch, .micActivity])))
        XCTAssertNil(reducer.ingest(.init(time: 2, active: [.appLaunch])))
        XCTAssertNil(reducer.ingest(.init(time: 3, active: [.appLaunch, .micActivity])))
        XCTAssertNil(reducer.ingest(.init(time: 7, active: [.appLaunch, .micActivity])))
    }

    func testBrowserTabSignalMeetingURLDetection() {
        XCTAssertTrue(
            BrowserTabSignal(browserBundleID: "com.apple.Safari", url: "https://meet.google.com/abc").isMeetingURL)
        XCTAssertTrue(
            BrowserTabSignal(browserBundleID: "com.apple.Safari", url: "https://app.zoom.us/wc/1").isMeetingURL)
        XCTAssertTrue(
            BrowserTabSignal(browserBundleID: "com.apple.Safari", url: "https://teams.microsoft.com/x").isMeetingURL)
        XCTAssertFalse(BrowserTabSignal(browserBundleID: "com.apple.Safari", url: "https://google.com").isMeetingURL)
    }
}
