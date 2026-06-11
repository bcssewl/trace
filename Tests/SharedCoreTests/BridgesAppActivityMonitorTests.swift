import XCTest

@testable import SharedCore

final class BridgesAppActivityMonitorTests: XCTestCase {
    func testTwoSignalsWithStrongAppStartMeetingAfterStableDuration() {
        var reducer = MeetingActivityReducer(config: .default)
        XCTAssertNil(reducer.ingest(.init(time: 0, active: [.appLaunch])))
        XCTAssertNil(reducer.ingest(.init(time: 1, active: [.appLaunch, .systemAudioEnergy])))
        XCTAssertNil(reducer.ingest(.init(time: 2.9, active: [.appLaunch, .systemAudioEnergy])))

        let event = reducer.ingest(.init(time: 3.1, active: [.appLaunch, .systemAudioEnergy]))
        XCTAssertEqual(event, .meetingLikelyStarted(strongSignal: true))
    }

    func testDisabledSignalDoesNotCount() {
        var config = MeetingActivityConfig.default
        config.enabledSignals.remove(.browserTab)
        config.weakSignalStableDuration = nil
        var reducer = MeetingActivityReducer(config: config)

        XCTAssertNil(reducer.ingest(.init(time: 0, active: [.browserTab, .micActivity])))
        XCTAssertNil(reducer.ingest(.init(time: 6, active: [.browserTab, .micActivity])))
    }

    func testGapResetsTimer() {
        var reducer = MeetingActivityReducer(config: .default)
        XCTAssertNil(reducer.ingest(.init(time: 0, active: [.appLaunch, .micActivity])))
        XCTAssertNil(reducer.ingest(.init(time: 1, active: [.appLaunch])))
        XCTAssertNil(reducer.ingest(.init(time: 2, active: [.appLaunch, .micActivity])))
        XCTAssertNil(reducer.ingest(.init(time: 3.9, active: [.appLaunch, .micActivity])))
        XCTAssertEqual(
            reducer.ingest(.init(time: 4.1, active: [.appLaunch, .micActivity])),
            .meetingLikelyStarted(strongSignal: true)
        )
    }

    /// Audio-only fallback: mic + system audio with NO recognised app fires
    /// after the (longer) weak window — calls on unlisted platforms are caught.
    func testWeakSignalsFireAfterWeakStableDuration() {
        var reducer = MeetingActivityReducer(config: .default)
        XCTAssertNil(reducer.ingest(.init(time: 0, active: [.micActivity, .systemAudioEnergy])))
        XCTAssertNil(reducer.ingest(.init(time: 5, active: [.micActivity, .systemAudioEnergy])))
        XCTAssertNil(reducer.ingest(.init(time: 11.9, active: [.micActivity, .systemAudioEnergy])))

        let event = reducer.ingest(.init(time: 12.1, active: [.micActivity, .systemAudioEnergy]))
        XCTAssertEqual(event, .meetingLikelyStarted(strongSignal: false))
    }

    /// Weak fallback disabled → audio-only signals never fire (pre-existing
    /// strong-signal-only behaviour).
    func testWeakSignalsNeverFireWhenFallbackDisabled() {
        var config = MeetingActivityConfig.default
        config.weakSignalStableDuration = nil
        var reducer = MeetingActivityReducer(config: config)
        XCTAssertNil(reducer.ingest(.init(time: 0, active: [.micActivity, .systemAudioEnergy])))
        XCTAssertNil(reducer.ingest(.init(time: 60, active: [.micActivity, .systemAudioEnergy])))
    }

    /// A strong signal seen once keeps the FAST path armed even after the
    /// meeting app leaves the foreground (the user tabs over to their notes):
    /// the span continues on audio signals alone and still fires as strong.
    func testStrongSignalSurvivesAppLeavingForeground() {
        var reducer = MeetingActivityReducer(config: .default)
        XCTAssertNil(reducer.ingest(.init(time: 0, active: [.appLaunch, .micActivity])))
        XCTAssertNil(reducer.ingest(.init(time: 1, active: [.micActivity, .systemAudioEnergy])))

        let event = reducer.ingest(.init(time: 2.1, active: [.micActivity, .systemAudioEnergy]))
        XCTAssertEqual(event, .meetingLikelyStarted(strongSignal: true))
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
