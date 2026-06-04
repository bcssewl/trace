import XCTest

@testable import SharedCore

final class BridgesPermissionGateTests: XCTestCase {
    func testSnapshotCombinesAllPermissionStatuses() async {
        let gate = PermissionGate(
            mic: StubMicPermission(.granted),
            systemAudio: StubSystemAudioPermission(.notDetermined),
            accessibility: StubAccessibilityPermission(.denied),
            speechRecognition: StubSpeechRecognitionPermission(.granted),
            calendar: StubCalendarPermission(.granted),
            notifications: StubNotificationPermission(.notDetermined)
        )

        let snapshot = await gate.snapshot()

        XCTAssertEqual(snapshot.microphone, .granted)
        XCTAssertEqual(snapshot.systemAudio, .notDetermined)
        XCTAssertEqual(snapshot.accessibility, .denied)
        XCTAssertEqual(snapshot.speechRecognition, .granted)
        XCTAssertEqual(snapshot.calendar, .granted)
        XCTAssertEqual(snapshot.notifications, .notDetermined)
        XCTAssertFalse(snapshot.requiredPermissionsSatisfied)
    }

    func testRequiredPermissionsIncludeSpeechRecognition() async {
        let gate = PermissionGate(
            mic: StubMicPermission(.granted),
            systemAudio: StubSystemAudioPermission(.granted),
            accessibility: StubAccessibilityPermission(.granted),
            speechRecognition: StubSpeechRecognitionPermission(.granted),
            calendar: StubCalendarPermission(.denied),
            notifications: StubNotificationPermission(.denied)
        )

        let snapshot = await gate.snapshot()
        XCTAssertTrue(snapshot.requiredPermissionsSatisfied)
    }

    func testMissingSpeechRecognitionLeavesRequiredPermissionsUnsatisfied() async {
        let gate = PermissionGate(
            mic: StubMicPermission(.granted),
            systemAudio: StubSystemAudioPermission(.granted),
            accessibility: StubAccessibilityPermission(.granted),
            speechRecognition: StubSpeechRecognitionPermission(.denied),
            calendar: StubCalendarPermission(.granted),
            notifications: StubNotificationPermission(.granted)
        )

        let snapshot = await gate.snapshot()
        XCTAssertFalse(snapshot.requiredPermissionsSatisfied)
    }
}

private struct StubMicPermission: MicrophonePermissionChecking {
    let status: PermissionStatus
    init(_ status: PermissionStatus) { self.status = status }
    func microphoneStatus() async -> PermissionStatus { status }
}
private struct StubSystemAudioPermission: SystemAudioPermissionChecking {
    let status: PermissionStatus
    init(_ status: PermissionStatus) { self.status = status }
    func systemAudioStatus() async -> PermissionStatus { status }
}
private struct StubAccessibilityPermission: AccessibilityPermissionChecking {
    let status: PermissionStatus
    init(_ status: PermissionStatus) { self.status = status }
    func accessibilityStatus(prompt: Bool) -> PermissionStatus { status }
}
private struct StubSpeechRecognitionPermission: SpeechRecognitionPermissionChecking {
    let status: PermissionStatus
    init(_ status: PermissionStatus) { self.status = status }
    func speechRecognitionStatus() async -> PermissionStatus { status }
}
private struct StubCalendarPermission: CalendarPermissionChecking {
    let status: PermissionStatus
    init(_ status: PermissionStatus) { self.status = status }
    func calendarStatus() async -> PermissionStatus { status }
}
private struct StubNotificationPermission: NotificationPermissionChecking {
    let status: PermissionStatus
    init(_ status: PermissionStatus) { self.status = status }
    func notificationStatus() async -> PermissionStatus { status }
}
