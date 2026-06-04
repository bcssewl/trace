import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import CoreAudio
import EventKit
import Foundation
import Speech
import UserNotifications

private let systemAudioCacheKey = "app.trace.permission.systemAudio"
let browserAwarenessCacheKey = "app.trace.permission.browserAwareness"

public struct PermissionRequester: Sendable {
    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        case microphone
        case systemAudio
        case accessibility
        case speechRecognition
        case calendar
        case notifications
        /// macOS Apple Events automation: lets Trace read the frontmost browser's
        /// active tab URL to recognize which call you're in. Filed by macOS under
        /// Privacy & Security → Automation.
        case browserAwareness

        public var settingsPaneURL: URL? {
            let raw: String
            switch self {
            case .microphone:
                raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .systemAudio:
                // macOS 14.4+ merged audio-capture into the "Screen & System Audio
                // Recording" pane under Privacy_ScreenCapture. The old
                // Privacy_AudioCapture URL no-ops on macOS 26.
                raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .accessibility:
                raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .speechRecognition:
                raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            case .calendar:
                raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            case .notifications:
                raw = "x-apple.systempreferences:com.apple.preference.notifications"
            case .browserAwareness:
                raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            }
            return URL(string: raw)
        }
    }

    public init() {}

    public func request(_ kind: Kind) async -> PermissionStatus {
        switch kind {
        case .microphone: return await requestMicrophone()
        case .systemAudio: return await requestSystemAudio()
        case .accessibility: return await requestAccessibility()
        case .speechRecognition: return await requestSpeechRecognition()
        case .calendar: return await requestCalendar()
        case .notifications: return await requestNotifications()
        case .browserAwareness: return await requestBrowserAwareness()
        }
    }

    /// Surface the macOS Automation (Apple Events) prompt by firing a tiny probe
    /// AppleScript against a common browser. macOS shows the "Trace wants to
    /// control Safari/Chrome" dialog the first time; subsequent runs return the
    /// cached decision.
    ///
    /// There is no public API to read Automation TCC silently,
    /// so we cache the outcome (like systemAudio) for later snapshots.
    private func requestBrowserAwareness() async -> PermissionStatus {
        let status = await Task.detached(priority: .userInitiated) { () -> PermissionStatus in
            // Try the running browsers first, then a sensible default. A bare
            // `get name` is enough to trigger the Automation consent dialog.
            let candidates = ["Safari", "Google Chrome", "Arc", "Brave Browser", "Microsoft Edge"]
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
            let targets = candidates.filter { running.contains($0) } + candidates
            for app in targets {
                guard let script = NSAppleScript(source: "tell application \"\(app)\" to get name") else { continue }
                var errorInfo: NSDictionary?
                _ = script.executeAndReturnError(&errorInfo)
                if errorInfo == nil { return .granted }
                if let code = errorInfo?[NSAppleScript.errorNumber] as? Int {
                    // -1743 = user denied automation; -600/-609 = app not running.
                    if code == -1743 { return .denied }
                    // Not running / not found — try the next candidate.
                    continue
                }
                return .denied
            }
            // No browser present to probe — treat as not-yet-determined so the
            // row stays informational rather than falsely "denied".
            return .notDetermined
        }.value
        if status != .notDetermined {
            UserDefaults.standard.set(status.rawValue, forKey: browserAwarenessCacheKey)
        }
        if status == .denied {
            await MainActor.run { self.openSystemSettings(for: .browserAwareness) }
        }
        return status
    }

    @MainActor
    public func openSystemSettings(for kind: Kind) {
        guard let url = kind.settingsPaneURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestMicrophone() async -> PermissionStatus {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        Loggers.bootstrap.info(
            "PermissionRequester.requestMicrophone current=\(String(describing: current), privacy: .public)"
        )
        if current == .authorized { return .granted }
        if current == .restricted { return .restricted }
        if current == .denied {
            Loggers.bootstrap.warning(
                "PermissionRequester.requestMicrophone status=.denied — macOS won't re-prompt; surfacing Open Settings flow"
            )
            await MainActor.run { self.openSystemSettings(for: .microphone) }
            return .denied
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        Loggers.bootstrap.info(
            "PermissionRequester.requestMicrophone requestAccess result=\(granted, privacy: .public)"
        )
        return granted ? .granted : .denied
    }

    private func requestSystemAudio() async -> PermissionStatus {
        guard #available(macOS 14.4, *) else { return .restricted }
        Loggers.bootstrap.info("PermissionRequester.requestSystemAudio: probing AudioHardwareCreateProcessTap")
        // Probe by creating a process tap on our own PID. macOS will prompt
        // the user with the audio-capture TCC dialog the first time. On
        // subsequent attempts macOS returns the cached decision without prompting.
        let status = await Task.detached(priority: .userInitiated) { () -> PermissionStatus in
            // Use a GLOBAL tap (exclude no processes = capture everything). This is
            // what triggers macOS to register the app under "System Audio Recording
            // Only" in System Settings → Privacy & Security → Screen & System Audio
            // Recording. A self-tap (processes: [selfPID]) does NOT register because
            // macOS doesn't consider self-capture a privileged operation.
            let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            desc.uuid = UUID()
            desc.name = "Trace Permission Probe"
            desc.muteBehavior = .unmuted
            desc.isPrivate = true

            var tapID: AudioObjectID = kAudioObjectUnknown
            let result = AudioHardwareCreateProcessTap(desc, &tapID)
            if result == noErr, tapID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyProcessTap(tapID)
                Loggers.bootstrap.info("PermissionRequester.requestSystemAudio: global probe tap succeeded; granted")
                return .granted
            }
            if result == kAudioHardwareIllegalOperationError {
                Loggers.bootstrap.warning(
                    "PermissionRequester.requestSystemAudio: kAudioHardwareIllegalOperationError; denied or notDetermined"
                )
                return .denied
            }
            Loggers.bootstrap.error(
                "PermissionRequester.requestSystemAudio: probe failed status=\(result, privacy: .public)")
            return .denied
        }.value
        UserDefaults.standard.set(status.rawValue, forKey: systemAudioCacheKey)
        if status == .denied {
            await MainActor.run { self.openSystemSettings(for: .systemAudio) }
        }
        return status
    }

    private func requestAccessibility() async -> PermissionStatus {
        // Check status silently first — no prompt yet.
        if AXIsProcessTrusted() { return .granted }

        // Not trusted. Clear any stale TCC entry from previous builds (dev only,
        // no-op in production where the code hash doesn't churn), then trigger
        // the macOS native prompt sheet exactly ONCE via prompt:true.
        _ = await Self.runTccReset(service: "Accessibility")
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        // The native sheet from `prompt:true` has its own "Open System Settings"
        // button — do NOT call openSystemSettings here, that would produce a
        // second Settings window on top of the sheet.
        return trusted ? .granted : .denied
    }

    /// Clears the TCC entry for this bundle so macOS re-prompts on the next
    /// request.
    ///
    /// Used to work around stale-hash entries on dev/ad-hoc-signed
    /// builds where Xcode produces a new code-sign hash each rebuild but the
    /// TCC database still references the old one.
    private static func runTccReset(service: String) async -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.launchPath = "/usr/bin/tccutil"
                task.arguments = ["reset", service, bundleID]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    Loggers.bootstrap.info(
                        "tccutil reset \(service, privacy: .public) \(bundleID, privacy: .public) exit=\(task.terminationStatus, privacy: .public)"
                    )
                    cont.resume(returning: task.terminationStatus == 0)
                } catch {
                    Loggers.bootstrap.error(
                        "tccutil reset failed: \(error.localizedDescription, privacy: .public)"
                    )
                    cont.resume(returning: false)
                }
            }
        }
    }

    private func requestSpeechRecognition() async -> PermissionStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        Loggers.bootstrap.info(
            "PermissionRequester.requestSpeechRecognition current=\(String(describing: current), privacy: .public)"
        )
        switch current {
        case .authorized:
            return .granted
        case .denied:
            await MainActor.run { self.openSystemSettings(for: .speechRecognition) }
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            let status = await withCheckedContinuation {
                (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
            return Self.mapSpeechStatus(status)
        @unknown default:
            return .unknown
        }
    }

    private static func mapSpeechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private func requestCalendar() async -> PermissionStatus {
        let current = EKEventStore.authorizationStatus(for: .event)
        Loggers.bootstrap.info(
            "PermissionRequester.requestCalendar current=\(String(describing: current), privacy: .public)"
        )
        if current == .denied || current == .restricted {
            await MainActor.run { self.openSystemSettings(for: .calendar) }
            return current == .denied ? .denied : .restricted
        }
        let store = EKEventStore()
        do {
            let ok = try await store.requestFullAccessToEvents()
            Loggers.bootstrap.info(
                "PermissionRequester.requestCalendar requestFullAccess result=\(ok, privacy: .public)"
            )
            return ok ? .granted : .denied
        } catch {
            Loggers.bootstrap.error(
                "PermissionRequester.requestCalendar failed: \(error.localizedDescription, privacy: .public)"
            )
            return .denied
        }
    }

    private func requestNotifications() async -> PermissionStatus {
        let center = UNUserNotificationCenter.current()
        do {
            let settings = await center.notificationSettings()
            Loggers.bootstrap.info(
                "PermissionRequester.requestNotifications current=\(String(describing: settings.authorizationStatus), privacy: .public)"
            )
            if settings.authorizationStatus == .denied {
                await MainActor.run { self.openSystemSettings(for: .notifications) }
                return .denied
            }
            let ok = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            Loggers.bootstrap.info(
                "PermissionRequester.requestNotifications requestAuthorization result=\(ok, privacy: .public)"
            )
            return ok ? .granted : .denied
        } catch {
            Loggers.bootstrap.error(
                "PermissionRequester.requestNotifications failed: \(error.localizedDescription, privacy: .public)"
            )
            return .denied
        }
    }
}
