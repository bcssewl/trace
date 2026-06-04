import XCTest

@testable import AppShell

/// BAS-24 — the persisted state behind the newly-wired Settings tabs (Updates,
/// Calendar) + the About "Re-run setup" reset.
@MainActor
final class SettingsTabsStateTests: XCTestCase {
    private let keys = [
        "app.trace.updates.autoEnabled",
        "app.trace.updates.channel",
        "app.trace.meeting.calendarEnabled",
        "app.trace.meeting.calendarWindowMinutes",
        "app.trace.onboardingComplete",
    ]

    override func setUp() {
        super.setUp()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    func testUpdateAndCalendarDefaults() {
        let state = AppStateModel()
        XCTAssertTrue(state.autoUpdatesEnabled)
        XCTAssertEqual(state.updateChannel, "Stable")
        XCTAssertTrue(state.meetingCalendarEnabled)
        XCTAssertEqual(state.meetingCalendarWindowMinutes, 15)
    }

    func testUpdateAndCalendarPrefsPersistAndRestore() {
        let state = AppStateModel()
        state.autoUpdatesEnabled = false
        state.updateChannel = "Beta"
        state.meetingCalendarEnabled = false
        state.meetingCalendarWindowMinutes = 30

        let restored = AppStateModel()
        XCTAssertFalse(restored.autoUpdatesEnabled)
        XCTAssertEqual(restored.updateChannel, "Beta")
        XCTAssertFalse(restored.meetingCalendarEnabled)
        XCTAssertEqual(restored.meetingCalendarWindowMinutes, 30)
    }

    func testUpdatePrefChangePostsNotification() {
        let state = AppStateModel()
        let exp = expectation(forNotification: .traceUpdaterPrefsChanged, object: nil)
        state.autoUpdatesEnabled = false
        wait(for: [exp], timeout: 1.0)
    }

    func testResetOnboardingReturnsToOnboardingScene() {
        UserDefaults.standard.set(true, forKey: "app.trace.onboardingComplete")
        let state = AppStateModel(onboardingComplete: true)
        XCTAssertEqual(state.activeScene, .main)

        state.resetOnboarding()

        XCTAssertFalse(state.onboardingComplete)
        XCTAssertEqual(state.activeScene, .onboarding)
        XCTAssertFalse(AppStateModel.persistedOnboardingComplete(), "the persisted completion flag is cleared")
    }
}
