import Foundation

/// The two coach stages whose health is reported individually, because they
/// fail differently:
///
/// - `listener` failures PAUSE the coach (its cloud model isn't responding, or
///   keeps returning unusable replies) — no card can be produced.
/// - `search` failures DEGRADE it (the coach keeps checking, but can't pull
///   snippets from the user's notes, so recall is limited to the transcript).
public enum CoachStage: String, Sendable, Codable, Hashable, CaseIterable {
    case listener
    case search
}

/// A typed health event emitted by `CoachListener` so failures surface loudly
/// (an overlay banner + a coalesced notice) instead of dying in a debug log.
///
/// Emission is EDGE-TRIGGERED per stage: a dead model produces exactly one
/// `stageUnavailable` for its first failure, then stays quiet until it succeeds
/// again (one `stageRecovered`), no matter how many checks fail in between.
/// That is the rate limit — the banner appears once per outage, not once per
/// check.
public enum CoachHealthEvent: Sendable, Hashable {
    /// A stage just went from working to failing.
    /// `reason` is the underlying error's description (for logs/tooltips).
    case stageUnavailable(stage: CoachStage, reason: String)
    /// A previously-failing stage just succeeded again.
    case stageRecovered(stage: CoachStage)
}

/// Pure, testable state behind the overlay's health banner: which stages are
/// failing, what (if anything) the banner says, and what "dismiss" means.
///
/// Dismissal semantics: dismissing hides the banner for the CURRENT set of
/// failing stages. If the situation changes — a different stage starts failing —
/// the banner reappears (new information must not stay hidden behind an old
/// dismissal). Recovery of all stages clears both the banner and the dismissal.
public struct CoachHealthBannerModel: Sendable, Hashable {
    public private(set) var failingStages: Set<CoachStage> = []
    /// The failing-stage set at the moment the user dismissed the banner; the
    /// banner stays hidden while the set is unchanged.
    private var dismissedSignature: Set<CoachStage>?

    public init() {}

    public mutating func apply(_ event: CoachHealthEvent) {
        switch event {
        case .stageUnavailable(let stage, _):
            failingStages.insert(stage)
            // A NEW failing stage invalidates a prior dismissal — the user
            // dismissed different news.
            if let signature = dismissedSignature, signature != failingStages {
                dismissedSignature = nil
            }
        case .stageRecovered(let stage):
            failingStages.remove(stage)
            if failingStages.isEmpty { dismissedSignature = nil }
        }
    }

    /// Hide the banner for the current failing-stage set (an explicit user
    /// action). It returns if the set changes.
    public mutating func dismissCurrent() {
        dismissedSignature = failingStages
    }

    /// Reset at meeting start, mirroring `CoachListener.beginMeeting()`:
    /// a still-dead model re-raises on its first failure in the new meeting.
    public mutating func resetForNewMeeting() {
        failingStages = []
        dismissedSignature = nil
    }

    /// The banner text to show, or nil when healthy or dismissed.
    ///
    /// The listener stage outranks search: "paused" is the bigger truth than
    /// "degraded". British English throughout.
    public var activeMessage: String? {
        guard !failingStages.isEmpty, dismissedSignature != failingStages else { return nil }
        if failingStages.contains(.listener) {
            return "Coach paused — its model isn't responding. Check Settings → AI models."
        }
        return
            "Coach can't search your notes — cards may miss things from your documents, but answers and suggestions still work. Check Settings → AI models."
    }
}

/// Pure, testable state behind "Dismiss" on the coach overlay: dismissed means
/// HIDDEN FOR THE REST OF THE MEETING (no cards pop), as the button says — not
/// minimised to the pill (that's "Minimise").
///
/// Dismissal also PAUSES the listener's automatic checks (each check is a paid
/// cloud call that would produce cards nobody sees) — the coordinator wires
/// that through `CoachListener.setAutoChecksPaused`. Reopening is always
/// possible: an explicit user action (manual trigger, menu-bar reopen, a new
/// meeting starting) clears the dismissal and resumes checking.
public struct CoachOverlayDismissState: Sendable, Hashable {
    public private(set) var isDismissedForMeeting = false

    public init() {}

    public mutating func dismissForMeeting() {
        isDismissedForMeeting = true
    }

    public mutating func reopen() {
        isDismissedForMeeting = false
    }

    /// Whether newly surfaced cards may pop the overlay open.
    public var acceptsCards: Bool { !isDismissedForMeeting }
}
