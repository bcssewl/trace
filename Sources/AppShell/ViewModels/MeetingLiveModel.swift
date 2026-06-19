import Foundation
import Observation
import SharedCore

/// The single source of truth for an in-progress meeting (Approach ① in the
/// build spec).
///
/// The capture pipeline writes committed utterances + volatile
/// partials here; the tri-column meeting UI binds to it directly; the live
/// summary and conversation-state digests write into it; and the (build-2)
/// Coach will subscribe to its utterance stream. Nothing keeps a second copy
/// of the live transcript.
///
/// This is distinct from `ActiveCaptureModel`, which stays the coarse
/// mode/timer state read by the menu bar and notch HUD. The meeting runtime
/// updates both: `ActiveCaptureModel` for chrome, `MeetingLiveModel` for the
/// detail view.
/// Post-finalize auto-categorization prompt shown as a banner on the meeting
/// detail (BAS-9): either confirmation of a high-confidence auto-file, or the
/// top candidates to choose from when the model is unsure. One-tap buttons file
/// the meeting (sticky manual override).
public struct MeetingCategorizationSuggestion: Sendable, Hashable {
    public struct Candidate: Sendable, Hashable, Identifiable {
        public let id: String  // project id (uuidString)
        public let name: String
        public let confidence: Double
        public init(id: String, name: String, confidence: Double) {
            self.id = id
            self.name = name
            self.confidence = confidence
        }
    }
    public let headline: String
    public let candidates: [Candidate]
    /// Every project, alphabetical — backs the banner's "all projects" picker,
    /// so a misfiled meeting can always be moved to the right project even when
    /// it didn't make the top-3 chips.
    public let allProjects: [Candidate]
    public let isAutoFiled: Bool

    public init(
        headline: String, candidates: [Candidate], allProjects: [Candidate] = [],
        isAutoFiled: Bool
    ) {
        self.headline = headline
        self.candidates = candidates
        self.allProjects = allProjects
        self.isAutoFiled = isAutoFiled
    }
}

@Observable
@MainActor
public final class MeetingLiveModel {

    /// One finalized line of transcript. `text` is the displayed text
    /// (`cleaned` when present, else raw ASR).
    ///
    /// Immutable except for later
    /// offline-refinement swaps which replace the whole turn.
    public struct Turn: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let t: Double  // seconds from meeting start
        public let speakerID: String  // "you", "remote_1", "system_audio", …
        public let isYou: Bool
        public var text: String
        public let confidence: Double?

        public init(
            id: UUID = UUID(),
            t: Double,
            speakerID: String,
            isYou: Bool,
            text: String,
            confidence: Double?
        ) {
            self.id = id
            self.t = t
            self.speakerID = speakerID
            self.isYou = isYou
            self.text = text
            self.confidence = confidence
        }
    }

    /// A participant seen in this meeting. `displayName` reflects any
    /// per-session rename; `turnCount` is how many finalized turns they have.
    public struct Speaker: Identifiable, Sendable, Hashable {
        public var id: String { speakerID }
        public let speakerID: String
        public let isYou: Bool
        public var displayName: String
        public var turnCount: Int

        public init(speakerID: String, isYou: Bool, displayName: String, turnCount: Int = 0) {
            self.speakerID = speakerID
            self.isYou = isYou
            self.displayName = displayName
            self.turnCount = turnCount
        }
    }

    public enum Health: Sendable, Equatable {
        case idle
        case capturing
        case noFrames  // capturing but the watchdog saw no audio frames
        case error(String)
    }

    public enum SummaryState: Sendable, Equatable {
        case none
        case streaming
        case final
    }

    /// The post-meeting finalisation lifecycle, distinct from `SummaryState`
    /// (which tracks the text stream itself, including the in-meeting rolling
    /// summary).
    ///
    /// Driven explicitly by `MeetingRuntime`'s finalisation task so the UI can
    /// show "Finalising transcript… / Generating summary… / failed (retry)"
    /// without the meeting feeling stuck after Stop. `.idle` for live capture
    /// and for hydrated saved meetings.
    public enum SummaryPhase: Sendable, Equatable {
        case idle
        /// Diarization refinement + title generation are running.
        case preparing
        /// Summary tokens are streaming in.
        case generating
        /// Generation failed; the associated message is user-facing and the view
        /// offers a retry. Never silent.
        case failed(String)
        case done
    }

    public private(set) var sessionId: String?
    public var title: String = ""
    public private(set) var startedAt: Date?

    public private(set) var turns: [Turn] = []
    /// When set, the transcript view scrolls to the turn nearest this offset
    /// (seconds from meeting start).
    ///
    /// Drives citation deep-links to `meeting @ ts`.
    /// Seek by timestamp, not `Turn.id` — ids are regenerated on each hydrate.
    public var scrollTargetTime: Double?
    /// Per-speaker volatile indicator shown while a speech segment is in
    /// progress.
    ///
    /// Parakeet transcribes per VAD segment (not token-by-token), so
    /// this is typically a "● speaking…" marker rather than interim words.
    /// Keyed by `speakerID`; cleared when that speaker's turn finalizes.
    public private(set) var partials: [String: String] = [:]
    public private(set) var speakers: [Speaker] = []

    /// User scratchpad.
    ///
    /// Bound to the My Notes editor; the runtime autosaves it
    /// to `notes.md` (debounced) and feeds it into the augmented-notes merge.
    public var notes: String = ""

    public private(set) var liveSummary: String = ""
    public private(set) var summaryState: SummaryState = .none
    public private(set) var summaryPhase: SummaryPhase = .idle
    public private(set) var health: Health = .idle

    /// Loud, user-facing persistence problems (utterance writes, notes, summary,
    /// session record) shown as warning banners — never log-only.
    ///
    /// De-duplicated
    /// by message so a repeatedly-failing write surfaces once. Cleared when a new
    /// meeting begins; individually dismissable.
    public private(set) var storageNotices: [String] = []

    /// Non-fatal notice about the transcription engine actually in use — set when
    /// the chosen engine couldn't start and the app fell back to another one, so
    /// the user isn't silently downgraded. nil = running the chosen engine.
    public private(set) var engineNotice: String?

    /// Non-fatal notice that the other side isn't being captured — set when the
    /// system-audio tap is running but only yielding silence while audio is
    /// playing out (the "permission not taking effect" case). Shown alongside
    /// the live indicator so the user is never silently handed a mic-only
    /// recording. nil = system audio is being captured (or nothing's wrong yet).
    public private(set) var captureNotice: String?

    /// How the user can fix a one-sided recording, chosen by the runtime from the
    /// last-known grant: the permission is simply OFF (open Settings to enable it)
    /// vs. it reads granted but isn't taking effect — a *stale* grant after a
    /// signature change — which needs a reset + re-grant because "turn it on" is
    /// useless when it already looks on. nil = no actionable fix button (the
    /// notice is informational, e.g. a transient "recovering audio" pill).
    public enum CaptureFix: Sendable, Equatable {
        case openSettings
        case resetGrant

        public var actionTitle: String {
            switch self {
            case .openSettings: return "Open Settings"
            case .resetGrant: return "Reset & re-grant"
            }
        }
    }

    /// The fix offered by the current `captureNotice`, if any. Drives whether the
    /// banner shows an action button (Open Settings / Reset & re-grant) instead of
    /// a plain Dismiss.
    public private(set) var captureNoticeFix: CaptureFix?

    /// Set by the runtime so the capture-notice banner's button can open the right
    /// Settings pane or reset a stale system-audio grant — without the view ever
    /// touching TCC or knowing the bundle id.
    @ObservationIgnored public var performCaptureFix: (@MainActor (CaptureFix) async -> Void)?

    /// Per-session speaker rename map (`speakerID` → display name).
    public private(set) var speakerNames: [String: String] = [:]

    /// Post-finalize auto-categorization prompt (BAS-9); nil when there's nothing
    /// to surface (low confidence / no projects / manual override).
    public private(set) var categorization: MeetingCategorizationSuggestion?
    /// Set by the runtime so the banner's one-tap buttons can file the meeting into
    /// a project (sticky manual override). nil project → keep in Inbox.
    @ObservationIgnored public var assignProjectFromSuggestion: (@MainActor (String?) async -> Void)?

    public init() {}

    /// Set by the meeting runtime so the My-Notes editor can persist to
    /// `notes.md` without the view knowing about storage.
    ///
    /// Not rendered state.
    @ObservationIgnored public var notesSink: (@Sendable (String) async -> Void)?

    /// Set by the runtime / library so the click-to-edit meeting title persists to
    /// `meetings.title` without the view knowing about storage (BAS-29).
    ///
    /// The detail
    /// header binds the title `TextField` directly and calls `commitTitle()`.
    @ObservationIgnored public var titleSink: (@Sendable (String) async -> Void)?

    /// Set (for saved meetings) so a *post-finalize* speaker rename persists back to
    /// the meeting's `speakers.json`, re-indexes its citations with the real name,
    /// and re-enrolls the corrected voiceprint across meetings (BAS-43 / BAS-46).
    /// `nil` for the live model — live renames persist at finalize via the runtime.
    @ObservationIgnored public var speakerRenameSink: (@Sendable ([String: String]) async -> Void)?

    /// Serializes `speakerRenameSink` invocations in call order so rapid successive
    /// renames can't race `speakers.json` into a stale final state (each persist
    /// awaits the previous before running).
    @ObservationIgnored private var renameSinkChain: Task<Void, Never>?

    /// Persist the current scratchpad via the runtime-provided sink.
    ///
    /// The view
    /// debounces calls to this.
    public func persistNotes() async {
        await notesSink?(notes)
    }

    /// Persist the current (user-edited) title via the runtime-provided sink.
    ///
    /// The
    /// detail header calls this when the title field commits (BAS-29).
    public func commitTitle() async {
        await titleSink?(title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Set (for saved meetings) so the AI Summary can be regenerated on demand.
    /// `nil` for the live model — the Regenerate button only appears when wired.
    @ObservationIgnored public var regenerateSummary: (@MainActor (String) async -> Void)?
    public private(set) var isRegenerating = false
    public var canRegenerate: Bool { regenerateSummary != nil }

    public func regenerate(steer: String = "") async {
        guard let regenerateSummary, !isRegenerating else { return }
        isRegenerating = true
        await regenerateSummary(steer)
        isRegenerating = false
    }

    /// Reset to a fresh meeting.
    ///
    /// Called by the runtime at capture start. Everything belonging to the
    /// previous session is dropped here — including the regenerate hook and any
    /// in-flight regeneration flag, so a stale closure can never act on the new
    /// meeting — and the session id change is what makes the runtime's
    /// finalisation guards drop late writes from the previous meeting.
    public func begin(sessionId: String, title: String, startedAt: Date = Date()) {
        self.sessionId = sessionId
        self.title = title
        self.startedAt = startedAt
        turns = []
        partials = [:]
        speakers = []
        notes = ""
        liveSummary = ""
        summaryState = .none
        summaryPhase = .idle
        speakerNames = [:]
        categorization = nil
        health = .capturing
        engineNotice = nil
        captureNotice = nil
        captureNoticeFix = nil
        storageNotices = []
        scrollTargetTime = nil
        regenerateSummary = nil
        isRegenerating = false
    }

    /// Surface (or clear) the post-finalize auto-categorization banner (BAS-9).
    public func setCategorization(_ suggestion: MeetingCategorizationSuggestion?) {
        categorization = suggestion
    }

    /// File the meeting into `projectID` (nil → keep in Inbox) from the banner,
    /// then dismiss it.
    ///
    /// Marks a sticky manual override via the runtime closure.
    public func chooseProject(_ projectID: String?) async {
        await assignProjectFromSuggestion?(projectID)
        categorization = nil
    }

    public func dismissCategorization() {
        categorization = nil
    }

    /// Append a finalized utterance: clears that speaker's in-progress partial,
    /// records the turn, and registers/bumps the speaker.
    public func appendCommitted(_ utterance: Utterance) {
        let speakerID = utterance.speaker.rawValue
        let isYou = utterance.speaker == .you
        partials[speakerID] = nil
        turns.append(
            Turn(
                t: utterance.t,
                speakerID: speakerID,
                isYou: isYou,
                text: utterance.cleaned ?? utterance.text,
                confidence: utterance.conf
            )
        )
        bumpSpeaker(speakerID, isYou: isYou)
    }

    /// Replace the whole transcript with offline-refined utterances (the
    /// source-of-truth diarization pass at finalize).
    ///
    /// Rebuilds the speaker roster
    /// from the refined speaker ids while preserving any per-session renames, so a
    /// "Speaker 2 → Dana" rename made live still applies after the swap.
    public func applyRefinedTurns(_ utterances: [Utterance]) {
        partials = [:]
        speakers = []
        turns = utterances.map { utterance in
            let speakerID = utterance.speaker.rawValue
            return Turn(
                t: utterance.t,
                speakerID: speakerID,
                isYou: utterance.speaker == .you,
                text: utterance.cleaned ?? utterance.text,
                confidence: utterance.conf
            )
        }
        for utterance in utterances {
            bumpSpeaker(utterance.speaker.rawValue, isYou: utterance.speaker == .you)
        }
    }

    /// Set the volatile partial for a speaker (e.g. "● speaking…").
    ///
    /// Ensures the
    /// speaker is registered but does not count as a turn.
    public func setPartial(speaker speakerID: String, text: String) {
        partials[speakerID] = text
        ensureSpeaker(speakerID, isYou: speakerID == Utterance.Speaker.you.rawValue)
    }

    public func clearPartial(speaker speakerID: String) {
        partials[speakerID] = nil
    }

    public func appendSummaryDelta(_ delta: String) {
        summaryState = .streaming
        liveSummary += delta
    }

    public func setSummary(_ text: String, isFinal: Bool = false) {
        liveSummary = text
        summaryState = isFinal ? .final : .streaming
    }

    /// Advance the post-meeting finalisation lifecycle shown in the AI Summary
    /// header.
    ///
    /// Deliberately decoupled from `setSummary` — the in-meeting rolling
    /// summary streams text without ever entering a finalisation phase.
    public func setSummaryPhase(_ phase: SummaryPhase) {
        summaryPhase = phase
    }

    /// Mark summary generation as failed with a plain, user-facing message.
    ///
    /// The view renders the message with a retry affordance — a failed summary
    /// is never a silent ghost state.
    public func setSummaryFailed(_ message: String) {
        summaryPhase = .failed(message)
    }

    /// Surface a persistence failure as a visible warning banner.
    ///
    /// `notice` MUST be plain, human-facing sentence-case text (no raw error
    /// strings). De-duplicated by message.
    public func raiseStorageNotice(_ notice: String) {
        guard !storageNotices.contains(notice) else { return }
        storageNotices.append(notice)
    }

    /// Dismiss one storage notice (the banner's Dismiss button).
    public func dismissStorageNotice(_ notice: String) {
        storageNotices.removeAll { $0 == notice }
    }

    public func setHealth(_ health: Health) {
        self.health = health
    }

    /// The notice is rendered verbatim as a status pill, so it MUST be plain,
    /// human-facing sentence-case text — never a raw engine identifier or error
    /// description. nil clears the pill.
    public func setEngineNotice(_ notice: String?) {
        self.engineNotice = notice
    }

    /// The notice is rendered verbatim as a status pill, so it MUST be plain,
    /// human-facing sentence-case text. nil clears the pill. `fix` adds an action
    /// button to the banner (Open Settings / Reset & re-grant); it is ignored when
    /// `notice` is nil.
    public func setCaptureNotice(_ notice: String?, fix: CaptureFix? = nil) {
        self.captureNotice = notice
        self.captureNoticeFix = notice == nil ? nil : fix
    }

    /// Rename a speaker for this session.
    ///
    /// An empty name clears the override.
    public func renameSpeaker(_ speakerID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            speakerNames[speakerID] = nil
        } else {
            speakerNames[speakerID] = trimmed
        }
        if let index = speakers.firstIndex(where: { $0.speakerID == speakerID }) {
            speakers[index].displayName = displayName(for: speakerID)
        }
        // For a saved meeting, push the updated map through the sink so the rename
        // persists + re-enrolls (BAS-43 / BAS-46). No-op for the live model (nil).
        // Chained on the previous invocation so rapid renames persist in order.
        if let speakerRenameSink {
            let snapshot = speakerNames
            let previous = renameSinkChain
            renameSinkChain = Task {
                await previous?.value
                await speakerRenameSink(snapshot)
            }
        }
    }

    /// End of capture.
    ///
    /// Keeps the transcript/summary for display; clears live-only state.
    public func end() {
        health = .idle
        partials = [:]
    }

    /// The display name for a speaker: the user's rename if set, else a sensible
    /// default ("You", "Speaker 1", "Others").
    public func displayName(for speakerID: String) -> String {
        if let custom = speakerNames[speakerID], !custom.isEmpty { return custom }
        return SpeakerLabel.display(forRawSpeaker: speakerID)
    }

    private func ensureSpeaker(_ speakerID: String, isYou: Bool) {
        guard !speakers.contains(where: { $0.speakerID == speakerID }) else { return }
        speakers.append(
            Speaker(speakerID: speakerID, isYou: isYou, displayName: displayName(for: speakerID))
        )
    }

    private func bumpSpeaker(_ speakerID: String, isYou: Bool) {
        if let index = speakers.firstIndex(where: { $0.speakerID == speakerID }) {
            speakers[index].turnCount += 1
        } else {
            speakers.append(
                Speaker(speakerID: speakerID, isYou: isYou, displayName: displayName(for: speakerID), turnCount: 1)
            )
        }
    }
}
