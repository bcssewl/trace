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

    public init(
        enabledSignals: Set<MeetingActivitySignal>,
        minimumConcurrentSignals: Int,
        stableDuration: TimeInterval,
        micPollInterval: TimeInterval,
        requiresStrongSignal: Bool = true
    ) {
        self.enabledSignals = enabledSignals
        self.minimumConcurrentSignals = minimumConcurrentSignals
        self.stableDuration = stableDuration
        self.micPollInterval = micPollInterval
        self.requiresStrongSignal = requiresStrongSignal
    }

    public static let `default` = MeetingActivityConfig(
        enabledSignals: Set(MeetingActivitySignal.allCases),
        minimumConcurrentSignals: 2,
        stableDuration: 5,
        micPollInterval: 2
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
    case meetingLikelyStarted
    case meetingLikelyEnded
}

public struct MeetingActivityReducer: Sendable {
    private let config: MeetingActivityConfig
    private var firstQualifiedTime: TimeInterval?
    private var alreadyStarted = false

    public init(config: MeetingActivityConfig) {
        self.config = config
    }

    public mutating func ingest(_ snapshot: MeetingSignalSnapshot) -> MeetingActivityEvent? {
        let active = snapshot.active.intersection(config.enabledSignals)
        let hasStrongSignal = active.contains(.appLaunch) || active.contains(.browserTab)
        guard active.count >= config.minimumConcurrentSignals,
            !config.requiresStrongSignal || hasStrongSignal
        else {
            firstQualifiedTime = nil
            return nil
        }

        if firstQualifiedTime == nil {
            firstQualifiedTime = snapshot.time
            return nil
        }

        guard !alreadyStarted,
            let first = firstQualifiedTime,
            snapshot.time - first >= config.stableDuration
        else { return nil }
        alreadyStarted = true
        return .meetingLikelyStarted
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
