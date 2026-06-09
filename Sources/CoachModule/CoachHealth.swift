import Foundation

/// The coach pipeline stages whose health is reported individually, because they
/// fail differently:
///
/// - `embedding` failures DEGRADE the pipeline (cards still surface, just without
///   grounding in the user's documents).
/// - `classifier` / `router` failures PAUSE it (no card can be produced).
public enum CoachPipelineStage: String, Sendable, Codable, Hashable, CaseIterable {
    case embedding
    case classifier
    case router
}

/// A typed health event emitted by `CoachOrchestrator` so failures surface loudly
/// (an overlay banner) instead of dying in a debug log.
///
/// Emission is EDGE-TRIGGERED per stage: a dead model produces exactly one
/// `stageUnavailable` for its first failure, then stays quiet until it succeeds
/// again (one `stageRecovered`), no matter how many utterances fail in between.
/// That is the rate limit — the banner appears once per outage, not once per
/// utterance.
public enum CoachHealthEvent: Sendable, Hashable {
    /// A stage's model just went from working to failing.
    /// `reason` is the underlying error's description (for logs/tooltips).
    case stageUnavailable(stage: CoachPipelineStage, reason: String)
    /// A previously-failing stage just succeeded again.
    case stageRecovered(stage: CoachPipelineStage)
    /// An utterance was superseded under concurrency load (latest-wins queueing —
    /// see `CoachOrchestrator.enqueue`). Carries the running per-meeting total so
    /// the overlay can show "N cues skipped under load".
    case cueSkipped(totalSkippedThisMeeting: Int)
}

/// Pure, testable state behind the overlay's health banner: which stages are
/// failing, what (if anything) the banner says, what "dismiss" means, and the
/// skipped-cues counter.
///
/// Dismissal semantics: dismissing hides the banner for the CURRENT set of
/// failing stages. If the situation changes — a different stage starts failing —
/// the banner reappears (new information must not stay hidden behind an old
/// dismissal). Recovery of all stages clears both the banner and the dismissal.
public struct CoachHealthBannerModel: Sendable, Hashable {
    public private(set) var failingStages: Set<CoachPipelineStage> = []
    /// Running count of cues skipped under load this meeting (latest-wins
    /// supersession in `CoachOrchestrator.enqueue`).
    public private(set) var skippedCueCount = 0
    /// The failing-stage set at the moment the user dismissed the banner; the
    /// banner stays hidden while the set is unchanged.
    private var dismissedSignature: Set<CoachPipelineStage>?

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
        case .cueSkipped(let total):
            skippedCueCount = total
        }
    }

    /// Hide the banner for the current failing-stage set (an explicit user
    /// action). It returns if the set changes.
    public mutating func dismissCurrent() {
        dismissedSignature = failingStages
    }

    /// Reset at meeting start, mirroring `CoachOrchestrator.beginMeeting()`:
    /// a still-dead model re-raises on its first failure in the new meeting.
    public mutating func resetForNewMeeting() {
        failingStages = []
        skippedCueCount = 0
        dismissedSignature = nil
    }

    /// The banner text to show, or nil when healthy or dismissed.
    ///
    /// Model stages outrank embedding: "paused" is the bigger truth than
    /// "degraded". British English throughout.
    public var activeMessage: String? {
        guard !failingStages.isEmpty, dismissedSignature != failingStages else { return nil }
        if failingStages.contains(.router) || failingStages.contains(.classifier) {
            return "Coach paused — model unavailable. Check Settings → Models."
        }
        // Honest about the actual degradation: with embeddings down the
        // relevance gate suppresses most automatic cues entirely — only obvious
        // triggers (questions, asks) and manual requests still produce help.
        return
            "Coach can't search your documents — automatic cues are limited to obvious triggers, and asking directly still works. Check Settings → Models."
    }

    /// The subtle expanded-overlay line for load shedding, or nil when none.
    public var skippedCueMessage: String? {
        guard skippedCueCount > 0 else { return nil }
        return skippedCueCount == 1
            ? "1 cue skipped under load"
            : "\(skippedCueCount) cues skipped under load"
    }
}

/// Pure, testable state behind "Dismiss" on the coach overlay: dismissed means
/// HIDDEN FOR THE REST OF THE MEETING (no cards pop), as the button says — not
/// minimised to the pill (that's "Minimise").
///
/// Reopening is always possible: an explicit user action (manual trigger,
/// menu-bar reopen, a new meeting starting) clears the dismissal.
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
