import Foundation
import SharedCore

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
    private var lastSpeechAt = Date()
    private var silencePrompted = false
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

    public var isCapturing: Bool { sessionId != nil }
    public var currentSessionID: String? { sessionId }

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

        let micPipeline = MeetingStreamPipeline(
            speaker: .you,
            diarLabel: "mic-stream",
            transcriber: micTranscriber,
            locale: transcriptionLocale,
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
        let systemArchiveURL = diarizeSystemAudio != nil ? layout.systemAudioURL : nil
        let systemPipeline = MeetingStreamPipeline(
            speaker: .other(id: "system_audio"),
            diarLabel: "system-stream",
            transcriber: systemTranscriber,
            locale: transcriptionLocale,
            speakerResolver: speakerResolver,
            archiveURL: systemArchiveURL,
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

        Loggers.meeting.info("MeetingRuntime started: \(id, privacy: .public)")
        return id
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

    /// Called when the user picks "keep recording" on the call-ended prompt:
    /// reset the silence clock so it can prompt (and eventually auto-stop) again
    /// after more silence.
    public func resumeAfterSilencePrompt() {
        lastSpeechAt = Date()
        silencePrompted = false
        autoStopped = false
    }

    /// Flush both pipelines, stop captures, and seal the session.
    ///
    /// (The
    /// augmented-notes merge + offline diarization refinement are layered on in
    /// the merge step.)
    public func stop() async {
        // Flush the latest scratchpad immediately. Notes save on an ~800ms UI
        // debounce, so a note typed right before stopping would otherwise be lost
        // — and the augmented-notes merge below would miss it. Persist first.
        if let sid = sessionId {
            try? await repository.writeNotes(liveModel.notes, sessionId: sid)
        }
        summaryTickTask?.cancel()
        summaryTickTask = nil
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        // Stop captures first so each stream finishes, then drain the pipelines:
        // this lets the system pipeline flush the full audio archive (and the last
        // in-flight segment) instead of dropping the tail on cancellation.
        mic?.stop()
        system?.stop()
        await micPipeline?.finish()
        await systemPipeline?.finish()
        mic = nil
        system = nil
        micPipeline = nil
        systemPipeline = nil

        // Close out the committed-utterance subscriber streams for this meeting.
        for continuation in utteranceContinuations.values {
            continuation.finish()
        }
        utteranceContinuations.removeAll()

        let endedSession = sessionId
        if let endedSession {
            do {
                try await repository.finalizeSession(sessionId: endedSession)
            } catch {
                Loggers.meeting.error(
                    "Meeting finalizeSession failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        // Offline source-of-truth diarization: re-diarize the recorded system
        // audio and rewrite the transcript with stable per-speaker labels, then
        // swap the refined turns into the live model so the (about-to-run)
        // summary and the saved transcript both use the refined attribution.
        await refineDiarizationIfEnabled()
        persistSpeakerNames()
        await generateMeetingTitleIfPossible()
        liveModel.end()
        activeCapture.end()

        // Augmented-notes merge: transcript + scratchpad (+ calendar) → template →
        // AI Summary, streamed into the live model and persisted to summary.md.
        await generateAugmentedNotes()

        Loggers.meeting.info("MeetingRuntime stopped: \(endedSession ?? "<none>", privacy: .public)")
        sessionId = nil
        layout = nil
    }

    /// The augmented note: merge the diarized transcript with the
    /// user's scratchpad (+ calendar) through the active template + LLM router,
    /// streaming the result into the AI Summary column and writing summary.md.
    private func generateAugmentedNotes() async {
        guard !liveModel.turns.isEmpty else {
            liveModel.setSummary(
                "No speech was captured in this meeting, so there's nothing to summarize.", isFinal: true)
            return
        }
        // Don't ask an LLM to summarize a near-empty transcript — that's where
        // models hallucinate a meeting out of a fragment. Below ~6 words, skip.
        guard liveModel.turns.map(\.text).joined(separator: " ").split(separator: " ").count >= 6 else {
            liveModel.setSummary("Not enough was said in this meeting to summarize.", isFinal: true)
            return
        }
        guard let merger, let resolveTemplate else {
            liveModel.setSummary(
                "No summary yet — choose a model for meeting notes in Settings → Meetings.", isFinal: true)
            return
        }
        guard let template = await resolveTemplate() else {
            liveModel.setSummary(
                "Couldn't build the summary. Try again, or pick a different notes model in Settings → Meetings.",
                isFinal: true)
            return
        }
        let transcript = liveModel.turns
            .map { "\(liveModel.displayName(for: $0.speakerID)): \($0.text)" }
            .joined(separator: "\n")
        let scratchpad = liveModel.notes
        let calendar = await calendarText?() ?? ""
        // A final conversation-state digest over the whole transcript (BAS-33), so
        // the summary shares the live coach's "topic / open items" context. Empty
        // when no model is configured or the extraction fails.
        let conversationState = await finalConversationState?(transcript) ?? ""
        liveModel.setSummary("", isFinal: false)
        do {
            let result = try await merger.generate(
                template: template,
                transcript: transcript,
                scratchpad: scratchpad,
                calendarText: calendar,
                priorNotes: "",
                conversationState: conversationState,
                projectID: nil,
                onToken: { [weak self] token in await self?.appendSummaryToken(token) }
            )
            liveModel.setSummary(result.markdown, isFinal: true)
            persistSummary(result.markdown)
            Loggers.meeting.info(
                "Augmented notes generated via \(result.routeDescription, privacy: .public)"
            )
        } catch {
            Loggers.meeting.error(
                "Augmented notes merge failed: \(error.localizedDescription, privacy: .public)"
            )
            liveModel.setSummary(
                "Couldn't build the summary. If you use Apple Intelligence, turn it on in System Settings → Apple Intelligence & Siri — or choose a different notes model in Settings → Meetings.",
                isFinal: true
            )
        }
    }

    /// Offline diarization refinement at finalize (no-op unless enabled + audio
    /// was recorded + there is remote speech).
    ///
    /// Rewrites `transcript.final.jsonl`
    /// and swaps the refined turns into the live model.
    private func refineDiarizationIfEnabled() async {
        guard let diarize = diarizeSystemAudio, let layout else { return }
        do {
            guard
                let result = try await refinementService.refineDetailed(
                    liveTranscriptURL: layout.transcriptLiveURL,
                    finalTranscriptURL: layout.transcriptFinalURL,
                    systemAudioURL: layout.systemAudioURL,
                    diarize: diarize,
                    deleteRecordingAfterRefine: !keepCallRecording
                )
            else { return }
            liveModel.applyRefinedTurns(result.utterances)
            Loggers.meeting.info(
                "Offline diarization refined \(result.utterances.count, privacy: .public) utterances"
            )
            await applySpeakerMemory(speakerEmbeddings: result.speakerEmbeddings)
        } catch {
            Loggers.meeting.error(
                "Offline diarization refinement failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Cross-meeting speaker memory (BAS-11): match this meeting's per-speaker
    /// voiceprints against the project's on-device DB, auto-apply recognised
    /// names to the live transcript, and persist new/confirmed voiceprints.
    ///
    /// No-op
    /// unless the user opted in and the offline pass produced embeddings. Failures
    /// degrade silently — recognition is a nicety, never a blocker for finalize.
    private func applySpeakerMemory(speakerEmbeddings: [String: [Float]]) async {
        guard speakerMemoryEnabled, let speakerMemory, !speakerEmbeddings.isEmpty else { return }
        // Persist the per-remote_N voiceprints alongside the meeting so a
        // post-finalize rename can re-enroll off the saved meeting without the live
        // audio (BAS-43). Best-effort — never blocks finalize.
        if let layout {
            try? MeetingVoiceprints.write(speakerEmbeddings, to: layout.speakerVoiceprintsURL)
        }
        let projectScope = currentProjectId.flatMap(UUID.init(uuidString:))
        do {
            let assignments = try await speakerMemory.reconcileAndPersist(
                speakerEmbeddings: speakerEmbeddings,
                sessionNames: liveModel.speakerNames,
                projectId: projectScope,
                embeddingModel: speakerEmbeddingModel,
                lastSeen: Date()
            )
            for (label, name) in assignments {
                liveModel.renameSpeaker(label, to: name)
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
    /// empty generation keeps the fallback. Updates the live model + `meetings.title`.
    private func generateMeetingTitleIfPossible() async {
        guard let generateTitle, let sid = sessionId, !liveModel.turns.isEmpty else { return }
        // Don't clobber a title the user typed themselves — only replace the
        // date-based placeholder (BAS-29 click-to-edit takes precedence).
        guard MeetingTitleGenerator.isPlaceholderTitle(liveModel.title) else { return }
        let transcript = liveModel.turns
            .map { "\(liveModel.displayName(for: $0.speakerID)): \($0.text)" }
            .joined(separator: "\n")
        guard let title = await generateTitle(transcript) else { return }
        liveModel.title = title
        do {
            try await repository.updateMeetingTitle(title, sessionId: sid)
        } catch {
            Loggers.meeting.error(
                "Update meeting title failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Persist the per-session speaker rename map to `speakers.json` so the library
    /// indexer can show real names in citations instead of "Speaker N" (BAS-11
    /// writes it, BAS-28 consumes it).
    ///
    /// No file when nothing was renamed.
    private func persistSpeakerNames() {
        guard let layout, !liveModel.speakerNames.isEmpty else { return }
        do {
            try MeetingSpeakerNames.write(liveModel.speakerNames, to: layout.speakerNamesURL)
        } catch {
            Loggers.meeting.error(
                "Persist speakers.json failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func appendSummaryToken(_ token: String) {
        liveModel.appendSummaryDelta(token)
    }

    private func persistSummary(_ markdownText: String) {
        guard let layout else { return }
        let url = layout.sessionDirectory.appendingPathComponent("summary.md")
        do {
            try markdownText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Loggers.meeting.error(
                "Persist summary.md failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Persist the user's scratchpad to `notes.md`.
    ///
    /// The UI debounces calls.
    public func saveNotes(_ markdownText: String) async {
        guard let sessionId else { return }
        do {
            try await repository.writeNotes(markdownText, sessionId: sessionId)
        } catch {
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

    private static func makeSessionID() -> String {
        "session_" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
