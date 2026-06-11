import AppKit
@preconcurrency import CoreAudio
import Foundation
import os

// MARK: - Meeting URL classification (pure, testable)

/// Pure URL/string classification used to decide whether a browser tab is a
/// meeting.
///
/// Kept separate from the live sources so it can be unit-tested
/// without any system dependencies.
public enum MeetingURLClassifier: Sendable {
    /// Returns `true` when `url` (a raw href string) points at a known
    /// real-time meeting surface: Google Meet, any Zoom subdomain, Microsoft
    /// Teams, Slack huddles, Google Hangouts, Whereby, Webex, GoTo/Meeting,
    /// or BlueJeans.
    ///
    /// Pure and case-insensitive on the host portion.
    public static func isMeetingURL(_ url: String) -> Bool {
        let lowered = url.lowercased()
        // Extract a host substring when possible so we match the authority,
        // not arbitrary path/query text (e.g. a blog post linking to zoom).
        let host = Self.host(from: lowered) ?? lowered

        // Google Meet (meet.google.com) — exclude generic google.com.
        if host == "meet.google.com" || host.hasSuffix(".meet.google.com") {
            return true
        }
        // Google Hangouts (legacy meeting URL).
        if host == "hangouts.google.com" || host.hasSuffix(".hangouts.google.com") {
            return true
        }
        // Zoom — any *.zoom.us subdomain (app.zoom.us, us02web.zoom.us, …)
        // plus the *.zoom.com web client.
        if host == "zoom.us" || host.hasSuffix(".zoom.us")
            || host == "zoom.com" || host.hasSuffix(".zoom.com")
        {
            return true
        }
        // Microsoft Teams.
        if host == "teams.microsoft.com" || host.hasSuffix(".teams.microsoft.com")
            || host == "teams.live.com" || host.hasSuffix(".teams.live.com")
        {
            return true
        }
        // Slack web huddle — app.slack.com with a huddle marker in the URL.
        if (host == "app.slack.com" || host.hasSuffix(".slack.com"))
            && (lowered.contains("huddle") || lowered.contains("/calls/"))
        {
            return true
        }
        // Whereby.
        if host == "whereby.com" || host.hasSuffix(".whereby.com") {
            return true
        }
        // Cisco Webex.
        if host.hasSuffix(".webex.com") || host == "webex.com" {
            return true
        }
        // GoTo Meeting.
        if host.hasSuffix(".gotomeeting.com") || host == "gotomeeting.com"
            || host.hasSuffix(".goto.com") || host == "goto.com"
        {
            return true
        }
        // BlueJeans.
        if host.hasSuffix(".bluejeans.com") || host == "bluejeans.com" {
            return true
        }
        return false
    }

    /// Best-effort host extraction from a lowercased URL string.
    ///
    /// Falls back to
    /// `nil` when there is no recognizable scheme/authority so callers can
    /// substring-match the whole string instead.
    private static func host(from lowered: String) -> String? {
        if let comps = URLComponents(string: lowered), let h = comps.host, !h.isEmpty {
            return h
        }
        // Manual parse for scheme-less or malformed strings: take the text
        // between "://" (if any) and the first "/" or "?".
        var rest = lowered
        if let schemeRange = rest.range(of: "://") {
            rest = String(rest[schemeRange.upperBound...])
        }
        if let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<slash])
        }
        // Strip any userinfo / port.
        if let at = rest.lastIndex(of: "@") {
            rest = String(rest[rest.index(after: at)...])
        }
        if let colon = rest.firstIndex(of: ":") {
            rest = String(rest[..<colon])
        }
        return rest.isEmpty ? nil : rest
    }
}

// MARK: - Known meeting application bundle identifiers

/// Static registry of bundle identifiers that, when frontmost or launched,
/// indicate a meeting may be in progress.
public enum MeetingAppCatalog: Sendable {
    /// Dedicated meeting / conferencing app bundle IDs.
    public static let meetingAppBundleIDs: Set<String> = [
        "us.zoom.xos",  // Zoom
        "com.microsoft.teams",  // Teams (classic)
        "com.microsoft.teams2",  // Teams (new)
        "com.tinyspeck.slackmacgap",  // Slack (huddles)
        "com.apple.FaceTime",  // FaceTime
        "com.hnc.Discord",  // Discord
        "com.cisco.webexmeetingsapp",  // Webex
        "com.logmein.GoToMeeting",  // GoTo Meeting
        "net.whatsapp.WhatsApp",  // WhatsApp (calls)
        "ru.keepcoder.Telegram",  // Telegram (macOS)
        "org.telegram.desktop",  // Telegram Desktop
        "org.whispersystems.signal-desktop",  // Signal
        "com.facebook.archon",  // Messenger
        "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",  // Meet PWA
    ]

    /// Browser bundle IDs whose active tab can be inspected for a meeting URL.
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",  // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",  // (no AppleScript URL support; still recognized)
    ]

    /// True when the bundle ID is a dedicated meeting app.
    public static func isMeetingApp(_ bundleID: String) -> Bool {
        meetingAppBundleIDs.contains(bundleID)
    }

    /// True when the bundle ID is a supported browser.
    public static func isBrowser(_ bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }
}

// MARK: - Browser tab reader (AppleScript)

/// Reads the active tab URL of the frontmost supported browser via
/// `NSAppleScript`.
///
/// Returns `nil` on any failure (no Automation permission,
/// unsupported browser, parse error). Never throws, never blocks the caller's
/// actor — all AppleScript execution happens off the main thread.
public struct AppleScriptBrowserTabURLReader: BrowserTabReading {
    public init() {}

    /// Pure, testable classification matching `meet.google.com`, any `*.zoom.us`,
    /// `teams.microsoft.com`, Slack huddles, and other known meeting surfaces.
    ///
    /// Delegates to `MeetingURLClassifier`.
    public static func isMeetingURL(_ url: String) -> Bool {
        MeetingURLClassifier.isMeetingURL(url)
    }

    public func activeBrowserTab(frontmostBundleID: String) async -> BrowserTabSignal? {
        guard MeetingAppCatalog.isBrowser(frontmostBundleID) else { return nil }
        guard let script = Self.scriptSource(forBrowserBundleID: frontmostBundleID) else {
            return nil
        }
        // NSAppleScript is not Sendable and must run off any actor; hop to a
        // detached task and capture only Sendable values.
        let urlString: String? = await Task.detached(priority: .utility) {
            Self.runAppleScriptForURL(script)
        }.value

        guard let urlString, !urlString.isEmpty else { return nil }
        return BrowserTabSignal(browserBundleID: frontmostBundleID, url: urlString)
    }

    /// Returns the AppleScript source that yields the frontmost tab URL for the
    /// given browser, or `nil` if the browser is not scriptable for URLs.
    static func scriptSource(forBrowserBundleID bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return "tell application \"Safari\" to return URL of front document"
        case "com.google.Chrome":
            return "tell application \"Google Chrome\" to return URL of active tab of front window"
        case "com.google.Chrome.beta":
            return "tell application \"Google Chrome Beta\" to return URL of active tab of front window"
        case "com.google.Chrome.canary":
            return "tell application \"Google Chrome Canary\" to return URL of active tab of front window"
        case "company.thebrowser.Browser":
            return "tell application \"Arc\" to return URL of active tab of front window"
        case "com.brave.Browser":
            return "tell application \"Brave Browser\" to return URL of active tab of front window"
        case "com.microsoft.edgemac":
            return "tell application \"Microsoft Edge\" to return URL of active tab of front window"
        default:
            // Firefox and others expose no AppleScript URL accessor.
            return nil
        }
    }

    /// Executes the AppleScript synchronously and extracts a string result.
    ///
    /// Returns `nil` on any compilation/execution error.
    static func runAppleScriptForURL(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            Loggers.bridges.debug(
                "Browser tab AppleScript error: \(String(describing: errorInfo[NSAppleScript.errorMessage]), privacy: .public)"
            )
            return nil
        }
        return descriptor.stringValue
    }
}

// MARK: - Live signal source

/// Concrete `MeetingSignalSourcing` implementation backed by real macOS APIs:
/// NSWorkspace (frontmost app), CoreAudio (input/output device running state),
/// and AppleScript (browser tab URL).
///
/// All probes are best-effort: any failure
/// degrades to "signal absent" rather than throwing.
public struct LiveMeetingSignalSource: MeetingSignalSourcing {
    private let browserReader: any BrowserTabReading
    /// User-added meeting app bundle IDs beyond the built-in catalog.
    ///
    /// Treated
    /// exactly like catalog apps for the `.appLaunch` signal.
    private let additionalMeetingAppIDs: Set<String>
    /// Injectable mic probe (real CoreAudio by default) — both the `appLaunch`
    /// and `browserTab` signals are gated on it, so tests must be able to pin
    /// it rather than depend on the machine's actual input-device state.
    private let micActiveProbe: @Sendable () -> Bool

    public init(
        browserReader: any BrowserTabReading = AppleScriptBrowserTabURLReader(),
        additionalMeetingAppIDs: Set<String> = [],
        micActiveProbe: (@Sendable () -> Bool)? = nil
    ) {
        self.browserReader = browserReader
        self.additionalMeetingAppIDs = additionalMeetingAppIDs
        // Internal static can't be a public default argument; resolve here.
        self.micActiveProbe = micActiveProbe ?? { Self.defaultInputDeviceIsRunningSomewhere() }
    }

    public func currentSignals() async -> Set<MeetingActivitySignal> {
        var signals: Set<MeetingActivitySignal> = []

        let frontmostBundleID = Self.frontmostBundleID()
        let micActive = micActiveProbe()

        // App-launch signal: a known (or user-added) meeting app is frontmost
        // AND the mic is actually live. The mic gate is what separates "in a
        // call" from "just using the app" — typing in WhatsApp / Slack / Telegram
        // (even with music playing) must NOT count as a call. A real call always
        // opens the input device, even when muted at the app level.
        if let bundleID = frontmostBundleID,
            MeetingAppCatalog.isMeetingApp(bundleID) || additionalMeetingAppIDs.contains(bundleID),
            micActive
        {
            signals.insert(.appLaunch)
        }

        // Microphone in use (best-effort, CoreAudio default input device).
        if micActive {
            signals.insert(.micActivity)
        }

        // System audio active (default output device running somewhere).
        if Self.defaultOutputDeviceIsRunningSomewhere() {
            signals.insert(.systemAudioEnergy)
        }

        // Browser meeting tab. Gated on the mic being live for the same reason
        // as `appLaunch` (a real call always opens the input device) — which
        // also keeps the per-tick AppleScript from running while you merely
        // browse, now that the detector polls every second.
        if micActive,
            let bundleID = frontmostBundleID,
            let tab = await browserReader.activeBrowserTab(frontmostBundleID: bundleID),
            tab.isMeetingURL || MeetingURLClassifier.isMeetingURL(tab.url)
        {
            signals.insert(.browserTab)
        }

        return signals
    }

    // MARK: Frontmost app

    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: CoreAudio device-running probes (best-effort)

    /// `true` when the system default input device reports it is running
    /// somewhere (i.e. some process has the mic open).
    ///
    /// Returns `false` on any
    /// CoreAudio error.
    static func defaultInputDeviceIsRunningSomewhere() -> Bool {
        guard let deviceID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice) else {
            return false
        }
        return deviceIsRunningSomewhere(deviceID)
    }

    /// `true` when the system default output device reports it is running
    /// somewhere (i.e. audio is playing).
    ///
    /// Returns `false` on any CoreAudio error.
    static func defaultOutputDeviceIsRunningSomewhere() -> Bool {
        guard let deviceID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice) else {
            return false
        }
        return deviceIsRunningSomewhere(deviceID)
    }

    /// Reads a default-device AudioObjectID for the given hardware selector.
    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Reads `kAudioDevicePropertyDeviceIsRunningSomewhere` for a device.
    private static func deviceIsRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }
}
