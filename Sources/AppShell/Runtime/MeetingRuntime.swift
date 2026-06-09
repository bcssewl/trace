import Foundation
import SharedCore

/// Everything the post-stop finalisation tail (diarization refinement, title
/// generation, summary merge) needs, snapshotted at capture teardown.
///
/// The live model is SHARED between meetings — a new meeting may `begin()` on
/// it while the previous meeting's tail is still running — so the tail must
/// never read live state after teardown. It reads this snapshot instead, and
/// every UI write is guarded by `sessionId` so a late result from meeting A can
/// never bleed into meeting B's view. Storage writes (summary.md, speakers.json,
/// meetings.title) are keyed to the snapshot and always complete.
struct MeetingFinalizeContext: Sendable {
    let sessionId: String
    let projectId: String?
    let layout: SessionLayout
    /// Transcript turns at teardown; replaced by the offline diarization
    /// refinement when it runs.
    var turns: [MeetingLiveModel.Turn]
    /// Per-session speaker renames at teardown; speaker-memory assignments are
    /// merged in during the tail.
    var speakerNames: [String: String]
    let notes: String
    let title: String
}

/// Top-level coordinator for a live meeting (Approach ① in the build spec).
///
/// Mirrors `LiveDictationRuntime`: it owns the capture → streaming-transcription
/// pipeline for both streams and is the only writer of the live state.
///
/// Mic is tagged `you`; the system stream is tagged coarsely (`system_audio`)
/// live and refined into per-speaker turns by the offline diarization pass at
/// finalize (added in the augmented-notes step). Every committed utterance is
/// (a) appended to `MeetingLiveModel` (the single source of truth the tri-column
/// UI binds to) and (b) written incrementally to `transcript.live.jsonl` via
/// `SessionRepository` so a crash loses at most the in-flight utterance.
@MainActor
public final class MeetingRuntime {

    public let liveModel: MeetingLiveModel

    private let markdown: MarkdownStore
    private let repository: SessionRepository
    private let activeCapture: ActiveCaptureModel
    private let asrResolver: @Sendable (ASRTaskClass) async -> (any SampleTranscribing)?
    /// Language for live transcription (BAS-74); `.autoDetect` lets Whisper detect.
    private let transcriptionLocale: Locale
    private let merger: MeetingNotesMerger?
    private let resolveTemplate: (@Sendable () async -> Template?)?
    private let calendarText: (@Sendable () async -> String)?
    /// Live text-domain echo suppression: drops mic utterances that are echoes of
    /// recent system audio (the laptop-speaker leak), keeping the live transcript clean.
    private let echo = CrossStreamSuppressor()
    private let liveSummary: LiveSummaryEngine?
    /// Fires once when neither stream has produced speech for `silenceThreshold`
    /// seconds.
    ///
    /// The coordinator uses it to drop a "Call ended?" notch prompt
    /// (never a hard stop). Keyed off real captured speech (VAD), not device
    /// flags — which stay true the whole meeting because we hold the mic.
    private let onSilenceTimeout: (@Sendable () async -> Void)?
    private let silenceThreshold: TimeInterval
    /// Hard auto-stop threshold (BAS-13): when no speech is captured for this long,
    /// a real stop + finalize fires via `onAutoStop` (so a call that's truly over
    /// still summarizes). nil disables it.
    ///
    /// Separate from — and longer than — the
    /// soft `silenceThreshold` "Call ended?" prompt.
    private let autoStopThreshold: TimeInterval?
    private let onAutoStop: (@Sendable () async -> Void)?

    /// Live display-only diarizer for the system stream.
    ///
    /// When non-nil, committed
    /// remote utterances get `remote_N` labels live; nil keeps the coarse
    /// `system_audio` label (live diarization disabled in settings).
    private let liveSpeakerLabeler: LiveSpeakerLabeler?
    /// Offline source-of-truth diarizer over the recorded `sys.caf`.
    ///
    /// When non-nil
    /// (and audio was recorded), the transcript is re-attributed to stable
    /// per-speaker labels at finalize; nil disables offline refinement.
    private let diarizeSystemAudio: (@Sendable (URL) async throws -> [DiarizedSegment])?
    private let refinementService = MeetingDiarizationRefinementService()
    /// On-device cross-meeting speaker memory (BAS-11).
    ///
    /// When enabled + present,
    /// the offline pass's per-speaker voiceprints are matched against this store at
    /// finalize and saved names auto-applied; new/confirmed voiceprints persist.
    /// nil / disabled → no memory (the voiceprints stay only in this session).
    private let speakerMemory: SpeakerMemoryStore?
    private let speakerMemoryEnabled: Bool
    private let speakerEmbeddingModel: String
    /// Keep the recorded system audio (`sys.caf`) after the offline pass consumes
    /// it, for later re-refinement (BAS-41).
    ///
    /// Default `false` → the recording is
    /// deleted once refined, so meeting recordings don't accumulate on disk.
    private let keepCallRecording: Bool
    /// Generate a descriptive title from the finalized transcript (BAS-29); nil →
    /// keep the date-based fallback.
    ///
    /// Injected so the runtime stays decoupled from
    /// the LLM router (the coordinator builds it from `MeetingTitleGenerator`).
    private let generateTitle: (@Sendable (String) async -> String?)?
    /// Run a final conversation-state extraction over the full transcript and feed
    /// its digest into the augmented-notes merge (BAS-33), so the summary gets the
    /// same "topic / open questions / decisions" context the live coach had. nil →
    /// the merge runs without it.
    ///
    /// Routed via the configurable conversation-state model.
    private let finalConversationState: (@Sendable (String) async -> String)?

    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var summaryTickTask: Task<Void, Never>?
    private var silenceMonitorTask: Task<Void, Never>?
    /// Polls the system-audio tap during a meeting and surfaces a loud, non-fatal
    /// notice if it's running but only ever capturing silence while audio plays
    /// out — i.e. the System Audio Recording permission isn't taking effect, so
    /// we'd otherwise hand the user a mic-only recording silently.
    private var systemAudioHealthTask: Task<Void, Never>?
    private var systemAudioWarned = false
    private var lastSpeechAt = Date()
    private var silencePrompted = false
    /// Speech segments that failed transcription and were dropped this meeting
    /// — drives the aggregated "N segments couldn't be transcribed" pill.
    private var droppedSegmentCount = 0
    private var autoStopped = false
    private var micPipeline: MeetingStreamPipeline?
    private var systemPipeline: MeetingStreamPipeline?
    private var sessionId: String?
    /// The meeting's project (a UUID string, or nil for Inbox), captured at
    /// `start` — scopes cross-meeting speaker memory to the right project DB.
    private var currentProjectId: String?
    private var layout: SessionLayout?
    /// Live subscribers to the committed-utterance stream (e.g. the Coach).
    ///
    /// Multi-subscriber: each `utteranceStream()` call registers a continuation
    /// keyed by a UUID; every committed (non-echo) utterance is yielded to all,
    /// and `stop()` finishes them. Mutated only on the main actor.
    private var utteranceContinuations: [UUID: AsyncStream<Utterance>.Continuation] = [:]

    /// The in-flight capture teardown, if a stop is currently running.
    ///
    /// Guards
    /// double-stop: a concurrent second `stop()` awaits this instead of tearing
    /// down twice.
    private var teardownTask: Task<Void, Never>?
    /// The tracked post-stop tail (refinement → title → summary) for the most
    /// recently stopped meeting.
    ///
    /// `stop()` (full-await form) awaits it;
    /// `stop(detachedFinalize: true)` returns while it runs.
    private var finalizationTask: Task<Void, Never>?
    /// The currently-running summary generation (initial or regenerate).
    ///
    /// A new
    /// generation cancels this rather than stacking a second stream onto the UI.
    private var summaryTask: Task<Void, Never>?
    /// Monotonic id for summary generations; token writes carry the id they were
    /// spawned with and are dropped once a newer generation starts.
    private var summaryGenerationID = 0
    /// The most recently stopped session, so late notes edits (the UI debounce
    /// firing after Stop) still persist instead of vanishing.
    private var lastEndedSessionId: String?

    /// Fired on the main actor when a meeting's finalisation tail (refinement,
    /// title, summary persist) has fully completed — in both the full-await and
    /// detached `stop` forms.
    ///
    /// The coordinator hangs post-stop work
    /// (auto-categorisation, RAG indexing) off this instead of awaiting `stop()`.
    public var onFinalizeComplete: (@MainActor (String) async -> Void)?

    public var isCapturing: Bool { sessionId != nil }
    public var currentSessionID: String? { sessionId }
    /// True while a stopped meeting's heavy tail is still running.
    public var isFinalizing: Bool { finalizationTask != nil }

    public init(
        database: SqliteDatabase,
        markdownRoot: String,
        liveModel: MeetingLiveModel,
        activeCapture: ActiveCaptureModel,
        asrResolver: @escaping @Sendable (ASRTaskClass) async -> (any SampleTranscribing)?,
        transcriptionLocale: Locale = .current,
        merger: MeetingNotesMerger? = nil,
        resolveTemplate: (@Sendable () async -> Template?)? = nil,
        calendarText: (@Sendable () async -> String)? = nil,
        liveSummary: LiveSummaryEngine? = nil,
        silenceThreshold: TimeInterval = 60,
        onSilenceTimeout: (@Sendable () async -> Void)? = nil,
        autoStopThreshold: TimeInterval? = nil,
        onAutoStop: (@Sendable () async -> Void)? = nil,
        liveSpeakerLabeler: LiveSpeakerLabeler? = nil,
        diarizeSystemAudio: (@Sendable (URL) async throws -> [DiarizedSegment])? = nil,
        speakerMemory: SpeakerMemoryStore? = nil,
        speakerMemoryEnabled: Bool = false,
        speakerEmbeddingModel: String = DiarizationManager.embeddingModel,
        keepCallRecording: Bool = false,
        generateTitle: (@Sendable (String) async -> String?)? = nil,
        finalConversationState: (@Sendable (String) async -> String)? = nil
    ) {
        self.markdown = MarkdownStore(folderConfig: MarkdownFolderConfig(displayPath: markdownRoot))
        self.repository = SessionRepository(database: database, markdown: markdown)
        self.liveModel = liveModel
        self.activeCapture = activeCapture
        self.asrResolver = asrResolver
        self.transcriptionLocale = transcriptionLocale
        self.merger = merger
        self.resolveTemplate = resolveTemplate
        self.calendarText = calendarText
        self.liveSummary = liveSummary
        self.silenceThreshold = silenceThreshold
        self.onSilenceTimeout = onSilenceTimeout
        self.autoStopThreshold = autoStopThreshold
        self.onAutoStop = onAutoStop
        self.liveSpeakerLabeler = liveSpeakerLabeler
        self.diarizeSystemAudio = diarizeSystemAudio
        self.speakerMemory = speakerMemory
        self.speakerMemoryEnabled = speakerMemoryEnabled
        self.speakerEmbeddingModel = speakerEmbeddingModel
        self.keepCallRecording = keepCallRecording
        self.generateTitle = generateTitle
        self.finalConversationState = finalConversationState
    }

    /// Create the session, start both captures, and begin live transcription.
    ///
    /// Returns the new session id.
    @discardableResult
    public func start(title: String, projectId: String? = nil) async throws -> String {
        guard sessionId == nil else { return sessionId! }

        let id = try await createAndActivateSession(title: title, projectId: projectId)

        // No silent downgrade: if the chosen transcription engine can't start, the
        // meeting refuses to record rather than capturing on a worse engine without
        // the user knowing. The error tells them exactly where to fix it.
        //
        // Resolve a SEPARATE transcriber per audio stream (mic + system): each owns
        // its own decoder state, so the two concurrent streams never bleed into each
        // other's decoding. The heavy model is shared process-wide, so the second
        // transcriber is cheap (no model reload).
        guard let micTranscriber = await asrResolver(.meetingCaptureLive),
            let systemTranscriber = await asrResolver(.meetingCaptureLive)
        else {
            let message =
                "Couldn't start transcribing. Open Settings → Meetings to choose a different way to transcribe."
            await unwindFailedStart(sessionId: id)
            liveModel.setHealth(.error(message))
            Loggers.meeting.error(
                "Meeting transcription engine failed to start; aborting capture (no fallback): \(message, privacy: .public)"
            )
            throw TraceError.configInvalid(field: "asr", reason: message)
        }

        let mic = MicCapture(voiceProcessingEnabled: false)
        let system = SystemAudioCapture()
        do {
            try mic.start()
            try system.start()
        } catch {
            mic.stop()
            system.stop()
            await unwindFailedStart(sessionId: id)
            // Keep the user-facing health message plain — never surface the raw
            // error text. The full error still goes to the log below.
            liveModel.setHealth(
                .error(
                    "Couldn't start recording. Check microphone and screen-recording access in System Settings → Privacy & Security, then try again."
                ))
            Loggers.meeting.error(
                "Meeting capture start failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        self.mic = mic
        self.system = system
        droppedSegmentCount = 0

        // Capture self-repair visibility: a rebuild in progress shows a
        // transient pill, success clears it, and a failed rebuild means the
        // capture is DEAD — surfaced loudly instead of silently producing a
        // one-sided recording.
        mic.setOnHealthEvent { [weak self] event in
            Task { @MainActor in self?.handleCaptureHealth(event, source: "Microphone") }
        }
        system.setOnHealthEvent { [weak self] event in
            Task { @MainActor in self?.handleCaptureHealth(event, source: "System audio") }
        }

        let micPipeline = MeetingStreamPipeline(
            speaker: .you,
            diarLabel: "mic-stream",
            transcriber: micTranscriber,
            locale: transcriptionLocale,
            onHealthEvent: { [weak self] event in
                Task { @MainActor in self?.handlePipelineHealth(event) }
            },
            onSpeaking: { [weak self] speaking in await self?.handleSpeaking(speaking, speakerID: "you") },
            onCommitted: { [weak self] utterance in await self?.commit(utterance) }
        )
        // Live display diarization: each committed system segment is labeled
        // remote_N by the labeler (best-effort; nil → keep system_audio).
        await liveSpeakerLabeler?.reset()
        var speakerResolver: (@Sendable ([Float], TimeInterval) async -> Utterance.Speaker?)? = nil
        if let labeler = liveSpeakerLabeler {
            speakerResolver = { samples, duration in
                guard
                    let remoteID = await labeler.label(
                        samples: samples, sampleRate: 16_000, duration: duration
                    )
                else { return nil }
                return .other(id: remoteID)
            }
        }
        // Record the system stream only when offline refinement is enabled (it's
        // the only consumer of the recording).
        let systemArchiveURL = diarizeSystemAudio != nil ? layout?.systemAudioURL : nil
        let systemPipeline = MeetingStreamPipeline(
            speaker: .other(id: "system_audio"),
            diarLabel: "system-stream",
            transcriber: systemTranscriber,
            locale: transcriptionLocale,
            speakerResolver: speakerResolver,
            archiveURL: systemArchiveURL,
            // Feed source buffers back to the capture's pre-allocated pool once
            // the pipeline has copied them out — steady-state zero allocation
            // on the real-time IO thread. (Mic buffers come from AVAudioEngine's
            // tap, not the pool, so only the system pipeline recycles.)
            recycler: { [weak system] buffer in system?.recycle(buffer) },
            onHealthEvent: { [weak self] event in
                Task { @MainActor in self?.handlePipelineHealth(event) }
            },
            onSpeaking: { [weak self] speaking in await self?.handleSpeaking(speaking, speakerID: "system_audio") },
            onCommitted: { [weak self] utterance in await self?.commit(utterance) }
        )
        await micPipeline.run(mic.subscribe())
        await systemPipeline.run(system.buffers)
        self.micPipeline = micPipeline
        self.systemPipeline = systemPipeline

        // Rolling live summary: tick on a cadence; the engine itself gates on
        // elapsed time + new content, so a frequent tick is cheap.
        if let liveSummary {
            await liveSummary.reset()
            summaryTickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if Task.isCancelled { break }
                    await self?.liveSummary?.tick(now: Date())
                }
            }
        }

        // Silence-based end detection (BAS-13): fire the soft "Call ended?" prompt
        // once at `silenceThreshold`, and hard-stop at the longer `autoStopThreshold`.
        lastSpeechAt = Date()
        silencePrompted = false
        autoStopped = false
        if onSilenceTimeout != nil || (autoStopThreshold != nil && onAutoStop != nil) {
            silenceMonitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if Task.isCancelled { break }
                    await self?.checkSilence()
                }
            }
        }

        // Watchdog for the "authorized but deaf" system-audio case: poll on a
        // cadence and warn (once) if the tap is alive yet has only ever produced
        // silence while the Mac is actively playing audio out. Always runs — this
        // is the no-silent-fallback guard for meeting capture.
        systemAudioWarned = false
        systemAudioHealthTask = Task { [weak self] in
            let monitorStart = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await self?.checkSystemAudioHealth(elapsed: Date().timeIntervalSince(monitorStart))
            }
        }

        Loggers.meeting.info("MeetingRuntime started: \(id, privacy: .public)")
        return id
    }

    /// Create the session record + layout and activate the live model.
    ///
    /// Shared
    /// by `start()` (which then brings up audio capture) and the no-capture test
    /// seam below.
    private func createAndActivateSession(title: String, projectId: String?) async throws -> String {
        let id = Self.makeSessionID()
        // Markdown lives under "inbox" on disk; the meeting's project is tracked by
        // `project_id` in SQLite, so a meeting started while viewing a project files
        // straight into it (and manual moves / auto-categorization only touch the DB).
        let projectFolderName = "inbox"
        let layout = try markdown.layout(projectFolderName: projectFolderName, sessionId: id)
        let metadata = SessionMetadata(
            sessionId: id,
            projectId: projectId,
            title: title,
            startedAt: Date(),
            manualOverride: projectId != nil,
            sessionDirPath: layout.sessionDirectory.path
        )
        try await repository.createSession(metadata, projectFolderName: projectFolderName)

        self.sessionId = id
        self.currentProjectId = projectId
        self.layout = layout
        liveModel.begin(sessionId: id, title: title)
        activeCapture.beginMeeting(sessionId: id)
        return id
    }

    /// Undo `createAndActivateSession` after a start that threw before capture
    /// began. Without this the runtime stays wedged: `sessionId` is non-nil, so
    /// the NEXT `start()` short-circuits and returns the stale id — a zombie
    /// "recording" capturing nothing, this time with no error shown at all.
    /// The just-created DB row + empty session directory are removed
    /// (best-effort — the launch reconciler closes anything that survives).
    private func unwindFailedStart(sessionId id: String) async {
        sessionId = nil
        currentProjectId = nil
        layout = nil
        activeCapture.end()
        do {
            try await repository.deleteMeeting(sessionId: id)
        } catch {
            Loggers.meeting.error(
                "Failed-start unwind couldn't delete session \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Test seam: create + activate a session WITHOUT starting audio capture, so
    /// the stop/finalisation flow can be exercised deterministically (capture
    /// needs real devices and TCC grants that tests don't have).
    ///
    /// Production
    /// code must go through `start(title:projectId:)`.
    @discardableResult
    func activateSessionWithoutCapture(title: String, projectId: String? = nil) async throws -> String {
        guard sessionId == nil else { return sessionId! }
        return try await createAndActivateSession(title: title, projectId: projectId)
    }

    private func checkSilence() async {
        guard sessionId != nil else { return }
        let elapsed = Date().timeIntervalSince(lastSpeechAt)
        switch MeetingSilencePolicy.evaluate(
            secondsSinceSpeech: elapsed,
            softThreshold: silenceThreshold,
            hardThreshold: onAutoStop != nil ? autoStopThreshold : nil,
            alreadyPrompted: silencePrompted
        ) {
        case .none:
            break
        case .promptSoftEnd:
            silencePrompted = true
            await onSilenceTimeout?()
        case .hardStop:
            guard !autoStopped else { return }
            autoStopped = true
            Loggers.meeting.info(
                "Auto-stopping meeting after \(Int(elapsed), privacy: .public)s of silence"
            )
            await onAutoStop?()
        }
    }

    /// Detect the "authorized but deaf" system-audio case and surface it loudly
    /// instead of silently recording the mic only.
    ///
    /// Fires when the tap is genuinely running (frames flowing) but has *never*
    /// produced a non-silent buffer, while the Mac's default output is actively
    /// playing audio — that combination means the System Audio Recording grant
    /// isn't taking effect (e.g. a quarantined/translocated download), so the
    /// other side is being dropped. The output-active check is what keeps a
    /// genuinely quiet call (nobody talking yet) from tripping a false alarm.
    ///
    /// Self-healing: the instant any real audio is captured, the notice clears.
    private func checkSystemAudioHealth(elapsed: TimeInterval) async {
        guard sessionId != nil, let system else { return }
        let diag = system.diagnostics()
        if diag.hasObservedNonZeroAudio {
            if systemAudioWarned {
                systemAudioWarned = false
                liveModel.setCaptureNotice(nil)
            }
            return
        }
        guard !systemAudioWarned,
            elapsed >= 45,
            diag.framesObserved > 0,
            SystemAudioCapture.isDefaultOutputActive()
        else { return }
        systemAudioWarned = true
        liveModel.setCaptureNotice(
            "Only recording you — turn on System Audio Recording for Trace in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then restart the meeting."
        )
        Loggers.meeting.error(
            "System audio appears unauthorized: tap alive (frames=\(diag.framesObserved, privacy: .public)) but only silence captured while the default output is active — recording mic only. Surfaced capture notice → Screen & System Audio Recording."
        )
    }

    /// Called when the user picks "keep recording" on the call-ended prompt:
    /// reset the silence clock so it can prompt (and eventually auto-stop) again
    /// after more silence.
    public func resumeAfterSilencePrompt() {
        lastSpeechAt = Date()
        silencePrompted = false
        autoStopped = false
    }

    /// Flush both pipelines, stop captures, seal the session, and await the full
    /// finalisation tail (diarization refinement, title, summary).
    ///
    /// Source-compatible full-await form — identical external semantics to the
    /// original `stop()`. Prefer `stop(detachedFinalize: true)` from UI paths so
    /// the meeting doesn't feel stuck while the summary generates.
    public func stop() async {
        await stop(detachedFinalize: false)
    }

    /// Stop the meeting.
    ///
    /// Capture teardown + persistence (pipeline drain, notes
    /// flush, `ended_at`) always complete before this returns. The heavy tail
    /// (offline diarization refinement, title generation, summary merge) runs as
    /// a tracked finalisation task whose progress is surfaced through
    /// `MeetingLiveModel.summaryPhase`:
    /// - `detachedFinalize: false` — awaits the tail too (original semantics).
    /// - `detachedFinalize: true` — returns once capture is sealed; the tail
    ///   continues in the background and `onFinalizeComplete` fires when done.
    ///
    /// Double-stop safe: a concurrent second call awaits the in-flight teardown
    /// instead of tearing down twice.
    public func stop(detachedFinalize: Bool) async {
        if let inFlight = teardownTask {
            await inFlight.value
            if !detachedFinalize { await finalizationTask?.value }
            return
        }
        guard sessionId != nil else {
            // No active capture: still close out subscriber streams (idempotent)
            // and, in the full-await form, wait for any tail still running from
            // the meeting that just stopped.
            finishUtteranceStreams()
            if !detachedFinalize { await finalizationTask?.value }
            return
        }
        let teardown = Task { await self.teardownCapture() }
        teardownTask = teardown
        await teardown.value
        teardownTask = nil
        if !detachedFinalize {
            await finalizationTask?.value
        }
    }

    /// Synchronous part of stopping: drain capture, flush persistence, seal the
    /// session record, snapshot everything the tail needs, and kick off the
    /// tracked finalisation task.
    private func teardownCapture() async {
        guard let sid = sessionId, let layout else { return }
        // Flush the latest scratchpad immediately. Notes save on an ~800ms UI
        // debounce, so a note typed right before stopping would otherwise be lost
        // — and the augmented-notes merge would miss it. Persist first.
        do {
            try await repository.writeNotes(liveModel.notes, sessionId: sid)
        } catch {
            liveModel.raiseStorageNotice(
                "Your notes couldn't be saved — check disk space, then edit them again to retry.")
            Loggers.meeting.error(
                "Meeting notes flush at stop failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        summaryTickTask?.cancel()
        summaryTickTask = nil
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        systemAudioHealthTask?.cancel()
        systemAudioHealthTask = nil
        // Stop captures first so each stream finishes, then drain the pipelines
        // with an explicit deadline: this lets the system pipeline flush the
        // full audio archive (and the last in-flight segment) instead of
        // dropping the tail — while guaranteeing stop can never hang the app if
        // a stream misbehaves. Expected results: system → .drained (its stream
        // now finishes on stop), mic → .drainedIdle (the warm mic keeps its
        // subscriber streams open by design). A timeout is genuine tail loss;
        // the pipeline fires `.drainTimedOut`, which `handlePipelineHealth`
        // surfaces as a storage notice.
        mic?.stop()
        system?.stop()
        let micResult = await micPipeline?.finish(timeout: .seconds(15))
        let sysResult = await systemPipeline?.finish(timeout: .seconds(15))
        if micResult == .timedOut || sysResult == .timedOut {
            Loggers.meeting.error(
                "Meeting pipeline drain timed out (mic=\(String(describing: micResult), privacy: .public) system=\(String(describing: sysResult), privacy: .public))"
            )
        }
        mic = nil
        system = nil
        micPipeline = nil
        systemPipeline = nil

        finishUtteranceStreams()

        do {
            try await repository.finalizeSession(sessionId: sid)
        } catch {
            liveModel.raiseStorageNotice(
                "This meeting's record couldn't be fully saved — it may be incomplete in the library.")
            Loggers.meeting.error(
                "Meeting finalizeSession failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        liveModel.end()
        activeCapture.end()

        // Snapshot the tail's inputs NOW: the live model is shared, and a new
        // meeting may begin() on it while the tail below is still running.
        let context = MeetingFinalizeContext(
            sessionId: sid,
            projectId: currentProjectId,
            layout: layout,
            turns: liveModel.turns,
            speakerNames: liveModel.speakerNames,
            notes: liveModel.notes,
            title: liveModel.title
        )
        lastEndedSessionId = sid
        sessionId = nil
        self.layout = nil
        currentProjectId = nil

        startFinalization(context)
        Loggers.meeting.info(
            "MeetingRuntime capture stopped: \(sid, privacy: .public); finalisation continues")
    }

    /// Close out the committed-utterance subscriber streams for this meeting.
    private func finishUtteranceStreams() {
        for continuation in utteranceContinuations.values {
            continuation.finish()
        }
        utteranceContinuations.removeAll()
    }

    /// Kick off the tracked post-stop tail: diarization refinement → speaker
    /// names persist → title → augmented-notes summary → completion callback.
    ///
    /// Deliberately captures `self` strongly: the tail must complete (the
    /// summary must reach `summary.md`) even if the coordinator drops this
    /// runtime instance for a config rebuild while it runs. Every UI write
    /// inside is guarded by the snapshot's session id, so if a new meeting has
    /// begun on the shared live model, the old meeting's results flow into
    /// storage only — never into the new meeting's view.
    func startFinalization(_ context: MeetingFinalizeContext) {
        if isCurrent(context) {
            liveModel.setSummaryPhase(.preparing)
        }
        finalizationTask = Task { [self] in
            var ctx = context
            await refineDiarizationIfEnabled(&ctx)
            persistSpeakerNames(ctx)
            await generateMeetingTitleIfPossible(ctx)
            wireRegenerate(ctx)
            await runSummaryGeneration(ctx, steer: "")
            finalizationTask = nil
            await onFinalizeComplete?(ctx.sessionId)
            Loggers.meeting.info(
                "MeetingRuntime finalisation complete: \(ctx.sessionId, privacy: .public)")
        }
    }

    /// True while the shared live model still shows the snapshot's session —
    /// i.e. no newer meeting has begun. The gate for every UI write in the tail.
    private func isCurrent(_ ctx: MeetingFinalizeContext) -> Bool {
        liveModel.sessionId == ctx.sessionId
    }

    /// Make the just-ended meeting's summary regenerable in place: the standard
    /// Regenerate / Try-again affordances call back into the tail's context.
    /// Replaces any running generation instead of stacking a second stream.
    private func wireRegenerate(_ ctx: MeetingFinalizeContext) {
        guard isCurrent(ctx) else { return }
        liveModel.regenerateSummary = { [weak self] steer in
            await self?.runSummaryGeneration(ctx, steer: steer)
        }
    }

    /// Start a summary generation for `ctx`, cancelling any generation already
    /// running (regenerate replaces, never stacks), and await it.
    private func runSummaryGeneration(_ ctx: MeetingFinalizeContext, steer: String) async {
        summaryGenerationID += 1
        let generation = summaryGenerationID
        summaryTask?.cancel()
        let task = Task { await self.generateAugmentedNotes(ctx, generation: generation, steer: steer) }
        summaryTask = task
        await task.value
    }

    /// The augmented note: merge the diarized transcript with the
    /// user's scratchpad (+ calendar) through the active template + LLM router,
    /// streaming the result into the AI Summary column (while it is still
    /// showing this session) and writing summary.md.
    private func generateAugmentedNotes(
        _ ctx: MeetingFinalizeContext, generation: Int, steer: String
    ) async {
        // Every UI write is double-gated: dropped once a newer generation starts
        // (regenerate) or once the shared model has moved to another session.
        func ui(_ apply: (MeetingLiveModel) -> Void) {
            guard generation == summaryGenerationID, isCurrent(ctx) else { return }
            apply(liveModel)
        }
        guard !ctx.turns.isEmpty else {
            ui {
                $0.setSummary(
                    "No speech was captured in this meeting, so there's nothing to summarise.",
                    isFinal: true)
                $0.setSummaryPhase(.done)
            }
            return
        }
        // Don't ask an LLM to summarise a near-empty transcript — that's where
        // models hallucinate a meeting out of a fragment. Below ~6 words, skip.
        guard ctx.turns.map(\.text).joined(separator: " ").split(separator: " ").count >= 6 else {
            ui {
                $0.setSummary("Not enough was said in this meeting to summarise.", isFinal: true)
                $0.setSummaryPhase(.done)
            }
            return
        }
        guard let merger, let resolveTemplate else {
            ui {
                $0.setSummaryFailed(
                    "No model is set up for meeting notes — choose one in Settings → Meetings, then try again."
                )
            }
            return
        }
        guard let template = await resolveTemplate() else {
            ui {
                $0.setSummaryFailed(
                    "Couldn't load the notes template. Try again, or pick a different notes model in Settings → Meetings."
                )
            }
            return
        }
        let transcript = Self.transcriptText(ctx)
        let calendar = await calendarText?() ?? ""
        // A final conversation-state digest over the whole transcript (BAS-33), so
        // the summary shares the live coach's "topic / open items" context. Empty
        // when no model is configured or the extraction fails.
        let conversationState = await finalConversationState?(transcript) ?? ""
        if Task.isCancelled { return }  // superseded while gathering context
        ui {
            $0.setSummary("", isFinal: false)
            $0.setSummaryPhase(.generating)
        }
        do {
            let result = try await merger.generate(
                template: template,
                transcript: transcript,
                scratchpad: ctx.notes,
                calendarText: calendar,
                priorNotes: "",
                conversationState: conversationState,
                projectID: nil,
                steer: steer,
                onToken: { [weak self] token in
                    await self?.applySummaryToken(token, ctx: ctx, generation: generation)
                }
            )
            ui {
                $0.setSummary(result.markdown, isFinal: true)
                $0.setSummaryPhase(.done)
            }
            persistSummary(result.markdown, ctx: ctx)
            Loggers.meeting.info(
                "Augmented notes generated via \(result.routeDescription, privacy: .public)"
            )
        } catch is CancellationError {
            Loggers.meeting.info(
                "Summary generation superseded for \(ctx.sessionId, privacy: .public)")
        } catch {
            if Task.isCancelled {
                Loggers.meeting.info(
                    "Summary generation superseded for \(ctx.sessionId, privacy: .public)")
                return
            }
            Loggers.meeting.error(
                "Augmented notes merge failed: \(error.localizedDescription, privacy: .public)"
            )
            ui {
                $0.setSummaryFailed(
                    "Couldn't build the summary. If you use Apple Intelligence, turn it on in System Settings → Apple Intelligence & Siri — or choose a different notes model in Settings → Meetings."
                )
            }
            // The UI write above is dropped once a newer meeting owns the live
            // model — but the OLD meeting still silently has no summary. Mirror
            // persistSummary's pattern: leave a durable, named trace (the saved
            // meeting also shows "Summary missing — Generate now" on open).
            if generation == summaryGenerationID && !isCurrent(ctx) {
                liveModel.raiseStorageNotice(
                    "The summary for “\(ctx.title)” couldn't be generated — open the meeting to try again.")
            }
        }
    }

    /// Offline diarization refinement at finalize (no-op unless enabled + audio
    /// was recorded + there is remote speech).
    ///
    /// Rewrites `transcript.final.jsonl`,
    /// updates the snapshot the title/summary steps consume, and — while the
    /// meeting is still on screen — swaps the refined turns into the live model.
    private func refineDiarizationIfEnabled(_ ctx: inout MeetingFinalizeContext) async {
        guard let diarize = diarizeSystemAudio else { return }
        do {
            guard
                let result = try await refinementService.refineDetailed(
                    liveTranscriptURL: ctx.layout.transcriptLiveURL,
                    finalTranscriptURL: ctx.layout.transcriptFinalURL,
                    systemAudioURL: ctx.layout.systemAudioURL,
                    diarize: diarize,
                    deleteRecordingAfterRefine: !keepCallRecording
                )
            else { return }
            ctx.turns = result.utterances.map { utterance in
                MeetingLiveModel.Turn(
                    t: utterance.t,
                    speakerID: utterance.speaker.rawValue,
                    isYou: utterance.speaker == .you,
                    text: utterance.cleaned ?? utterance.text,
                    confidence: utterance.conf
                )
            }
            if isCurrent(ctx) {
                liveModel.applyRefinedTurns(result.utterances)
            }
            Loggers.meeting.info(
                "Offline diarization refined \(result.utterances.count, privacy: .public) utterances"
            )
            await applySpeakerMemory(&ctx, speakerEmbeddings: result.speakerEmbeddings)
        } catch {
            Loggers.meeting.error(
                "Offline diarization refinement failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Cross-meeting speaker memory (BAS-11): match this meeting's per-speaker
    /// voiceprints against the project's on-device DB, auto-apply recognised
    /// names to the snapshot (and the live transcript while still on screen),
    /// and persist new/confirmed voiceprints.
    ///
    /// No-op
    /// unless the user opted in and the offline pass produced embeddings. Failures
    /// degrade silently — recognition is a nicety, never a blocker for finalize.
    private func applySpeakerMemory(
        _ ctx: inout MeetingFinalizeContext, speakerEmbeddings: [String: [Float]]
    ) async {
        guard speakerMemoryEnabled, let speakerMemory, !speakerEmbeddings.isEmpty else { return }
        // Persist the per-remote_N voiceprints alongside the meeting so a
        // post-finalize rename can re-enroll off the saved meeting without the live
        // audio (BAS-43). Best-effort — never blocks finalize.
        try? MeetingVoiceprints.write(speakerEmbeddings, to: ctx.layout.speakerVoiceprintsURL)
        let projectScope = ctx.projectId.flatMap(UUID.init(uuidString:))
        do {
            let assignments = try await speakerMemory.reconcileAndPersist(
                speakerEmbeddings: speakerEmbeddings,
                sessionNames: ctx.speakerNames,
                projectId: projectScope,
                embeddingModel: speakerEmbeddingModel,
                lastSeen: Date()
            )
            for (label, name) in assignments {
                ctx.speakerNames[label] = name
                if isCurrent(ctx) {
                    liveModel.renameSpeaker(label, to: name)
                }
            }
            if !assignments.isEmpty {
                Loggers.meeting.info(
                    "Speaker memory recognised \(assignments.count, privacy: .public) returning speaker(s)"
                )
            }
        } catch {
            Loggers.meeting.error(
                "Speaker memory reconcile failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Replace the date-based fallback title with a generated, descriptive one at
    /// finalize (BAS-29).
    ///
    /// No-op without a generator or captured speech; a failed /
    /// empty generation keeps the fallback. The DB write is keyed to the
    /// snapshot's session id (robust against the runtime's own session having
    /// been cleared or replaced); the UI write only lands while the live model
    /// still shows this session.
    private func generateMeetingTitleIfPossible(_ ctx: MeetingFinalizeContext) async {
        guard generateTitle != nil, !ctx.turns.isEmpty else { return }
        // Don't clobber a title the user typed themselves — only replace the
        // date-based placeholder (BAS-29 click-to-edit takes precedence). While
        // the meeting is still on screen, the user may have renamed it after the
        // snapshot was taken, so prefer the live title for this check.
        guard MeetingTitleGenerator.isPlaceholderTitle(currentTitle(ctx)) else { return }
        let transcript = Self.transcriptText(ctx)
        guard let raw = await generateTitle?(transcript) else { return }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        // Re-check after the await: the user may have typed a title while the
        // model generated one — theirs wins.
        guard MeetingTitleGenerator.isPlaceholderTitle(currentTitle(ctx)) else { return }
        if isCurrent(ctx) {
            liveModel.title = title
        }
        do {
            try await repository.updateMeetingTitle(title, sessionId: ctx.sessionId)
        } catch {
            Loggers.meeting.error(
                "Update meeting title failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// The title to honour for the placeholder check: live (covers a rename made
    /// during finalisation) while this session is on screen, else the snapshot.
    private func currentTitle(_ ctx: MeetingFinalizeContext) -> String {
        isCurrent(ctx) ? liveModel.title : ctx.title
    }

    /// Persist the per-session speaker rename map to `speakers.json` so the library
    /// indexer can show real names in citations instead of "Speaker N" (BAS-11
    /// writes it, BAS-28 consumes it).
    ///
    /// No file when nothing was renamed.
    private func persistSpeakerNames(_ ctx: MeetingFinalizeContext) {
        guard !ctx.speakerNames.isEmpty else { return }
        do {
            try MeetingSpeakerNames.write(ctx.speakerNames, to: ctx.layout.speakerNamesURL)
        } catch {
            Loggers.meeting.error(
                "Persist speakers.json failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func applySummaryToken(_ token: String, ctx: MeetingFinalizeContext, generation: Int) {
        guard generation == summaryGenerationID, isCurrent(ctx) else { return }
        liveModel.appendSummaryDelta(token)
    }

    /// Render the snapshot's transcript with display names (rename map first,
    /// then the standard You / Speaker N / Others labels).
    private static func transcriptText(_ ctx: MeetingFinalizeContext) -> String {
        ctx.turns
            .map { "\(displayName(for: $0.speakerID, names: ctx.speakerNames)): \($0.text)" }
            .joined(separator: "\n")
    }

    private static func displayName(for speakerID: String, names: [String: String]) -> String {
        if let custom = names[speakerID], !custom.isEmpty { return custom }
        return SpeakerLabel.display(forRawSpeaker: speakerID)
    }

    /// Write `summary.md` for the snapshot's session — always, even when the UI
    /// has moved on (the file belongs to the old meeting). A failure is loud:
    /// the user is told the summary won't survive closing the meeting.
    private func persistSummary(_ markdownText: String, ctx: MeetingFinalizeContext) {
        let url = ctx.layout.sessionDirectory.appendingPathComponent("summary.md")
        do {
            try markdownText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Loggers.meeting.error(
                "Persist summary.md failed: \(error.localizedDescription, privacy: .public)"
            )
            if isCurrent(ctx) {
                liveModel.raiseStorageNotice(
                    "The summary couldn't be saved to disk — it will be lost when you leave this meeting.")
            } else {
                liveModel.raiseStorageNotice(
                    "The summary for “\(ctx.title)” couldn't be saved to disk.")
            }
        }
    }

    /// Persist the user's scratchpad to `notes.md`.
    ///
    /// The UI debounces calls, so the debounce may fire just AFTER stop — those
    /// late edits still belong to the just-ended meeting (the live model keeps
    /// showing it) and are persisted rather than silently dropped.
    public func saveNotes(_ markdownText: String) async {
        let target = sessionId ?? lastEndedSessionId
        guard let sid = target, liveModel.sessionId == sid else { return }
        do {
            try await repository.writeNotes(markdownText, sessionId: sid)
        } catch {
            liveModel.raiseStorageNotice(
                "Your notes couldn't be saved — check disk space, then edit them again to retry.")
            Loggers.meeting.error(
                "Meeting writeNotes failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Subscribe to committed utterances as they happen.
    ///
    /// Each committed
    /// (non-echo) utterance is delivered to every active subscriber in commit
    /// order; the stream finishes when the meeting stops. Multi-call safe —
    /// call once per consumer (e.g. the Coach). This is a read-only seam: it
    /// neither drives nor alters capture.
    public func utteranceStream() -> AsyncStream<Utterance> {
        let id = UUID()
        return AsyncStream<Utterance> { continuation in
            utteranceContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.utteranceContinuations[id] = nil
                }
            }
        }
    }

    private func commit(_ utterance: Utterance) async {
        guard let sessionId else { return }
        // Echo suppression: remember remote (system) utterances, and drop mic
        // utterances that are echoes of recent system audio (laptop-speaker leak).
        if utterance.speaker == .you {
            if await echo.isMicEcho(text: utterance.text, at: utterance.t) {
                Loggers.meeting.info("Dropped mic echo of recent system audio")
                return
            }
        } else {
            await echo.noteSystemUtterance(text: utterance.text, at: utterance.t)
        }
        liveModel.appendCommitted(utterance)
        lastSpeechAt = Date()
        silencePrompted = false
        // Fan the committed utterance out to any live subscribers (e.g. Coach).
        for continuation in utteranceContinuations.values {
            continuation.yield(utterance)
        }
        await liveSummary?.noteUtterance(
            speaker: liveModel.displayName(for: utterance.speaker.rawValue),
            text: utterance.text
        )
        do {
            try await repository.appendUtteranceImmediate(utterance, in: sessionId)
        } catch {
            // Loud, not log-only: the on-screen transcript still has the line but
            // the saved meeting won't — the user must know before relying on it.
            liveModel.raiseStorageNotice(
                "The saved transcript may be incomplete — a disk error stopped a line from saving.")
            Loggers.meeting.error(
                "Meeting append utterance failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleSpeaking(_ speaking: Bool, speakerID: String) {
        if speaking {
            lastSpeechAt = Date()
            silencePrompted = false
            liveModel.setPartial(speaker: speakerID, text: "● speaking…")
        } else {
            liveModel.clearPartial(speaker: speakerID)
        }
    }

    /// Capture self-repair events → user-visible state. Rebuild triggers show a
    /// transient "recovering" pill; success clears it (only if it is still ours
    /// — never clobber another notice, e.g. the permission-health pill); a
    /// failed rebuild means that capture is dead and the recording is now
    /// one-sided, which must be said loudly.
    private func handleCaptureHealth(_ event: CaptureHealthEvent, source: String) {
        let recoveringNotice = "\(source) capture recovering…"
        switch event {
        case .watchdogTriggeredRebuild, .deviceChangeTriggeredRebuild,
            .driftTriggeredRebuild, .configurationChangeTriggeredRebuild:
            liveModel.setCaptureNotice(recoveringNotice)
        case .rebuildSucceeded:
            if liveModel.captureNotice == recoveringNotice {
                // Don't just clear: if segments were dropped earlier, that pill
                // still matters and was only displaced by the transient
                // "recovering" one — restore it instead of losing it.
                liveModel.setCaptureNotice(droppedSegmentNotice())
            }
        case .rebuildFailed(let reason):
            Loggers.meeting.error(
                "\(source, privacy: .public) capture rebuild failed — capture stopped: \(reason, privacy: .public)"
            )
            liveModel.setHealth(
                .error(
                    "\(source) capture stopped and couldn't recover — stop and restart the meeting to resume recording."
                ))
        }
    }

    /// The running dropped-segments pill text — nil when nothing was dropped.
    private func droppedSegmentNotice() -> String? {
        guard droppedSegmentCount > 0 else { return nil }
        let counted =
            droppedSegmentCount == 1
            ? "A segment couldn't be transcribed"
            : "\(droppedSegmentCount) segments couldn't be transcribed"
        return "\(counted) — consider choosing a different transcription engine in Settings → Meetings."
    }

    /// Pipeline-level losses → user-visible state. Nothing here is allowed to
    /// stay log-only: every dropped segment or unprocessed tail changes what
    /// ends up in the transcript.
    private func handlePipelineHealth(_ event: PipelineHealthEvent) {
        switch event {
        case .asrSegmentDropped(let stream, let reason, let seconds):
            droppedSegmentCount += 1
            Loggers.meeting.error(
                "ASR dropped a \(String(format: "%.1f", seconds), privacy: .public)s segment on \(stream, privacy: .public): \(reason, privacy: .public)"
            )
            liveModel.setCaptureNotice(droppedSegmentNotice())
        case .audioConversionFailed(let stream, let reason):
            Loggers.meeting.error(
                "Audio conversion failing on \(stream, privacy: .public): \(reason, privacy: .public)"
            )
            liveModel.setCaptureNotice(
                "Audio capture problem — some audio is being dropped. Try changing the audio device."
            )
        case .drainTimedOut(let stream):
            Loggers.meeting.error(
                "Pipeline drain timed out on \(stream, privacy: .public) — tail audio unprocessed"
            )
            liveModel.raiseStorageNotice(
                "Some audio at the end of the meeting wasn't processed — the transcript may stop early."
            )
        case .archiveFailed(let stream, let reason):
            Loggers.meeting.error(
                "Call-recording archive failing on \(stream, privacy: .public): \(reason, privacy: .public)"
            )
            liveModel.raiseStorageNotice(
                "The call recording can't be saved — check disk space. Speaker refinement after the meeting may be skipped."
            )
        }
    }

    private static func makeSessionID() -> String {
        "session_" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
