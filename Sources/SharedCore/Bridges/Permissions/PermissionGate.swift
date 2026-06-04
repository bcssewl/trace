import AVFoundation
@preconcurrency import ApplicationServices
import EventKit
import Foundation
import Speech
import UserNotifications

public enum PermissionStatus: String, Sendable, Codable, Hashable {
    case granted
    case denied
    case notDetermined
    case restricted
    case unknown
}

public struct PermissionSnapshot: Sendable, Codable, Hashable {
    public let microphone: PermissionStatus
    public let systemAudio: PermissionStatus
    public let accessibility: PermissionStatus
    public let speechRecognition: PermissionStatus
    public let calendar: PermissionStatus
    public let notifications: PermissionStatus
    public let browserAwareness: PermissionStatus

    public var requiredPermissionsSatisfied: Bool {
        microphone == .granted
            && systemAudio == .granted
            && accessibility == .granted
            && speechRecognition == .granted
    }
}

public protocol MicrophonePermissionChecking: Sendable {
    func microphoneStatus() async -> PermissionStatus
}
public protocol SystemAudioPermissionChecking: Sendable {
    func systemAudioStatus() async -> PermissionStatus
}
public protocol AccessibilityPermissionChecking: Sendable {
    func accessibilityStatus(prompt: Bool) -> PermissionStatus
}
public protocol SpeechRecognitionPermissionChecking: Sendable {
    func speechRecognitionStatus() async -> PermissionStatus
}
public protocol CalendarPermissionChecking: Sendable {
    func calendarStatus() async -> PermissionStatus
}
public protocol NotificationPermissionChecking: Sendable {
    func notificationStatus() async -> PermissionStatus
}
public protocol BrowserAwarenessPermissionChecking: Sendable {
    func browserAwarenessStatus() async -> PermissionStatus
}

public struct PermissionGate: Sendable {
    private let mic: any MicrophonePermissionChecking
    private let systemAudio: any SystemAudioPermissionChecking
    private let accessibility: any AccessibilityPermissionChecking
    private let speechRecognition: any SpeechRecognitionPermissionChecking
    private let calendar: any CalendarPermissionChecking
    private let notifications: any NotificationPermissionChecking
    private let browserAwareness: any BrowserAwarenessPermissionChecking

    public init(
        mic: any MicrophonePermissionChecking = LiveMicrophonePermission(),
        systemAudio: any SystemAudioPermissionChecking = LiveSystemAudioPermission(),
        accessibility: any AccessibilityPermissionChecking = LiveAccessibilityPermission(),
        speechRecognition: any SpeechRecognitionPermissionChecking = LiveSpeechRecognitionPermission(),
        calendar: any CalendarPermissionChecking = LiveCalendarPermission(),
        notifications: any NotificationPermissionChecking = LiveNotificationPermission(),
        browserAwareness: any BrowserAwarenessPermissionChecking = LiveBrowserAwarenessPermission()
    ) {
        self.mic = mic
        self.systemAudio = systemAudio
        self.accessibility = accessibility
        self.speechRecognition = speechRecognition
        self.calendar = calendar
        self.notifications = notifications
        self.browserAwareness = browserAwareness
    }

    public func snapshot(promptForAccessibility: Bool = false) async -> PermissionSnapshot {
        async let micStatus = mic.microphoneStatus()
        async let systemStatus = systemAudio.systemAudioStatus()
        async let speechStatus = speechRecognition.speechRecognitionStatus()
        async let calendarStatus = calendar.calendarStatus()
        async let notificationStatus = notifications.notificationStatus()
        async let browserStatus = browserAwareness.browserAwarenessStatus()
        let ax = accessibility.accessibilityStatus(prompt: promptForAccessibility)

        return await PermissionSnapshot(
            microphone: micStatus,
            systemAudio: systemStatus,
            accessibility: ax,
            speechRecognition: speechStatus,
            calendar: calendarStatus,
            notifications: notificationStatus,
            browserAwareness: browserStatus
        )
    }
}

public struct LiveBrowserAwarenessPermission: BrowserAwarenessPermissionChecking {
    public init() {}
    public func browserAwarenessStatus() async -> PermissionStatus {
        // No public API reads Automation (Apple Events) TCC without prompting,
        // so read the cached decision written by
        // PermissionRequester.requestBrowserAwareness.
        let raw = UserDefaults.standard.string(forKey: "app.trace.permission.browserAwareness")
        if let raw, let status = PermissionStatus(rawValue: raw) {
            return status
        }
        return .notDetermined
    }
}

public struct LiveMicrophonePermission: MicrophonePermissionChecking {
    public init() {}
    public func microphoneStatus() async -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
}

public struct LiveSystemAudioPermission: SystemAudioPermissionChecking {
    public init() {}
    public func systemAudioStatus() async -> PermissionStatus {
        // No public API checks audio-capture TCC without prompting. Read the
        // cached decision written by PermissionRequester.requestSystemAudio.
        // Cleared on app uninstall via UserDefaults.
        let raw = UserDefaults.standard.string(forKey: "app.trace.permission.systemAudio")
        if let raw, let status = PermissionStatus(rawValue: raw) {
            return status
        }
        return .notDetermined
    }
}

public struct LiveAccessibilityPermission: AccessibilityPermissionChecking {
    public init() {}
    public func accessibilityStatus(prompt: Bool) -> PermissionStatus {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
        return trusted ? .granted : .denied
    }
}

public struct LiveSpeechRecognitionPermission: SpeechRecognitionPermissionChecking {
    public init() {}
    public func speechRecognitionStatus() async -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
}

public struct LiveCalendarPermission: CalendarPermissionChecking {
    public init() {}
    public func calendarStatus() async -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly, .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
}

public struct LiveNotificationPermission: NotificationPermissionChecking {
    public init() {}
    public func notificationStatus() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
}
