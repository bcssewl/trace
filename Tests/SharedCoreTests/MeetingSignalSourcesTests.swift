import XCTest

@testable import SharedCore

final class MeetingSignalSourcesTests: XCTestCase {

    // MARK: - isMeetingURL (pure)

    func testMeetingURLsAreMatched() {
        let positives = [
            "https://meet.google.com/abc-defg-hij",
            "https://meet.google.com/",
            "https://hangouts.google.com/call/x",
            "https://app.zoom.us/wc/123456/join",
            "https://us02web.zoom.us/j/9999",
            "https://zoom.us/j/12345",
            "https://example.zoom.com/wc/1",
            "https://teams.microsoft.com/l/meetup-join/19:abc",
            "https://teams.live.com/meet/123",
            "https://app.slack.com/huddle/T123/C456",
            "https://app.slack.com/client/T1/calls/X",
            "https://company.whereby.com/room",
            "https://acme.webex.com/meet/jane",
            "https://global.gotomeeting.com/join/123",
            "https://acme.bluejeans.com/123456",
        ]
        for url in positives {
            XCTAssertTrue(MeetingURLClassifier.isMeetingURL(url), "expected meeting URL: \(url)")
            XCTAssertTrue(AppleScriptBrowserTabURLReader.isMeetingURL(url), "reader.isMeetingURL: \(url)")
        }
    }

    func testNonMeetingURLsAreRejected() {
        let negatives = [
            "https://google.com/search?q=zoom",
            "https://www.google.com",
            "https://mail.google.com/mail/u/0",
            "https://github.com/anthropic",
            "https://news.ycombinator.com",
            "https://app.slack.com/client/T1/C2",  // Slack but not a huddle/call
            "https://zoominfo.com/company",  // not zoom.us / zoom.com
            "https://notzoom.us.evil.com",  // host is evil.com, not zoom.us
            "https://teams.microsoft.com.evil.com",  // host is evil.com
            "",
            "not a url at all",
        ]
        for url in negatives {
            XCTAssertFalse(MeetingURLClassifier.isMeetingURL(url), "expected NON-meeting URL: \(url)")
        }
    }

    func testIsMeetingURLIsCaseInsensitiveOnHost() {
        XCTAssertTrue(MeetingURLClassifier.isMeetingURL("HTTPS://MEET.GOOGLE.COM/ABC"))
        XCTAssertTrue(MeetingURLClassifier.isMeetingURL("https://US02WEB.ZOOM.US/j/1"))
    }

    func testSchemelessMeetingURLStillMatches() {
        XCTAssertTrue(MeetingURLClassifier.isMeetingURL("meet.google.com/abc-defg-hij"))
        XCTAssertTrue(MeetingURLClassifier.isMeetingURL("app.zoom.us/wc/1/join"))
    }

    // MARK: - MeetingAppCatalog

    func testMeetingAppCatalogClassifiesKnownApps() {
        XCTAssertTrue(MeetingAppCatalog.isMeetingApp("us.zoom.xos"))
        XCTAssertTrue(MeetingAppCatalog.isMeetingApp("com.microsoft.teams2"))
        XCTAssertTrue(MeetingAppCatalog.isMeetingApp("com.tinyspeck.slackmacgap"))
        XCTAssertTrue(MeetingAppCatalog.isMeetingApp("com.apple.FaceTime"))
        XCTAssertTrue(MeetingAppCatalog.isMeetingApp("com.hnc.Discord"))

        XCTAssertFalse(MeetingAppCatalog.isMeetingApp("com.apple.Safari"))
        XCTAssertFalse(MeetingAppCatalog.isMeetingApp("com.apple.finder"))
        XCTAssertFalse(MeetingAppCatalog.isMeetingApp(""))
    }

    func testMeetingAppCatalogClassifiesBrowsers() {
        XCTAssertTrue(MeetingAppCatalog.isBrowser("com.apple.Safari"))
        XCTAssertTrue(MeetingAppCatalog.isBrowser("com.google.Chrome"))
        XCTAssertTrue(MeetingAppCatalog.isBrowser("company.thebrowser.Browser"))
        XCTAssertTrue(MeetingAppCatalog.isBrowser("com.brave.Browser"))
        XCTAssertTrue(MeetingAppCatalog.isBrowser("com.microsoft.edgemac"))

        XCTAssertFalse(MeetingAppCatalog.isBrowser("us.zoom.xos"))
        XCTAssertFalse(MeetingAppCatalog.isBrowser(""))
    }

    // MARK: - AppleScript source mapping (pure)

    func testScriptSourceForSupportedBrowsers() {
        XCTAssertNotNil(AppleScriptBrowserTabURLReader.scriptSource(forBrowserBundleID: "com.apple.Safari"))
        XCTAssertNotNil(AppleScriptBrowserTabURLReader.scriptSource(forBrowserBundleID: "com.google.Chrome"))
        XCTAssertNotNil(AppleScriptBrowserTabURLReader.scriptSource(forBrowserBundleID: "company.thebrowser.Browser"))
        XCTAssertNotNil(AppleScriptBrowserTabURLReader.scriptSource(forBrowserBundleID: "com.brave.Browser"))
        XCTAssertNotNil(AppleScriptBrowserTabURLReader.scriptSource(forBrowserBundleID: "com.microsoft.edgemac"))

        // Firefox and unknowns are not scriptable for URLs.
        XCTAssertNil(AppleScriptBrowserTabURLReader.scriptSource(forBrowserBundleID: "org.mozilla.firefox"))
        XCTAssertNil(AppleScriptBrowserTabURLReader.scriptSource(forBrowserBundleID: "com.unknown.app"))
    }

    // MARK: - Browser reader: non-browser frontmost yields nil without running AppleScript

    func testBrowserReaderReturnsNilForNonBrowserFrontmost() async {
        let reader = AppleScriptBrowserTabURLReader()
        let result = await reader.activeBrowserTab(frontmostBundleID: "us.zoom.xos")
        XCTAssertNil(result)
    }

    // MARK: - Live source: protocol conformance + no crash in headless env

    func testLiveSourceConformsAndDoesNotCrash() async {
        let source: any MeetingSignalSourcing = LiveMeetingSignalSource()
        // Results are environment-dependent (may be empty in CI); the contract is
        // only that this never throws or crashes.
        let signals = await source.currentSignals()
        XCTAssertTrue(signals.isSubset(of: Set(MeetingActivitySignal.allCases)))
    }

    func testLiveSourceWithStubBrowserReaderReportsBrowserTab() async {
        let stub = StubBrowserReader(
            result: BrowserTabSignal(
                browserBundleID: "com.google.Chrome",
                url: "https://meet.google.com/xyz"))
        // Pin the mic probe live: the browserTab signal is mic-gated (a real
        // call always opens the input device), and the real CoreAudio probe
        // would make this test depend on the machine's actual mic state.
        let source = LiveMeetingSignalSource(browserReader: stub, micActiveProbe: { true })
        let signals = await source.currentSignals()
        // The stub always returns a meeting URL regardless of frontmost app, so
        // the browserTab signal must be present.
        XCTAssertTrue(signals.contains(.browserTab))
    }

    func testLiveSourceWithMicIdleSuppressesBrowserTab() async {
        let stub = StubBrowserReader(
            result: BrowserTabSignal(
                browserBundleID: "com.google.Chrome",
                url: "https://meet.google.com/xyz"))
        // Mic idle → a meeting tab merely being open must NOT read as a call.
        let source = LiveMeetingSignalSource(browserReader: stub, micActiveProbe: { false })
        let signals = await source.currentSignals()
        XCTAssertFalse(signals.contains(.browserTab))
    }

    func testLiveSourceWithNilBrowserReaderHasNoBrowserTab() async {
        let stub = StubBrowserReader(result: nil)
        let source = LiveMeetingSignalSource(browserReader: stub)
        let signals = await source.currentSignals()
        XCTAssertFalse(signals.contains(.browserTab))
    }

    // MARK: - CoreAudio probes do not crash (results may be false headless)

    func testCoreAudioProbesDoNotCrash() {
        _ = LiveMeetingSignalSource.defaultInputDeviceIsRunningSomewhere()
        _ = LiveMeetingSignalSource.defaultOutputDeviceIsRunningSomewhere()
        _ = LiveMeetingSignalSource.frontmostBundleID()
    }
}

// MARK: - Test doubles

/// A `BrowserTabReading` stub that ignores the frontmost app and returns a fixed
/// result, so browser-tab signal logic can be tested without AppleScript.
private struct StubBrowserReader: BrowserTabReading {
    let result: BrowserTabSignal?
    func activeBrowserTab(frontmostBundleID: String) async -> BrowserTabSignal? {
        result
    }
}
