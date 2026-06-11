import Foundation

public enum MeetingActivitySignal: String, Sendable, Codable, Hashable, CaseIterable {
    case appLaunch
    case micActivity
    case systemAudioEnergy
    case browserTab
}

public struct MeetingActivityConfig: Sendable, Codable, Hashable {
    public var enabledSignals: Set<MeetingActivitySignal>
    public var minimumConcurrentSignals: Int
    public var stableDuration: TimeInterval
    public var micPollInterval: TimeInterval
    /// Require at least one "strong" signal — a known meeting/call app in front
    /// (`appLaunch`) or a meeting URL in the browser (`browserTab`) — so the
    /// loose audio proxies (mic-in-use + audio-playing) can't fire on their own
    /// during ordinary use (e.g. music while coding).
    public var requiresStrongSignal: Bool
    /// Slow-burn fallback for calls in apps the catalog doesn't know: when the
    /// loose audio proxies (mic-in-use + audio-playing) hold continuously for
    /// this long WITHOUT a strong signal, fire anyway. A real call keeps both
    /// up for minutes; a voice note or a quick Siri query doesn't survive the
    /// window. `nil` disables the fallback (strong-signal-only behaviour).
    ///
    /// A strong signal seen at any point during the window also keeps the
    /// fast `stableDuration` path armed — so briefly switching away from the
    /// meeting app no longer resets detection to zero.
    public var weakSignalStableDuration: TimeInterval?

    public init(
        enabledSignals: Set<MeetingActivitySignal>,
        minimumConcurrentSignals: Int,
        stableDuration: TimeInterval,
        micPollInterval: TimeInterval,
        requiresStrongSignal: Bool = true,
        weakSignalStableDuration: TimeInterval? = nil
    ) {
        self.enabledSignals = enabledSignals
        self.minimumConcurrentSignals = minimumConcurrentSignals
        self.stableDuration = stableDuration
        self.micPollInterval = micPollInterval
        self.requiresStrongSignal = requiresStrongSignal
        self.weakSignalStableDuration = weakSignalStableDuration
    }

    public static let `default` = MeetingActivityConfig(
        enabledSignals: Set(MeetingActivitySignal.allCases),
        minimumConcurrentSignals: 2,
        stableDuration: 2,
        micPollInterval: 1,
        weakSignalStableDuration: 12
    )
}

public struct MeetingSignalSnapshot: Sendable, Hashable {
    public let time: TimeInterval
    public let active: Set<MeetingActivitySignal>
    public init(time: TimeInterval, active: Set<MeetingActivitySignal>) {
        self.time = time
        self.active = active
    }
}

public enum MeetingActivityEvent: Sendable, Equatable {
    /// `strongSignal` is true when a known meeting app / meeting URL was seen
    /// during the qualifying window — callers use it to gate auto-start (a
    /// weak, audio-only detection should always ASK, never surprise-record).
    case meetingLikelyStarted(strongSignal: Bool)
    case meetingLikelyEnded
}

public struct MeetingActivityReducer: Sendable {
    private let config: MeetingActivityConfig
    private var firstQualifiedTime: TimeInterval?
    /// True once any snapshot in the current qualifying span carried a strong
    /// signal. Lets the fast path survive the meeting app briefly leaving the
    /// foreground (the strong signal drops but mic + audio keep the span alive).
    private var strongSeenInSpan = false
    private var alreadyStarted = false

    public init(config: MeetingActivityConfig) {
        self.config = config
    }

    public mutating func ingest(_ snapshot: MeetingSignalSnapshot) -> MeetingActivityEvent? {
        let active = snapshot.active.intersection(config.enabledSignals)
        let hasStrongSignal = active.contains(.appLaunch) || active.contains(.browserTab)
        // A snapshot keeps the span alive when enough signals are up AND it is
        // on at least one viable path: strong signal present, strong not
        // required at all, or the weak-signal fallback is enabled.
        guard active.count >= config.minimumConcurrentSignals,
            !config.requiresStrongSignal || hasStrongSignal
                || config.weakSignalStableDuration != nil
        else {
            firstQualifiedTime = nil
            strongSeenInSpan = false
            return nil
        }

        if firstQualifiedTime == nil {
            firstQualifiedTime = snapshot.time
            strongSeenInSpan = hasStrongSignal
            return nil
        }
        if hasStrongSignal { strongSeenInSpan = true }

        guard !alreadyStarted, let first = firstQualifiedTime else { return nil }
        let span = snapshot.time - first
        let strongPathReady =
            (strongSeenInSpan || !config.requiresStrongSignal) && span >= config.stableDuration
        let weakPathReady = config.weakSignalStableDuration.map { span >= $0 } ?? false
        guard strongPathReady || weakPathReady else { return nil }
        alreadyStarted = true
        return .meetingLikelyStarted(strongSignal: strongSeenInSpan)
    }
}

public protocol MeetingSignalSourcing: Sendable {
    func currentSignals() async -> Set<MeetingActivitySignal>
}

public actor AppActivityMonitor {
    private let source: any MeetingSignalSourcing
    private var reducer: MeetingActivityReducer

    public init(source: any MeetingSignalSourcing, config: MeetingActivityConfig = .default) {
        self.source = source
        self.reducer = MeetingActivityReducer(config: config)
    }

    public func tick(time: TimeInterval) async -> MeetingActivityEvent? {
        let active = await source.currentSignals()
        return reducer.ingest(MeetingSignalSnapshot(time: time, active: active))
    }
}

public struct BrowserTabSignal: Sendable, Hashable {
    public let browserBundleID: String
    public let url: String
    public var isMeetingURL: Bool {
        url.contains("meet.google.com") || url.contains("app.zoom.us") || url.contains("teams.microsoft.com")
    }
}

public protocol BrowserTabReading: Sendable {
    func activeBrowserTab(frontmostBundleID: String) async -> BrowserTabSignal?
}
