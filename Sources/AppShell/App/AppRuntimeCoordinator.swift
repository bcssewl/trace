@preconcurrency import AVFoundation
import AppKit
import Carbon
import CoachModule
import DictationModule
import FileBatchModule
import Foundation
import MeetingModule
import SharedCore

@MainActor
public final class AppRuntimeCoordinator {

    public let environment: AppEnvironment
    public let commands: AppCommands

    private var database: SqliteDatabase?
    /// On-device cross-meeting speaker memory (BAS-11).
    ///
    /// Built once at bootstrap
    /// over the shared DB; passed into each `MeetingRuntime` and used by the
    /// settings "Forget remembered speakers" action + the remembered-count refresh.
    private var speakerMemoryStore: SpeakerMemoryStore?
    private var router: ModelRouter?
    private var asrRouter: ASRRouter?
    private var asrBackendResolver: RuntimeASRBackendResolver?
    private var dictationRuntime: LiveDictationRuntime?
    private var meetingRuntime: MeetingRuntime?
    /// Bumped on every meeting start AND stop.
    ///
    /// A meeting's async startup captures
    /// the current value and re-checks it before showing the coach — so if the
    /// meeting is stopped (or restarted) while it's still spinning up (the model
    /// cold-load can take seconds), the now-stale startup won't pop the coach pill
    /// for a meeting that's no longer active.
    private var meetingSessionEpoch = 0
    /// Read-only session repository for the "All meetings" library (separate
    /// instance from the live runtime's; SQLite + markdown are shared on disk).
    private var libraryRepository: SessionRepository?
    private var playbookStore: PlaybookStore?
    private var fileBatchController: FileBatchController?
    private var fileProcessingState: ProcessingState?
    /// Forwards `ProcessingState` broadcasts to `AppStateModel.fileBatch` so the
    /// Files / Voice Memos lists show live queue progress (BAS-22).
    private var fileBatchLiveTask: Task<Void, Never>?
    /// Live folder watchers (general watched folders + the iCloud Voice-Memo
    /// folder when sync is on).
    ///
    /// Rebuilt on `.traceWatchedFoldersChanged`.
    private var watchedFolderSessions: [WatchedFolderSession] = []
    /// Project IDs whose per-project route overrides are currently applied to the
    /// routers — so a re-hydrate can clear overrides for deleted projects (BAS-23).
    private var hydratedProjectIDs: Set<UUID> = []
    /// The project of the meeting currently capturing (nil = none / Inbox).
    ///
    /// Lets
    /// a mid-meeting global Coach-settings change re-resolve the project-aware
    /// config instead of clobbering it with the global one (BAS-23).
    private var activeMeetingProjectID: String?
    private var hotkeyCenter: GlobalHotkeyCenter?
    private var tripleTapMonitor: TripleTapMonitor?
    /// Tap-or-hold monitor when dictation is bound to a lone modifier key.
    private var dictationTriggerMonitor: ModifierTriggerMonitor?
    /// True while the current lone-modifier press is the one that *started*
    /// dictation — so its release can decide tap (keep recording) vs hold (stop).
    private var dictationTriggerStartedRecording = false
    /// Active only while a dictation is recording with "Return sends" enabled:
    /// swallows a plain Return, then stops + submits. Torn down on every stop.
    private var enterKeyInterceptor: EnterKeyInterceptor?
    /// Press longer than this is a hold (push-to-talk); shorter is a tap (toggle).
    private static let dictationHoldThreshold: TimeInterval = 0.3
    private var bootstrapTask: Task<Void, Never>?
    /// Opt-in meeting auto-detection.
    ///
    /// The reducer inside `AppActivityMonitor`
    /// latches `.meetingLikelyStarted` once per instance, so a FRESH monitor is
    /// created for each detection window (re-armed after every meeting).
    private var autoDetectMonitor: AppActivityMonitor?
    private var autoDetectTask: Task<Void, Never>?
    private var meetingPromptTimeoutTask: Task<Void, Never>?
    /// The app whose "Call detected" prompt is currently showing — so a dismiss
    /// is attributed to the right bundle ID for its per-app cooldown.
    private var promptedAppBundleID: String?
    /// Per-app transient cooldown after a dismiss (bundle ID → quiet-until).
    ///
    /// A
    /// different app is unaffected, so a real meeting elsewhere still prompts.
    private var meetingDetectSuppressedUntil: [String: Date] = [:]
    /// How long a dismissed app stays quiet.
    ///
    /// Rolls forward while the call's
    /// signals remain live (so an ongoing call isn't re-nagged), then lapses
    /// shortly after the call ends so the next call prompts fresh.
    private static let meetingDismissCooldown: TimeInterval = 120
    /// Optional reference set by AppDelegate so the coordinator can drive the
    /// HUD on dictation/meeting/voice-memo lifecycle events.
    public weak var notchHUD: NotchHUDController?
    /// Set by AppDelegate so the coordinator can present + drive the
    /// screen-share-invisible coach overlay during meetings.
    public weak var coachOverlay: CoachOverlayController?
    private var coachOrchestrator: CoachOrchestrator?
    private var coachVectorSearch: VectorSearch?
    /// Library search / cross-meeting Q&A stack (BAS-19), built lazily over the
    /// shared database + router once bootstrap completes.
    private var libraryVectorSearch: VectorSearch?
    private var libraryStore: LibraryStore?
    private var qaPipeline: QASearchPipeline?
    private var meetingChunkIndexer: MeetingChunkIndexer?
    private var libraryEntryIndexer: LibraryEntryIndexer?
    private var coachSubscriptionTask: Task<Void, Never>?
    /// Rolling window of recent utterance text — feeds topic-shift detection and
    /// the manual-trigger "help me now" context.
    private var coachRecentText: [String] = []
    /// Routed conversation-state extractor + its ~30s ticker, feeding the coach
    /// orchestrator live context (topic / open questions / tensions / decisions)
    /// during a meeting (BAS-16).
    ///
    /// Built lazily alongside the orchestrator.
    private var coachConversationStateExtractor: ConversationStateExtractor?
    private var coachConversationStateTask: Task<Void, Never>?

    public init(environment: AppEnvironment) {
        self.environment = environment
        self.commands = AppCommands()
        wireCommandClosures()
        wireMeetingLibrary()
        wirePlaybooks()
        wireLibrarySearch()
        wireFileBatch()
        observeNotifications()
        registerGlobalControls()
        self.bootstrapTask = Task { [weak self] in
            await self?.bootstrapServices()
        }
        // Backfill meeting embeddings after bootstrap, in a SEPARATE task so
        // callers awaiting `bootstrapTask.value` (first dictation/meeting) aren't
        // blocked by the reconcile pass.
        Task { [weak self] in
            await self?.bootstrapTask?.value
            // Title backfill first, so the reconcile/embed pass indexes meetings
            // with their generated titles (search citations show the real title,
            // not the date placeholder) rather than re-indexing later.
            await self?.backfillMeetingTitles()
            await self?.reconcileMeetingIndex()
            await self?.reconcileEntryIndex()
            // Index playbook folders so the Coach can ground on them (BAS-18).
            // Content-hash gated, so a steady-state launch only re-embeds changed
            // docs; an all-cached pass needs no embedding model at all.
            await self?.reconcilePlaybookIndex()
        }
    }

    private func wireCommandClosures() {
        commands.startDictation = { [weak self] in self?.runStartDictation() }
        commands.stopDictation = { [weak self] in self?.runStopDictation() }
        commands.startVoiceMemo = { [weak self] in self?.runStartVoiceMemo() }
        commands.stopVoiceMemo = { [weak self] in self?.runStopVoiceMemo() }
        commands.startMeeting = { [weak self] in self?.runStartMeeting() }
        commands.stopMeeting = { [weak self] in self?.runStopMeeting() }
        commands.transcribeFile = { [weak self] in self?.runTranscribeFile() }
        commands.openLibrary = { [weak self] in self?.runOpenLibrary() }
        commands.openSettings = { [weak self] in self?.runOpenSettings() }
        commands.quit = { NSApp.terminate(nil) }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        observeName(.traceStartDictation) { [weak self] _ in self?.runStartDictation() }
        observeName(.traceStopDictation) { [weak self] _ in self?.runStopDictation() }
        observeName(.traceStartVoiceMemo) { [weak self] _ in self?.runStartVoiceMemo() }
        observeName(.traceStopVoiceMemo) { [weak self] _ in self?.runStopVoiceMemo() }
        observeName(.traceStartMeeting) { [weak self] _ in self?.runStartMeeting() }
        observeName(.traceStopMeeting) { [weak self] _ in self?.runStopMeeting() }
        observeName(.traceCoachManualTrigger) { [weak self] _ in self?.runManualCoachTrigger() }
        observeName(.traceCoachAsk) { [weak self] note in
            self?.runManualCoachTrigger(intent: note?.object as? CoachIntent)
        }
        observeName(.traceCoachConfigChanged) { [weak self] _ in
            self?.applyCoachConfigChange()
            // Coach routing + card-content routes ride this notification too (BAS-35).
            Task { [weak self] in await self?.applyRoutes(matching: .traceCoachConfigChanged) }
        }
        observeName(.traceRequestTranscribeFile) { [weak self] _ in self?.runTranscribeFile() }
        observeName(.traceDictationPrefsChanged) { [weak self] _ in self?.resetDictationRuntime() }
        observeName(.traceWatchedFoldersChanged) { [weak self] _ in self?.restartWatchedFolders() }
        observeName(.traceProjectOverridesChanged) { [weak self] _ in
            Task { [weak self] in await self?.hydrateProjectOverrides() }
        }
        observeName(.traceMeetingAutoDetectChanged) { [weak self] _ in self?.rearmMeetingAutoDetect() }
        observeName(.traceMeetingPromptDismiss) { [weak self] _ in self?.dismissMeetingPrompt(reArmAfterCooldown: true)
        }
        observeName(.traceMeetingEndPromptKeep) { [weak self] _ in self?.keepRecordingAfterSilence() }
        observeName(.traceLibraryQAConfigChanged) { [weak self] _ in
            Task { [weak self] in
                // Drop the cached pipeline so it rebuilds with the new relevance
                // floor (BAS-30), then re-point the .libraryQA route (BAS-49).
                self?.qaPipeline = nil
                await self?.applyRoutes(matching: .traceLibraryQAConfigChanged)
            }
        }
        observeName(.traceConversationStateConfigChanged) { [weak self] _ in
            Task { [weak self] in await self?.applyRoutes(matching: .traceConversationStateConfigChanged) }
        }
        observeName(.traceEmbeddingConfigChanged) { [weak self] _ in
            // Rebuild cached RAG components against the new fingerprint, then route.
            self?.invalidateEmbeddingConsumers()
            Task { [weak self] in await self?.applyEmbeddingRoute() }
        }
        observeName(.traceCacheBudgetChanged) { [weak self] _ in self?.pruneAudioArchiveToBudget() }
        observeName(.traceMeetingConfigChanged) { [weak self] _ in
            // Drop the cached runtime so the NEXT meeting rebuilds with the new
            // ASR engine / live-summary config, and re-point the meeting notes &
            // summary routes at the newly chosen provider/model.
            self?.invalidateMeetingRuntime()
            // Toggling the diarization feature on starts a background model
            // prepare so it's ready by the next meeting (no-op otherwise).
            self?.prepareDiarizationModelsIfNeeded()
            // Re-apply notes/title/categorization routes for the newly chosen models.
            Task { [weak self] in await self?.applyRoutes(matching: .traceMeetingConfigChanged) }
        }
        observeName(.traceClearSpeakerMemory) { [weak self] _ in
            Task { [weak self] in await self?.clearSpeakerMemory() }
        }
        let token = center.addObserver(
            forName: .traceTranscribeFiles, object: nil, queue: .main
        ) { [weak self] note in
            let urls = (note.userInfo?["urls"] as? [URL]) ?? []
            MainActor.assumeIsolated {
                self?.runTranscribeFiles(urls: urls)
            }
        }
        _ = token
    }

    private func observeName(_ name: Notification.Name, action: @escaping @MainActor @Sendable (Notification?) -> Void)
    {
        _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                action(nil)
            }
        }
    }

    private func registerGlobalControls() {
        let registrar = CarbonHotkeyRegistrar()
        let center = GlobalHotkeyCenter(registrar: registrar)
        registrar.setEventHandler { id in
            Task { await center.handleCarbonEvent(id: id) }
        }
        hotkeyCenter = center

        applyHotkeyBindings()

        // Re-register whenever the user edits a binding in Settings.
        observeName(AppStateModel.hotkeysChangedNotification) { [weak self] _ in
            self?.applyHotkeyBindings()
        }

        // Built from the user's Coach manual-trigger config; rebuilt when it changes.
        rebuildTripleTapMonitor()

        // Global ⌥esc dismiss for the coach overlay — registered globally (not a
        // local monitor) so it minimizes the overlay to its pill even when the call
        // app is frontmost mid-call. esc = keyCode 53. Minimize is the existing
        // .traceCoachOverlayHide path.
        Task {
            await self.registerHotkey(
                center: center,
                id: "coachOverlayDismiss",
                descriptor: HotkeyDescriptor(keyCode: 53, modifiers: [.option])
            ) {
                NotificationCenter.default.post(name: .traceCoachOverlayHide, object: nil)
            }
        }
    }

    /// (Re)registers every global hotkey from the user's current bindings,
    /// falling back to each action's default.
    ///
    /// Safe to call repeatedly — it
    /// unregisters the previous binding for each action first.
    private func applyHotkeyBindings() {
        guard let center = hotkeyCenter else { return }
        let state = environment.state
        let actions: [(HotkeyAction, @MainActor @Sendable () -> Void)] = [
            (.dictationToggle, { [weak self] in self?.toggleDictation() }),
            (.meetingToggle, { [weak self] in self?.toggleMeeting() }),
            (.voiceMemoToggle, { [weak self] in self?.toggleVoiceMemo() }),
            (.transcribeFile, { [weak self] in self?.runTranscribeFile() }),
            (.openLibrary, { [weak self] in self?.runOpenLibrary() }),
        ]
        Task {
            for (action, handler) in actions {
                let descriptor = state.descriptor(for: action.rawValue, default: action.defaultDescriptor)
                await center.unregister(id: HotkeyID(action.rawValue))
                // A lone-modifier binding can't be registered via Carbon — it's
                // driven by a flagsChanged monitor instead. Only the dictation
                // action supports this.
                if action == .dictationToggle {
                    if descriptor.isModifierTap {
                        self.installDictationTriggerMonitor(descriptor)
                        continue
                    }
                    self.dictationTriggerMonitor?.stop()
                    self.dictationTriggerMonitor = nil
                }
                await self.registerHotkey(center: center, id: action.rawValue, descriptor: descriptor, action: handler)
            }
        }
    }

    /// Starts (or replaces) the lone-modifier dictation trigger, which works both
    /// ways on the same key (the Spokenly model):
    ///
    /// - a quick **tap** toggles dictation on and leaves it running until the user
    ///   taps again or hits Stop — never auto-stopping;
    /// - a **hold** is push-to-talk: dictation runs while the key is held and stops
    ///   the instant it's released.
    ///
    /// Driven by a flagsChanged monitor since a bare modifier can't be a Carbon
    /// hotkey. The press/release timing (vs `dictationHoldThreshold`) is what
    /// distinguishes a tap from a hold.
    private func installDictationTriggerMonitor(_ descriptor: HotkeyDescriptor) {
        dictationTriggerMonitor?.stop()
        guard let tap = descriptor.modifierTap else {
            dictationTriggerMonitor = nil
            return
        }
        let monitor = ModifierTriggerMonitor(
            key: tap,
            onDown: { [weak self] in
                MainActor.assumeIsolated { self?.handleDictationTriggerDown() }
            },
            onUp: { [weak self] held in
                MainActor.assumeIsolated { self?.handleDictationTriggerUp(held: held) }
            }
        )
        monitor.start()
        dictationTriggerMonitor = monitor
        Loggers.bridges.info("Dictation bound to tap-or-hold: \(tap.displayName, privacy: .public)")
    }

    /// Lone-modifier pressed: toggle dictation. Remember whether this press is the
    /// one that *started* recording, so its release can decide tap (keep recording)
    /// vs hold (stop). When it instead stops a running session, the release is a
    /// no-op (tap-to-stop already happened here).
    private func handleDictationTriggerDown() {
        dictationTriggerStartedRecording = environment.state.activeCapture.mode != .dictation
        toggleDictation()
    }

    /// Lone-modifier released: only meaningful for the press that started
    /// dictation. A long hold is push-to-talk → stop on release; a quick tap leaves
    /// dictation running (toggle), to be stopped by a later tap or Stop.
    private func handleDictationTriggerUp(held: TimeInterval) {
        guard dictationTriggerStartedRecording else { return }
        dictationTriggerStartedRecording = false
        if held >= Self.dictationHoldThreshold {
            runStopDictation()
        }
    }

    private func registerHotkey(
        center: GlobalHotkeyCenter,
        id: String,
        descriptor: HotkeyDescriptor,
        action: @escaping @MainActor @Sendable () -> Void
    ) async {
        do {
            try await center.register(id: HotkeyID(id), descriptor: descriptor) {
                Task { @MainActor in action() }
            }
            Loggers.bridges.info("Registered global hotkey \(id, privacy: .public)")
        } catch {
            Loggers.bridges.error(
                "Failed to register hotkey \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func bootstrapServices() async {
        if let shared = environment.database {
            self.database = shared
            Loggers.bootstrap.info("AppRuntimeCoordinator reusing BootContext database")
        } else {
            do {
                let url = try environment.paths.indexDatabaseURL()
                let db = try await SqliteDatabase.open(at: url)
                try await AppSchema.bootstrap(database: db)
                self.database = db
                Loggers.bootstrap.warning("AppRuntimeCoordinator opened fallback database (BootContext was empty)")
            } catch {
                Loggers.bootstrap.error(
                    "AppRuntimeCoordinator bootstrap failed: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }
        // On-device cross-meeting speaker memory (BAS-11): build the store now so
        // the remembered-count + "Forget" action work before the first meeting.
        if let db = self.database {
            self.speakerMemoryStore = SpeakerMemoryStore(database: db)
        }
        // Meeting notes use a single in-code template built from the user's
        // editable summary instructions (see `meetingTemplate()`), so there's no
        // template store to seed.
        // Single source of truth for the registered provider set (BAS-40) — the
        // headless `trace mcp` server builds its router through the same factory,
        // which now also registers BAS-37's Anthropic + Codex providers.
        let router = await ModelRouterFactory.makeDefaultRouter()
        self.router = router
        let asrRouter = ASRRouter()
        self.asrRouter = asrRouter
        self.asrBackendResolver = RuntimeASRBackendResolver(router: asrRouter)
        // Apply each routable stage's provider/model now that the router is
        // built, so the first use routes correctly. Dictation cleanup is applied
        // lazily when the dictation runtime is constructed (it carries the
        // deterministic-skip flag), so it's excluded here.
        for stage in LLMRouteStage.allCases where stage != .dictationCleanup {
            await applyRoute(forStage: stage)
        }
        // Apply the user's embedding provider/model so RAG indexing/search route
        // correctly from first use (BAS-17).
        await applyEmbeddingRoute()
        // Prune retained recordings to the cache budget at launch (BAS-44).
        pruneAudioArchiveToBudget()
        // Arm opt-in meeting auto-detection (no-op when the pref is OFF).
        rearmMeetingAutoDetect()
        // Warm the diarization models in the background if the (beta) feature is
        // already enabled, so the first meeting is ready (no-op otherwise).
        prepareDiarizationModelsIfNeeded()
        // Surface how many speaker voiceprints are remembered on this Mac.
        await refreshRememberedSpeakerCount()
        // Start any configured watched folders + iPhone Voice-Memo sync.
        restartWatchedFolders()
        // Apply per-project model/ASR route overrides to the freshly built routers.
        await hydrateProjectOverrides()
    }

    /// Load every project's persisted overrides and apply them to the routers
    /// (BAS-23): `ModelRouter` per-task LLM routes + `ASRRouter` per-task ASR
    /// routes.
    ///
    /// Clears overrides for projects that no longer exist so a delete
    /// (or an emptied override set) takes effect. Re-run on
    /// `.traceProjectOverridesChanged`.
    private func hydrateProjectOverrides() async {
        guard let store = environment.projectStore, let router, let asrRouter else { return }
        let records = (try? await store.list()) ?? []
        let currentIDs = Set(records.map(\.id))
        for staleID in hydratedProjectIDs.subtracting(currentIDs) {
            await router.clearProjectLLMOverrides(projectID: staleID)
            await asrRouter.clearProjectOverrides(projectID: staleID)
        }
        for record in records {
            let overrides = record.overrides
            await router.setProjectLLMOverrides(overrides.modelRouteOverrides, projectID: record.id)
            await asrRouter.setProjectOverrides(overrides.asrRouteOverrides, projectID: record.id)
        }
        hydratedProjectIDs = currentIDs
        Loggers.bootstrap.info(
            "Hydrated per-project overrides for \(records.count, privacy: .public) project(s)"
        )
    }

    /// (Re)arms opt-in meeting auto-detection.
    ///
    /// Cancels any in-flight detector,
    /// then — only when the pref is ON and we are not already capturing —
    /// creates a FRESH `AppActivityMonitor` (its reducer latches and fires
    /// `.meetingLikelyStarted` only once per instance) and polls it every ~2s.
    /// On detection it starts the meeting and stops polling; `runStopMeeting`
    /// re-arms for the next call. Default OFF means this never surprise-records.
    private func rearmMeetingAutoDetect() {
        autoDetectTask?.cancel()
        autoDetectTask = nil
        guard environment.state.meetingAutoDetectEnabled, meetingRuntime?.isCapturing != true else {
            autoDetectMonitor = nil
            return
        }
        let monitor = AppActivityMonitor(
            source: LiveMeetingSignalSource(additionalMeetingAppIDs: environment.state.meetingCustomApps))
        autoDetectMonitor = monitor
        Loggers.meeting.info("Meeting auto-detect armed")
        autoDetectTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                let event = await monitor.tick(time: Date().timeIntervalSince1970)
                if Task.isCancelled { break }
                if event == .meetingLikelyStarted {
                    Loggers.meeting.info("Meeting auto-detect fired")
                    self?.handleMeetingDetected()
                    break
                }
            }
        }
    }

    /// Auto-detect fired.
    ///
    /// Either start immediately (user opted into auto-start)
    /// or drop a notch "Call detected · <app>" prompt asking to start; the
    /// "Later"/✕ button or a timeout backs off briefly so a false positive
    /// (e.g. a WhatsApp voice note) doesn't nag.
    private func handleMeetingDetected() {
        // Never prompt while something else is already capturing (dictation,
        // voice memo, or a meeting). Avoids mic contention and spurious
        // "call detected" prompts while you're dictating.
        guard environment.state.activeCapture.mode == .idle else { return }
        if environment.state.meetingAutoStartOnDetect {
            runStartMeeting()
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? "unknown"
        // Explicit mute: the user switched this app off in Settings → never offer.
        // Keep watching so a DIFFERENT app (a genuine meeting) still prompts.
        if environment.state.isMeetingAppMuted(bundleID) {
            Loggers.meeting.info("Auto-detect: \(bundleID, privacy: .public) muted by user; skipping")
            scheduleAutoDetectRearm(after: 20)
            return
        }
        // Recently dismissed for this app — stay quiet. Roll the cooldown forward
        // while the call's signals are still live, so a dismissed call stays quiet
        // for its whole duration and only re-prompts once the call has ended
        // (signals stop → no more refreshes → cooldown lapses).
        if let until = meetingDetectSuppressedUntil[bundleID], until > Date() {
            meetingDetectSuppressedUntil[bundleID] = Date().addingTimeInterval(Self.meetingDismissCooldown)
            scheduleAutoDetectRearm(after: 20)
            return
        }
        promptedAppBundleID = bundleID
        let timeout = environment.state.meetingPromptTimeoutSeconds
        notchHUD?.showMeetingPrompt(
            title: "Call detected", detail: app?.localizedName, icon: app?.icon, duration: Double(timeout))
        meetingPromptTimeoutTask?.cancel()
        meetingPromptTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            if Task.isCancelled { return }
            self?.dismissMeetingPrompt(reArmAfterCooldown: true)
        }
    }

    /// Clears the notch prompt; optionally re-arms detection after a cooldown so
    /// lingering signals don't immediately re-prompt.
    private func dismissMeetingPrompt(reArmAfterCooldown: Bool) {
        meetingPromptTimeoutTask?.cancel()
        meetingPromptTimeoutTask = nil
        notchHUD?.dismissMeetingPrompt()
        if let app = promptedAppBundleID {
            // Quiet THIS app until the call ends (the cooldown rolls forward while
            // its signals stay live). A different app is unaffected and still
            // prompts. We never auto-mute — muting is explicit, in Settings.
            meetingDetectSuppressedUntil[app] = Date().addingTimeInterval(Self.meetingDismissCooldown)
            Loggers.meeting.info("Auto-detect dismissed for \(app, privacy: .public); quiet until call ends")
        }
        promptedAppBundleID = nil
        guard reArmAfterCooldown else { return }
        // Re-arm soon (NOT a long global cooldown) so a genuine meeting in
        // another app is still caught; per-app suppression handles the rest.
        scheduleAutoDetectRearm(after: 15)
    }

    /// Re-arm auto-detect after a short delay, replacing the previous global
    /// cooldown so other apps / a genuine meeting are still caught quickly.
    private func scheduleAutoDetectRearm(after seconds: Double) {
        autoDetectTask?.cancel()
        autoDetectTask = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.rearmMeetingAutoDetect()
        }
    }

    /// Silence-based end: the runtime saw ~60s of no speech on either stream.
    ///
    /// Drop a "Call ended?" notch prompt (Stop & save / Keep recording) —
    /// never a hard stop.
    private func handleMeetingSilence() {
        guard meetingRuntime?.isCapturing == true else { return }
        let timeout = environment.state.meetingPromptTimeoutSeconds
        notchHUD?.showMeetingPrompt(
            title: "Call ended?", detail: "Stop & save your notes", icon: nil, kind: .end, duration: Double(timeout))
        meetingPromptTimeoutTask?.cancel()
        meetingPromptTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            if Task.isCancelled { return }
            self?.keepRecordingAfterSilence()
        }
    }

    /// Hard auto-stop (BAS-13): an auto-detected meeting had no captured speech for
    /// the configured window, so finalize it (which generates the notes) exactly
    /// like the Stop button.
    ///
    /// Distinct from the soft "Call ended?" prompt above —
    /// this is the real stop a never-ending auto-detected meeting needs to summarize.
    private func handleMeetingAutoStop() {
        guard meetingRuntime?.isCapturing == true else { return }
        Loggers.meeting.info("Meeting auto-stopped after sustained silence; finalizing")
        runStopMeeting()
    }

    /// "Keep recording" (or the end-prompt timed out): restore the recording HUD
    /// and keep the meeting going; reset the silence clock.
    private func keepRecordingAfterSilence() {
        meetingPromptTimeoutTask?.cancel()
        meetingPromptTimeoutTask = nil
        guard meetingRuntime?.isCapturing == true else {
            notchHUD?.dismissMeetingPrompt()
            return
        }
        notchHUD?.showCompact(timer: "0:00", kind: .meeting)
        meetingRuntime?.resumeAfterSilencePrompt()
    }

    /// Applies one route stage's provider + model to the shared `ModelRouter`,
    /// setting every `LLMTaskClass` the stage drives (e.g. meeting notes drives
    /// both `.meetingSummary` and `.meetingAugmentedMerge`).
    ///
    /// The single
    /// generalized route updater behind dictation cleanup, meeting
    /// notes/title/categorization, library Q&A, and conversation state (BAS-49) —
    /// replacing six near-identical `update<stage>Route()` methods. For
    /// `.dictationCleanup`/`.deterministic` the nominal Apple FM route is set but
    /// `RouterCleanup` skips the LLM via its deterministic flag; for any provider
    /// that can't service the call the provider throws and the consumer falls
    /// back, so the offline guarantee is preserved.
    private func applyRoute(forStage stage: LLMRouteStage) async {
        guard let router else { return }
        let provider = environment.state.provider(for: stage)
        let model = environment.state.model(for: stage, provider: provider)
        let route = Self.providerRoute(provider, model: model)
        for taskClass in stage.taskClasses {
            await router.setRoute(route, for: taskClass)
        }
        Loggers.bootstrap.info(
            "Route \(stage.rawValue, privacy: .public) → \(provider.rawValue, privacy: .public) model=\(model, privacy: .public)"
        )
    }

    /// Applies every route stage whose config-changed notification is `notification`.
    ///
    /// One place so single- and multi-stage notifications behave identically and a
    /// stage added to an existing notification is picked up for free.
    private func applyRoutes(matching notification: Notification.Name) async {
        for stage in LLMRouteStage.allCases where stage.configChangedNotification == notification {
            await applyRoute(forStage: stage)
        }
    }

    /// The `LLMRoute` for a provider preference + model — the single mapping every
    /// per-task route (dictation cleanup, meeting notes, library Q&A) shares.
    ///
    /// All
    /// endpoint/account knowledge lives in `ModelProvider` (the catalog); the
    /// `.deterministic` no-LLM case maps to the Apple FM route (the cleanup step
    /// then skips the call via its own deterministic flag).
    private static func providerRoute(_ provider: DictationCleanupProvider, model: String) -> LLMRoute {
        (provider.modelProvider ?? .appleFM).route(model: model)
    }

    /// Public API for Settings: dispose the existing dictation runtime so the
    /// next capture rebuilds with the latest ASR engine / cleanup preferences.
    public func resetDictationRuntime() {
        dictationRuntime = nil
        Loggers.bootstrap.info("Dictation runtime invalidated; will rebuild on next capture")
    }

    func ensureDictationRuntime() async -> LiveDictationRuntime? {
        if let runtime = dictationRuntime { return runtime }
        await bootstrapTask?.value
        guard let db = database else { return nil }
        // Apply the cleanup-provider preference by overriding the
        // `.dictationCleanup` route on the shared ModelRouter before
        // constructing the runtime. `.deterministic` keeps the default Apple
        // FM route but RouterCleanup will skip the LLM call via this flag.
        let asrEngine = environment.state.dictationASREngine
        await applyRoute(forStage: .dictationCleanup)
        do {
            let deterministicCleanup = environment.state.dictationCleanupProvider == .deterministic
            let showLivePartials = environment.state.dictationShowLivePartials
            // Push interim transcript into the notch dropdown as the user
            // speaks. Hops to MainActor since the recognizer callback is
            // off-main.
            let onPartial: @Sendable (String) -> Void = { [weak self] text in
                Task { @MainActor in
                    self?.notchHUD?.updatePartial(text)
                }
            }
            // Pipe the live mic level into the notch VU meter so its bars actually
            // move with the user's voice — previously the meter was never fed and
            // sat dead at zero (BAS-79). Hops to MainActor (callback is off-main).
            let onLevel: @Sendable (Double) -> Void = { [weak self] level in
                Task { @MainActor in
                    self?.notchHUD?.updateLevel(level)
                }
            }
            let runtime = try await LiveDictationRuntime(
                database: db,
                router: self.router,
                asrEngine: asrEngine,
                cloudProvider: environment.state.dictationCloudProvider,
                localModelID: environment.state.dictationLocalModelID,
                transcriptionLanguage: environment.state.dictationTranscriptionLanguage,
                deterministicCleanup: deterministicCleanup,
                showLivePartials: showLivePartials,
                onPartial: onPartial,
                onLevel: onLevel
            )
            self.dictationRuntime = runtime
            Loggers.bootstrap.info(
                "LiveDictationRuntime constructed (asr=\(asrEngine.rawValue, privacy: .public), cleanup=\(self.environment.state.dictationCleanupProvider.rawValue, privacy: .public))"
            )
            return runtime
        } catch {
            Loggers.dictation.error(
                "LiveDictationRuntime construction failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    private func ensureFileBatchController() async -> FileBatchController? {
        if let controller = fileBatchController { return controller }
        await bootstrapTask?.value
        guard let db = database else {
            Loggers.files.error("File batch unavailable: database not bootstrapped")
            return nil
        }
        let resolver: RuntimeASRBackendResolver
        if let existing = asrBackendResolver {
            resolver = existing
        } else {
            let router = asrRouter ?? ASRRouter()
            self.asrRouter = router
            resolver = RuntimeASRBackendResolver(router: router)
            self.asrBackendResolver = resolver
        }

        let markdownRoot =
            BootContext.current
            .map { AppLaunch.expandTildePath($0.config.storage.markdownRoot).path }
            ?? MarkdownFolderConfig.makeDefault().displayPath
        // Reuse the ProcessingState the UI already subscribed to (created in
        // wireFileBatch) so live queue progress shows even on the first ingest.
        let processingState = fileProcessingState ?? ProcessingState()
        let controller = FileBatchController(
            queue: FileBatchQueue(capacity: 64),
            repository: FileRepository(database: db),
            transcriber: FileTranscriber { task, projectID in
                await resolver.resolve(task: task, projectID: projectID)
            },
            markdown: MarkdownStore(folderConfig: MarkdownFolderConfig(displayPath: markdownRoot)),
            processingState: processingState,
            folderResolver: FileBatchController.defaultFolderResolver()
        )
        self.fileProcessingState = processingState
        self.fileBatchController = controller
        Loggers.files.info("FileBatchController constructed lazily on first file ingest")
        return controller
    }

    // MARK: Files & Voice Memos (BAS-22)

    /// Wire the Files/Voice-Memo model's closures and create the shared
    /// `ProcessingState` up front, forwarding its broadcasts to the model so the
    /// lists show live queue progress even before the (lazy) controller exists.
    private func wireFileBatch() {
        let model = environment.state.fileBatch
        let processing = ProcessingState()
        self.fileProcessingState = processing
        fileBatchLiveTask = Task { [weak self] in
            for await snapshots in await processing.subscribe() {
                await self?.environment.state.fileBatch.applyLive(snapshots)
            }
        }

        model.loadRecords = { [weak self] origins, projectID in
            guard let self else { return [] }
            await self.bootstrapTask?.value
            guard let db = self.database else { return [] }
            let repo = FileRepository(database: db)
            return (try? await repo.list(origins: origins, projectID: projectID)) ?? []
        }
        model.enqueueURLs = { [weak self] urls, projectID in
            await self?.enqueueFiles(urls: urls, origin: .dragDrop, projectID: projectID)
        }
        model.cancelJob = { [weak self] id in
            guard let self, let controller = await self.ensureFileBatchController() else { return }
            try? await controller.cancel(id: id)
        }
        model.deleteRecord = { [weak self] record in
            guard let self, let id = UUID(uuidString: record.id) else { return }
            await self.bootstrapTask?.value
            guard let db = self.database else { return }
            try? await FileRepository(database: db).delete(id: id)
            // Clean up the captured audio we own. ONLY for mic-recorded memos —
            // a drag-dropped file's source is the user's own original elsewhere,
            // which we must never delete. Synced iPhone memos live in a watched
            // folder the user controls, so leave those too.
            if record.origin == .voiceMemoCapture {
                try? FileManager.default.removeItem(atPath: record.sourcePath)
            }
            // Remove the generated transcript note so a delete leaves nothing behind.
            if let transcriptPath = record.transcriptPath {
                try? FileManager.default.removeItem(atPath: transcriptPath)
            }
        }
        model.retryRecord = { [weak self] record in
            await self?.enqueueFiles(
                urls: [URL(fileURLWithPath: record.sourcePath)],
                origin: record.origin,
                projectID: record.projectID
            )
        }
        model.revealInFinder = { path in
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        model.openTranscript = { record in
            guard let path = record.transcriptPath else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Build supported jobs from URLs and feed them to the batch controller,
    /// carrying the project scope so a file picked/dropped while viewing a
    /// project files into it.
    private func enqueueFiles(urls: [URL], origin: FileBatchJob.Origin, projectID: String?) async {
        let jobs = urls.compactMap {
            FileBatchJob.makeIfSupported(url: $0, origin: origin, projectID: projectID)
        }
        guard !jobs.isEmpty, let controller = await ensureFileBatchController() else {
            if urls.isEmpty == false {
                Loggers.files.warning("enqueueFiles: \(urls.count, privacy: .public) url(s) produced no supported jobs")
            }
            return
        }
        for job in jobs {
            do {
                try await controller.enqueue(job, engine: await engineLabel(for: job))
            } catch {
                Loggers.files.error("enqueue file job failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await controller.startRunLoop()
    }

    /// Enqueue jobs surfaced by a `WatchedFolderSession` (already hopped to
    /// MainActor by the caller).
    ///
    /// De-dupes against the `files` table by source
    /// path so a rescan on relaunch never re-imports a recording already
    /// ingested (the in-memory snapshot only de-dupes within a session).
    private func enqueueWatchedJobs(_ jobs: [FileBatchJob]) async {
        guard !jobs.isEmpty, let controller = await ensureFileBatchController(), let db = database else { return }
        let repo = FileRepository(database: db)
        let present = (try? await repo.sourcePathsPresent(jobs.map { $0.sourceURL.path })) ?? []
        let fresh = jobs.filter { !present.contains($0.sourceURL.path) }
        guard !fresh.isEmpty else { return }
        for job in fresh {
            do {
                try await controller.enqueue(job, engine: await engineLabel(for: job))
            } catch {
                Loggers.files.error("watched-folder enqueue failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await controller.startRunLoop()
    }

    /// (Re)build the set of live folder watchers from the user's settings: each
    /// general watched folder (origin `.watchedFolder`) plus — when iPhone
    /// Voice-Memo sync is enabled — the iCloud Voice Memos folder (origin
    /// `.voiceMemosSync`).
    ///
    /// Idempotent: stops the old set first.
    private func restartWatchedFolders() {
        let state = environment.state
        // The watchers we WANT, as (config, origin) pairs.
        var desired: [(config: WatchedFolderConfig, origin: FileBatchJob.Origin)] =
            state.watchedFolders.map { ($0, .watchedFolder) }
        if state.voiceMemoSyncEnabled {
            let folder = FileInbox.defaultVoiceMemosFolder()
            desired.append(
                (
                    WatchedFolderConfig(
                        displayPath: folder.path,
                        importExistingOnFirstScan: state.voiceMemoImportExisting,
                        projectID: nil,
                        templateID: nil
                    ),
                    .voiceMemosSync
                ))
        }
        // Reconcile against the running set: keep watchers whose (config, origin)
        // is unchanged, stop the removed ones, start only the added/changed ones.
        // This avoids tearing down + re-scanning every folder when only one
        // changed (e.g. a single folder's project re-assignment).
        var remaining = desired
        var kept: [WatchedFolderSession] = []
        for session in watchedFolderSessions {
            if let idx = remaining.firstIndex(where: { $0.config == session.config && $0.origin == session.origin }) {
                kept.append(session)
                remaining.remove(at: idx)
            } else {
                session.stop()
            }
        }
        for entry in remaining {
            let session = makeWatcher(config: entry.config, origin: entry.origin)
            session.start()
            kept.append(session)
        }
        watchedFolderSessions = kept
        Loggers.files.info("Watched folders reconciled: \(kept.count, privacy: .public) watcher(s) active")
    }

    private func makeWatcher(config: WatchedFolderConfig, origin: FileBatchJob.Origin) -> WatchedFolderSession {
        WatchedFolderSession(config: config, origin: origin) { [weak self] jobs in
            // onJobs fires off the watcher's own dispatch queue → hop to MainActor.
            Task { @MainActor in await self?.enqueueWatchedJobs(jobs) }
        }
    }

    private func ensureMeetingRuntime() async -> MeetingRuntime? {
        if let runtime = meetingRuntime { return runtime }
        await bootstrapTask?.value
        guard let db = database else {
            Loggers.meeting.error("Meeting unavailable: database not bootstrapped")
            return nil
        }
        let markdownRoot =
            BootContext.current
            .map { AppLaunch.expandTildePath($0.config.storage.markdownRoot).path }
            ?? MarkdownFolderConfig.makeDefault().displayPath
        let resolver: RuntimeASRBackendResolver
        if let existing = asrBackendResolver {
            resolver = existing
        } else {
            let router = asrRouter ?? ASRRouter()
            self.asrRouter = router
            resolver = RuntimeASRBackendResolver(router: router)
            self.asrBackendResolver = resolver
        }
        let merger = self.router.map { MeetingNotesMerger(router: $0) }
        let liveModel = environment.state.meetingLive
        // Live meeting transcription uses the user's chosen engine (Settings →
        // Audio Devices → Meeting models), not the fixed `.meetingCaptureLive`
        // router default. Captured here so the rebuild on the next meeting picks
        // up a changed selection.
        let meetingEngine = environment.state.meetingASREngine
        let meetingCloudProvider = environment.state.meetingCloudProvider
        let meetingLocale = environment.state.meetingTranscriptionLanguage.locale
        // Rolling in-meeting summary is user-configurable (Settings → Audio
        // Devices → Meeting capture). When disabled, pass nil so the runtime
        // never wires the engine; cadence is read fresh on each rebuild.
        let liveSummary: LiveSummaryEngine?
        if environment.state.meetingLiveSummaryEnabled {
            let cadence = environment.state.meetingLiveSummaryCadenceSeconds
            liveSummary = LiveSummaryEngine(router: self.router, cadenceSeconds: Double(cadence)) { text, isFinal in
                await MainActor.run { liveModel.setSummary(text, isFinal: isFinal) }
            }
        } else {
            liveSummary = nil
        }
        // Calendar context for the augmented note: resolve the event around now
        // and format it as untrusted text. Degrades to "" if calendar access
        // isn't granted, so notes still generate without it.
        let calendarResolver = MeetingCalendarResolver(reader: CalendarReader())
        // Per-speaker diarization (BAS-10) — beta, gated on the master toggle AND
        // on-device model readiness. Off / not-ready → the meeting runs the
        // standard You / Others (no labeler, no recording). If the feature is on
        // but models aren't ready yet, kick a background prepare for next time.
        let appState = environment.state
        if appState.meetingDiarizationEnabled, !appState.diarizationReadiness.isReady {
            prepareDiarizationModelsIfNeeded()
        }
        let diarization = DiarizationActivation.resolve(
            featureEnabled: appState.meetingDiarizationEnabled,
            modelsReady: appState.diarizationReadiness.isReady,
            liveEnabled: appState.meetingLiveDiarizationEnabled,
            offlineEnabled: appState.meetingOfflineDiarizationRefinementEnabled
        )
        let liveSpeakerLabeler: LiveSpeakerLabeler? =
            diarization.useLive ? LiveSpeakerLabeler(embedder: FluidAudioSpeechEmbedder()) : nil
        let diarizeSystemAudio: (@Sendable (URL) async throws -> [DiarizedSegment])?
        if diarization.useOffline {
            let diarizationManager = DiarizationManager()
            diarizeSystemAudio = { url in try await diarizationManager.diarize(contentsOf: url) }
        } else {
            diarizeSystemAudio = nil
        }
        // Meeting-title generation (BAS-29): route via the user's configured title
        // model. nil when the router isn't up yet → the date fallback is kept.
        let titleGenerator: (@Sendable (String) async -> String?)? = self.router.map { router in
            { @Sendable transcript in await MeetingTitleGenerator(router: router).generate(transcript: transcript) }
        }
        // Final conversation-state digest (BAS-33): a one-shot extraction over the
        // finalized transcript, fed into the augmented-notes merge. Routed via the
        // configurable conversation-state model; "" on failure.
        let conversationStateDigest: (@Sendable (String) async -> String)? = self.router.map { router in
            { @Sendable transcript in
                let extractor = ConversationStateExtractor(model: RoutedConversationStateModel(router: router))
                let state = try? await extractor.update(withRecentTranscript: String(transcript.prefix(16000)))
                return state?.digest ?? ""
            }
        }
        // Calendar context (BAS-24): gate on the pref + use the configured ± window.
        // Captured as Sendable locals (the calendarText closure is @Sendable); a
        // pref change rebuilds the runtime via traceMeetingConfigChanged.
        let calendarEnabled = environment.state.meetingCalendarEnabled
        let calendarWindow = environment.state.meetingCalendarWindowMinutes
        let runtime = MeetingRuntime(
            database: db,
            markdownRoot: markdownRoot,
            liveModel: liveModel,
            activeCapture: environment.state.activeCapture,
            asrResolver: { _ in await resolver.resolve(engine: meetingEngine, cloudProvider: meetingCloudProvider) },
            transcriptionLocale: meetingLocale,
            merger: merger,
            resolveTemplate: { [weak self] in
                await self?.meetingTemplate()
            },
            calendarText: {
                guard calendarEnabled,
                    let event = await calendarResolver.resolveCurrentEvent(now: Date(), windowMinutes: calendarWindow)
                else { return "" }
                return MeetingCalendarResolver.calendarText(for: event)
            },
            liveSummary: liveSummary,
            silenceThreshold: TimeInterval(environment.state.meetingSilenceThresholdSeconds),
            onSilenceTimeout: { [weak self] in await self?.handleMeetingSilence() },
            // Hard auto-stop (BAS-13) only while auto-detect is on — manual meetings
            // stay manual. nil threshold disables it in the runtime.
            autoStopThreshold: appState.meetingAutoDetectEnabled
                ? TimeInterval(appState.meetingAutoStopSilenceSeconds) : nil,
            onAutoStop: { [weak self] in await self?.handleMeetingAutoStop() },
            liveSpeakerLabeler: liveSpeakerLabeler,
            diarizeSystemAudio: diarizeSystemAudio,
            speakerMemory: speakerMemoryStore,
            speakerMemoryEnabled: appState.meetingSpeakerMemoryEnabled,
            speakerEmbeddingModel: DiarizationManager.embeddingModel,
            keepCallRecording: appState.meetingKeepCallRecordingEnabled,
            generateTitle: titleGenerator,
            finalConversationState: conversationStateDigest
        )
        // Persist the My-Notes scratchpad to notes.md via the runtime (weak to
        // avoid a runtime ⇄ liveModel retain cycle).
        environment.state.meetingLive.notesSink = { [weak runtime] text in
            await runtime?.saveNotes(text)
        }
        // Click-to-edit title (BAS-29): persist the live meeting's renamed title to
        // meetings.title; resolves the session id at call time on the main actor.
        environment.state.meetingLive.titleSink = { [weak self] text in
            await self?.persistLiveMeetingTitle(text)
        }
        meetingRuntime = runtime
        Loggers.meeting.info("MeetingRuntime constructed lazily on first meeting capture")
        return runtime
    }

    /// Persist a rename of the in-progress meeting's title to `meetings.title`
    /// (BAS-29 click-to-edit).
    ///
    /// Main-actor isolated so it can read the live session.
    private func persistLiveMeetingTitle(_ text: String) async {
        guard let sid = environment.state.meetingLive.sessionId,
            let repo = ensureLibraryRepository()
        else { return }
        try? await repo.updateMeetingTitle(text, sessionId: sid)
    }

    /// Wipe every on-device speaker voiceprint (all projects) — the user-facing
    /// "Forget remembered speakers" action.
    ///
    /// Refreshes the count to 0 on success.
    private func clearSpeakerMemory() async {
        guard let store = speakerMemoryStore else { return }
        do {
            try await store.clearAll()
            Loggers.meeting.info("Cleared all remembered speaker voiceprints")
        } catch {
            Loggers.meeting.error(
                "Clear speaker memory failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        await refreshRememberedSpeakerCount()
    }

    /// Refresh the remembered-speaker count shown in Settings from the store.
    private func refreshRememberedSpeakerCount() async {
        guard let store = speakerMemoryStore else { return }
        let count = (try? await store.totalCount()) ?? 0
        environment.state.meetingRememberedSpeakerCount = count
    }

    /// Drops the cached meeting runtime so the NEXT meeting rebuilds with the
    /// current live-summary configuration.
    ///
    /// A meeting in progress keeps its
    /// existing runtime untouched — the rebuild only takes effect once that
    /// meeting stops and a new one begins.
    private func invalidateMeetingRuntime() {
        guard meetingRuntime?.isCapturing != true else {
            Loggers.meeting.info("Meeting config changed during capture; deferring rebuild until next meeting")
            return
        }
        meetingRuntime = nil
        Loggers.meeting.info("Meeting runtime invalidated; will rebuild on next meeting capture")
    }

    /// Kick a background download/compile of the diarization models when the
    /// (beta) feature is enabled but not yet prepared.
    ///
    /// Idempotent; flips
    /// `diarizationReadiness` to `.ready` and persists a prepared-once flag on
    /// success (so later launches start ready), or `.failed` on error. Until
    /// ready, meetings stay in You / Others — this never blocks capture.
    private func prepareDiarizationModelsIfNeeded() {
        let state = environment.state
        guard
            DiarizationActivation.needsModels(
                featureEnabled: state.meetingDiarizationEnabled,
                liveEnabled: state.meetingLiveDiarizationEnabled,
                offlineEnabled: state.meetingOfflineDiarizationRefinementEnabled
            )
        else { return }
        let readiness = state.diarizationReadiness
        guard readiness.status == .unprepared || readiness.status == .failed else { return }
        let wantLive = state.meetingLiveDiarizationEnabled
        let wantOffline = state.meetingOfflineDiarizationRefinementEnabled
        readiness.markPreparing()
        Task { @MainActor in
            var ok = true
            if wantLive {
                ok =
                    await Self.prepareModels("Live diarization") { try await FluidAudioSpeechEmbedder().prepare() }
                    && ok
            }
            if wantOffline {
                ok = await Self.prepareModels("Offline diarization") { try await DiarizationManager().prepare() } && ok
            }
            if ok {
                readiness.markReady()
                UserDefaults.standard.set(true, forKey: AppStateModel.diarizationModelsPreparedOnceKey)
                Loggers.meeting.info("Diarization models prepared")
            } else {
                readiness.markFailed()
            }
        }
    }

    /// Run one model-prepare step, logging + swallowing failure into `false` so a
    /// missing/undownloadable model never throws into the meeting path.
    private static func prepareModels(_ label: String, _ op: @Sendable () async throws -> Void) async -> Bool {
        do {
            try await op()
            return true
        } catch {
            Loggers.meeting.error(
                "\(label, privacy: .public) model prepare failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: Meeting library ("All meetings")

    /// Read-only session repository for listing/loading past meetings.
    ///
    /// Reuses the
    /// bootstrapped database + markdown root; built lazily once both are ready.
    private func ensureLibraryRepository() -> SessionRepository? {
        if let libraryRepository { return libraryRepository }
        guard let db = database else { return nil }
        let markdownRoot =
            BootContext.current
            .map { AppLaunch.expandTildePath($0.config.storage.markdownRoot).path }
            ?? MarkdownFolderConfig.makeDefault().displayPath
        let repo = SessionRepository(
            database: db,
            markdown: MarkdownStore(folderConfig: MarkdownFolderConfig(displayPath: markdownRoot))
        )
        self.libraryRepository = repo
        return repo
    }

    /// Lazily build the per-project playbook store (folder bookmarks + indexing
    /// state) over the app database.
    private func ensurePlaybookStore() -> PlaybookStore? {
        if let playbookStore { return playbookStore }
        guard let db = database else { return nil }
        let store = PlaybookStore(database: db)
        self.playbookStore = store
        return store
    }

    /// Build a knowledge-base indexer that chunks + embeds playbook docs into the
    /// RAG store (embeddings route to the configured provider — Ollama by default).
    private func makeKnowledgeBaseIndexer() -> KnowledgeBaseIndexer? {
        guard let db = database, let router = self.router else { return nil }
        let config = ragEmbedConfig()
        return KnowledgeBaseIndexer(
            cache: KbCache(db: db),
            embedder: EmbeddingClient(router: router, config: config, task: .embeddingsIndex),
            config: config
        )
    }

    /// Index every playbook folder into the shared RAG corpus and refresh the live
    /// vector indices so library Q&A + the next coach lookup see the new chunks
    /// (the coach also refreshes at meeting start).
    ///
    /// Returns the number of chunks
    /// indexed (0 on failure / no reachable embedding model).
    @discardableResult
    private func indexPlaybookCorpus() async -> Int {
        guard let store = ensurePlaybookStore(), let indexer = makeKnowledgeBaseIndexer() else { return 0 }
        do {
            try await store.ensureSchema()
            let report = try await store.index(projectId: nil, into: indexer)
            // Only reload the live vector indices when something was actually
            // (re)embedded — an all-cached steady-state pass leaves them valid, so
            // skip the full kb_chunks rescan.
            if report.embedded > 0 {
                try? await ensureLibraryVectorSearch()?.refresh()
                try? await coachVectorSearch?.refresh()
            }
            return report.indexed
        } catch {
            Loggers.library.warning("Playbook indexing failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Launch-time playbook reconcile (BAS-18): bring the RAG corpus up to date with
    /// the user's playbook folders so grounded coach cards + the sources line fire.
    private func reconcilePlaybookIndex() async {
        let count = await indexPlaybookCorpus()
        if count > 0 {
            Loggers.library.info("Playbook index reconcile embedded \(count, privacy: .public) chunk(s)")
        }
    }

    /// Wire the Playbooks model's read/write closures (lazy — they resolve the
    /// store + indexer at call time, mirroring the meeting-library wiring).
    private func wirePlaybooks() {
        environment.state.playbooks.loadProjects = { [weak self] in
            guard let self, let store = self.environment.projectStore else { return [] }
            let records = (try? await store.list()) ?? []
            return records.map { ProjectInfo(id: $0.id.uuidString, name: $0.name) }
        }
        environment.state.playbooks.loadFolders = { [weak self] projectId in
            guard let self, let store = self.ensurePlaybookStore(),
                let pid = UUID(uuidString: projectId)
            else { return [] }
            try? await store.ensureSchema()
            return (try? await store.folders(projectId: pid)) ?? []
        }
        environment.state.playbooks.addFolder = { [weak self] projectId, url in
            guard let self, let store = self.ensurePlaybookStore(),
                let pid = UUID(uuidString: projectId)
            else { return }
            try? await store.ensureSchema()
            _ = try? await store.addFolder(projectId: pid, url: url)
        }
        environment.state.playbooks.removeFolder = { [weak self] folderId in
            guard let self, let store = self.ensurePlaybookStore() else { return }
            try? await store.removeFolder(id: folderId)
        }
        environment.state.playbooks.indexCorpus = { [weak self] in
            // Indexes the WHOLE playbook corpus: the prune is global to playbook
            // rows, so a per-project pass would drop other projects' chunks.
            await self?.indexPlaybookCorpus() ?? 0
        }
    }

    /// Wire the library model's read closures (lazy — they resolve the repository
    /// at call time, so this is safe to call before bootstrap finishes).
    private func wireMeetingLibrary() {
        environment.state.meetingLibrary.loadList = { [weak self] projectId in
            guard let self, let repo = self.ensureLibraryRepository() else { return [] }
            return (try? await repo.listMeetings(projectId: projectId)) ?? []
        }
        environment.state.meetingLibrary.loadInbox = { [weak self] in
            guard let self, let repo = self.ensureLibraryRepository() else { return [] }
            return (try? await repo.listInboxMeetings()) ?? []
        }
        environment.state.meetingLibrary.loadProjects = { [weak self] in
            guard let self, let store = self.environment.projectStore else { return [] }
            let records = (try? await store.list()) ?? []
            return records.map { ProjectInfo(id: $0.id.uuidString, name: $0.name) }
        }
        environment.state.meetingLibrary.assignProjectAction = { [weak self] sessionId, projectId in
            guard let self, let repo = self.ensureLibraryRepository() else { return }
            try? await repo.assignProject(
                sessionId: sessionId, projectId: projectId, manualOverride: true
            )
        }
        environment.state.meetingLibrary.deleteAction = { [weak self] sessionId in
            guard let self, let repo = self.ensureLibraryRepository() else { return }
            try? await repo.deleteMeeting(sessionId: sessionId)
        }
        environment.state.meetingLibrary.loadMeeting = { [weak self] meta in
            guard let self, let repo = self.ensureLibraryRepository() else { return nil }
            let saved = await repo.loadSavedMeeting(meta)
            // Hydrate a MeetingLiveModel so a saved meeting renders in the EXACT
            // same tri-column view (Transcript / Notes / AI Summary) as a live one.
            let model = MeetingLiveModel()
            model.begin(sessionId: meta.sessionId, title: meta.title ?? "Meeting", startedAt: meta.startedAt)
            for utterance in saved.utterances { model.appendCommitted(utterance) }
            model.notes = saved.notes
            if let summary = saved.summary,
                !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                model.setSummary(summary, isFinal: true)
            }
            model.end()
            // Editing a past meeting's notes persists back to its own notes.md.
            model.notesSink = { [weak repo] text in try? await repo?.writeNotes(text, sessionId: meta.sessionId) }
            // Click-to-edit title (BAS-29): renaming a saved meeting persists to meetings.title.
            model.titleSink = { [weak repo] text in try? await repo?.updateMeetingTitle(text, sessionId: meta.sessionId)
            }
            // Post-finalize speaker rename (BAS-43 / BAS-46): persist speakers.json,
            // re-index this meeting's citations with the real name, and re-enroll the
            // corrected voiceprint so the mis-match doesn't recur next meeting.
            model.speakerRenameSink = { [weak self] names in
                await self?.handleSavedMeetingSpeakerRename(meta: meta, names: names)
            }
            // Regenerate the AI summary from the saved transcript + notes on demand.
            model.regenerateSummary = { [weak self, weak model] steer in
                guard let self, let model else { return }
                await self.regenerateSavedSummary(meta: meta, model: model, steer: steer)
            }
            return model
        }
    }

    // MARK: Library search / cross-meeting Q&A (BAS-19)

    /// The single embedding config for every RAG feature (library search, the
    /// playbook indexer, and Coach).
    ///
    /// One source ⇒ one fingerprint space ⇒ one
    /// shared vector index; never construct this literal anywhere else.
    private func ragEmbedConfig() -> EmbeddingConfig {
        environment.state.embeddingConfig()
    }

    /// Applies the user's embedding provider/model (BAS-17) to the shared router's
    /// `.embeddingsIndex` + `.embeddingsLive` routes.
    ///
    /// Cloud providers throw without
    /// a key, so RAG degrades rather than crashes; the default is local Ollama.
    private func applyEmbeddingRoute() async {
        guard let router else { return }
        let route = environment.state.embeddingRoute()
        await router.setRoute(route, for: .embeddingsIndex)
        await router.setRoute(route, for: .embeddingsLive)
        Loggers.bootstrap.info(
            "Embedding route → \(route.provider.rawValue, privacy: .public) model=\(route.model, privacy: .public)"
        )
    }

    /// Drop the cached RAG components so they rebuild against the new embedding
    /// fingerprint when the user changes the embedding provider/model (BAS-17) —
    /// otherwise a stale `EmbeddingConfig` would namespace new vectors wrongly.
    private func invalidateEmbeddingConsumers() {
        libraryVectorSearch = nil
        libraryStore = nil
        qaPipeline = nil
        meetingChunkIndexer = nil
    }

    /// Prunes retained audio recordings to the cache budget (BAS-44), oldest-first,
    /// across the markdown root + the audio archive.
    ///
    /// Runs off-main; the summary is
    /// surfaced in Settings → Library & Storage so pruning is never silent.
    private func pruneAudioArchiveToBudget() {
        // Clamp before the Double→Int64 conversion: a corrupt/huge UserDefaults
        // value (or infinity) would otherwise trap in `Int64(_:)`.
        let budgetGb = environment.state.cacheBudgetGb
        guard budgetGb.isFinite, budgetGb > 0 else { return }
        let budgetBytes = Int64(min(budgetGb, 1_000_000) * 1_073_741_824)
        var roots: [URL] = []
        if let root = BootContext.current.map({ AppLaunch.expandTildePath($0.config.storage.markdownRoot) }) {
            roots.append(root)
        }
        if let archive = try? DatabasePaths().audioArchiveDirectory() { roots.append(archive) }
        guard !roots.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let result = AudioArchivePruner().prune(roots: roots, budgetBytes: budgetBytes)
            guard !result.deleted.isEmpty else { return }
            let freedMB = Double(result.freedBytes) / 1_048_576
            Loggers.storage.info(
                "Cache prune: removed \(result.deleted.count, privacy: .public) recording(s), freed \(String(format: "%.0f", freedMB), privacy: .public) MB to fit the \(String(format: "%.0f", budgetGb), privacy: .public) GB budget"
            )
            await MainActor.run { [weak self] in
                self?.environment.state.lastCachePruneSummary =
                    "Pruned \(result.deleted.count) recording(s) · freed \(String(format: "%.1f", freedMB)) MB"
            }
        }
    }

    /// The library's vector index over the unified `kb_chunks` store (transcripts
    /// + notes + playbooks). Built lazily; refreshed after new meetings index.
    private func ensureLibraryVectorSearch() -> VectorSearch? {
        if let libraryVectorSearch { return libraryVectorSearch }
        guard let db = database else { return nil }
        let search = VectorSearch(cache: KbCache(db: db), config: ragEmbedConfig())
        self.libraryVectorSearch = search
        return search
    }

    private func ensureLibraryStore() -> LibraryStore? {
        if let libraryStore { return libraryStore }
        guard let db = database, let search = ensureLibraryVectorSearch() else { return nil }
        let store = LibraryStore(db: db, vectorSearch: search)
        self.libraryStore = store
        return store
    }

    /// Build the cross-meeting Q&A pipeline: dense (vector) + lexical (FTS via the
    /// store) hybrid retrieval, with an optional Voyage reranker when a key is set.
    private func ensureQAPipeline() -> QASearchPipeline? {
        if let qaPipeline { return qaPipeline }
        guard let router = self.router,
            let search = ensureLibraryVectorSearch(),
            let store = ensureLibraryStore()
        else { return nil }
        let config = ragEmbedConfig()
        let voyageKey = (try? KeychainSecrets().load(account: "voyage")) ?? nil
        let reranker: Reranker? =
            (voyageKey?.isEmpty == false)
            ? Reranker(backend: VoyageRerankerBackend(), topK: 8)
            : nil
        let pipeline = QASearchPipeline(
            embedder: EmbeddingClient(router: router, config: config, task: .embeddingsLive),
            vectorSearch: search,
            reranker: reranker,
            router: router,
            lexical: store,
            // Clamp at the consumer so an out-of-range stored value (corrupt default,
            // future programmatic write) can't silence the dense arm; matches the
            // slider's 0…0.9 bound.
            denseFloor: Float(min(max(environment.state.qaRelevanceFloor, 0), 0.9))
        )
        self.qaPipeline = pipeline
        return pipeline
    }

    /// Indexer that embeds a finalized meeting's transcript + notes + summary into
    /// the shared RAG store (same embedding config as playbooks).
    private func makeMeetingChunkIndexer() -> MeetingChunkIndexer? {
        if let meetingChunkIndexer { return meetingChunkIndexer }
        guard let db = database, let router = self.router else { return nil }
        let config = ragEmbedConfig()
        let indexer = MeetingChunkIndexer(
            cache: KbCache(db: db),
            embedder: EmbeddingClient(router: router, config: config, task: .embeddingsIndex),
            config: config
        )
        self.meetingChunkIndexer = indexer
        return indexer
    }

    /// Wire the library search model's closures (lazy — they resolve the store +
    /// pipeline at call time, so this is safe to call before bootstrap finishes).
    private func wireLibrarySearch() {
        let state = environment.state
        state.librarySearch.searchKeyword = { [weak self] query, scope in
            guard let self, let store = self.ensureLibraryStore() else { return [] }
            return (try? await store.searchKeyword(query: query, scope: scope, limit: 80)) ?? []
        }
        state.librarySearch.ask = { [weak self] question, scope in
            guard let self, let pipeline = self.ensureQAPipeline() else {
                return .failure("Q&A isn't ready yet — the app is still starting up.")
            }
            do {
                return .success(try await pipeline.ask(question: question, scope: scope))
            } catch {
                return .failure(Self.qaErrorMessage(error))
            }
        }
        state.librarySearch.loadProjects = { [weak self] in
            guard let self, let store = self.environment.projectStore else { return [] }
            let records = (try? await store.list()) ?? []
            return records.map { ProjectInfo(id: $0.id.uuidString, name: $0.name) }
        }
        state.librarySearch.openMeeting = { meetingId, timestamp in
            NotificationCenter.default.post(
                name: .traceOpenMeeting,
                object: OpenMeetingRequest(meetingId: meetingId, timestamp: timestamp)
            )
        }
        state.librarySearch.openSourceFile = { [weak self] path, _ in
            guard let self else { return }
            Task { @MainActor in
                guard let store = self.ensurePlaybookStore(),
                    let url = try? await store.locateFile(relativePath: path)
                else { return }
                NSWorkspace.shared.open(url)
            }
        }
        state.librarySearch.openSettings = { [weak self] in self?.runOpenSettings() }
        state.librarySearch.checkEmbeddingAvailability = { [weak self] in
            guard let self else { return .notApplicable }
            return await EmbeddingAvailabilityChecker().check(config: self.ragEmbedConfig())
        }
        state.librarySearch.openItem = { source, itemId, projectId in
            NotificationCenter.default.post(
                name: .traceOpenLibraryItem,
                object: OpenLibraryItemRequest(source: source, itemId: itemId, projectId: projectId)
            )
        }
        state.librarySearch.reconcileEntries = { [weak self] in await self?.reconcileEntryIndex() }
    }

    /// Friendly message for a Q&A failure — the common cause is a missing cloud
    /// key for the default `.libraryQA` route (OpenRouter / Claude Sonnet).
    private static func qaErrorMessage(_ error: Error) -> String {
        guard let trace = error as? TraceError else {
            return "Couldn't answer that just now. Please try again."
        }
        switch trace {
        case .configInvalid, .modelRouteUnresolved:
            return
                "Q&A needs a language model. Choose one — or connect a provider — in Settings → Intelligence → LLM Router."
        case .networkFailed, .modelProviderFailed:
            return
                "Couldn't reach the model for Q&A. If you're using a local model, make sure it's running; otherwise check your connection and provider in Settings → Intelligence → LLM Router."
        default:
            return "Couldn't answer that just now. Please try again."
        }
    }

    /// Embed the just-finalized meeting so it's immediately searchable + citable.
    ///
    /// Runs after auto-categorization so chunk provenance carries the final
    /// project id.
    private func indexFinalizedMeeting() async {
        guard let repo = ensureLibraryRepository(),
            let indexer = makeMeetingChunkIndexer(),
            let latest = environment.state.meetingLibrary.meetings.first
        else { return }
        let saved = await repo.loadSavedMeeting(latest)
        // Capture this session's live speaker renames (in-memory on `meetingLive`,
        // still present here because `MeetingRuntime.stop()` calls `end()`, not
        // `reset()`) so citations show real names instead of "Speaker N". The
        // cross-relaunch / reconcile path can't see these — that needs persisted
        // names (BAS-11).
        let speakerNames = environment.state.meetingLive.speakerNames
        do {
            let report = try await indexer.index(meeting: saved, speakerNames: speakerNames)
            if report.embedded > 0 {
                try? await ensureLibraryVectorSearch()?.refresh()
                Loggers.library.info(
                    "Indexed finalized meeting \(latest.sessionId, privacy: .public): \(report.embedded) chunks"
                )
            }
        } catch {
            Loggers.library.warning(
                "Meeting indexing failed for \(latest.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// A speaker was renamed in a *saved* meeting (post-finalize).
    ///
    /// Persist the
    /// updated rename map to `speakers.json`, re-index the meeting so its Q&A /
    /// keyword citations pick up the real name immediately (BAS-46), then re-enroll
    /// the corrected voiceprint so the same mis-match doesn't recur (BAS-43).
    private func handleSavedMeetingSpeakerRename(meta: SessionMetadata, names: [String: String]) async {
        // speakers.json is the durability anchor the reconcile re-reads, so persist
        // it FIRST and only re-index when it succeeds — stamping last_indexed_at
        // against a stale sidecar would let a later content-edit reconcile silently
        // revert the rename. The voiceprint re-enroll below is independent (DB-backed).
        do {
            try MeetingSpeakerNames.write(names, to: MeetingSpeakerNames.url(sessionDirPath: meta.sessionDirPath))
            if let indexer = makeMeetingChunkIndexer(), let repo = ensureLibraryRepository() {
                let saved = await repo.loadSavedMeeting(meta)
                if let report = try? await indexer.index(meeting: saved, speakerNames: names),
                    report.embedded > 0
                {
                    try? await ensureLibraryVectorSearch()?.refresh()
                }
            }
        } catch {
            Loggers.meeting.error(
                "Persist speakers.json failed on saved rename for \(meta.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        await reenrollVoiceprintsAfterRename(meta: meta, names: names)
    }

    /// Re-run cross-meeting speaker enrollment for a saved meeting using its
    /// persisted per-`remote_N` voiceprints + the corrected names (BAS-43).
    ///
    /// No-op
    /// unless speaker memory is enabled and the finalize pass persisted voiceprints.
    /// Returned auto-assignments are intentionally not re-applied to the saved model
    /// — the user is editing names directly; the goal is only to correct the stored
    /// voiceprint so the mis-match doesn't recur in future meetings.
    private func reenrollVoiceprintsAfterRename(meta: SessionMetadata, names: [String: String]) async {
        guard environment.state.meetingSpeakerMemoryEnabled, let store = speakerMemoryStore else { return }
        let voiceprints = MeetingVoiceprints.load(sessionDirPath: meta.sessionDirPath)
        guard !voiceprints.isEmpty else { return }
        let projectScope = meta.projectId.flatMap(UUID.init(uuidString:))
        do {
            _ = try await store.reconcileAndPersist(
                speakerEmbeddings: voiceprints,
                sessionNames: names,
                projectId: projectScope,
                embeddingModel: DiarizationManager.embeddingModel,
                lastSeen: Date()
            )
            Loggers.meeting.info(
                "Re-enrolled voiceprints after post-finalize rename for \(meta.sessionId, privacy: .public)"
            )
        } catch {
            Loggers.meeting.error(
                "Post-finalize voiceprint re-enroll failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Give every meeting still on the date-based fallback a generated, descriptive
    /// title (BAS-29 backfill). `isPlaceholderTitle` gates it, so once a meeting is
    /// titled it's skipped — a cheap no-op on steady-state launches.
    ///
    /// Runs in the
    /// background after bootstrap; updates `meetings.title` and refreshes the
    /// library list so the new titles surface in All-Meetings / sidebar / search.
    private func backfillMeetingTitles() async {
        guard let router, let repo = ensureLibraryRepository() else { return }
        let metas = (try? await repo.listMeetings(projectId: nil, limit: 5000)) ?? []
        let needing = metas.filter { MeetingTitleGenerator.isPlaceholderTitle($0.title) }
        guard !needing.isEmpty else { return }
        let generator = MeetingTitleGenerator(router: router)
        var updated = 0
        for meta in needing {
            let saved = await repo.loadSavedMeeting(meta)
            let transcript = saved.utterances
                .map { "\(SpeakerLabel.display(forRawSpeaker: $0.speaker.rawValue)): \($0.cleaned ?? $0.text)" }
                .joined(separator: "\n")
            guard let title = await generator.generate(transcript: transcript) else { continue }
            do {
                try await repo.updateMeetingTitle(title, sessionId: meta.sessionId)
                updated += 1
            } catch {
                Loggers.meeting.error(
                    "Backfill title update failed for \(meta.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if updated > 0 {
            await environment.state.meetingLibrary.refresh()
            Loggers.meeting.info("Backfilled \(updated, privacy: .public) meeting title(s)")
        }
    }

    /// Keyword indexer for the whole-item sources (dictations / files / voice
    /// memos) feeding `entry_fts`.
    ///
    /// Reuses the boot database.
    private func ensureLibraryEntryIndexer() -> LibraryEntryIndexer? {
        if let libraryEntryIndexer { return libraryEntryIndexer }
        guard let db = database else { return nil }
        let indexer = LibraryEntryIndexer(db: db)
        self.libraryEntryIndexer = indexer
        return indexer
    }

    /// Reconcile the dictation / file / voice-memo keyword index.
    ///
    /// Signature-gated,
    /// so a steady-state pass is a cheap no-op; runs on launch + whenever the
    /// Library search surface appears, so newly captured items become searchable.
    private func reconcileEntryIndex() async {
        guard let indexer = ensureLibraryEntryIndexer() else { return }
        do {
            _ = try await indexer.reconcile()
        } catch {
            Loggers.library.warning("entry index reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-shot reconcile pass: embed any meeting that lacks current-fingerprint
    /// chunks (backfills history + re-indexes after an embedding-model change).
    ///
    /// Content-hash gated, so after the first run it's a cheap no-op. Runs in the
    /// background after bootstrap; until a meeting is embedded, the FTS lexical arm
    /// still answers keyword + hybrid Q&A for it, so there's no silent gap.
    private func reconcileMeetingIndex() async {
        guard let db = database,
            let repo = ensureLibraryRepository(),
            let indexer = makeMeetingChunkIndexer()
        else { return }
        let metas = (try? await repo.listMeetings(projectId: nil, limit: 5000)) ?? []
        guard !metas.isEmpty else { return }
        // Skip meetings already embedded at the current fingerprint, so steady-state
        // launches don't re-read every meeting from disk. New meetings re-index at
        // finalize; this pass backfills history + re-indexes after an embedding-model
        // change (when the fingerprint set is empty, so everything is reconsidered).
        let cache = KbCache(db: db)
        let alreadyIndexed = (try? await cache.indexedMeetingIds(config: ragEmbedConfig())) ?? []
        // Both gate inputs fetched once up front (one query each), not per meeting.
        let lastIndexedByMeeting = (try? await cache.allLastIndexedAt()) ?? [:]
        var embeddedAny = false
        for meta in metas {
            // mtime gate: only re-read a meeting from disk when it isn't embedded
            // at the current fingerprint, or its content changed since last index.
            let mtime = MeetingIndexGate.contentMtime(sessionDirPath: meta.sessionDirPath)
            guard
                MeetingIndexGate.shouldReindex(
                    indexedAtCurrentFingerprint: alreadyIndexed.contains(meta.sessionId),
                    lastIndexedAt: lastIndexedByMeeting[meta.sessionId],
                    contentMtime: mtime
                )
            else { continue }
            let saved = await repo.loadSavedMeeting(meta)
            // Feed the persisted per-meeting speaker renames so historical citations
            // show real names instead of "Speaker N" (BAS-46). The names are baked
            // into the transcript chunk's content hash, so a rename naturally
            // re-embeds; an unchanged map re-produces the same hash and skips.
            let speakerNames = MeetingSpeakerNames.load(sessionDirPath: meta.sessionDirPath)
            if let report = try? await indexer.index(meeting: saved, speakerNames: speakerNames),
                report.embedded > 0
            {
                embeddedAny = true
            }
        }
        if embeddedAny {
            try? await ensureLibraryVectorSearch()?.refresh()
            Loggers.library.info("Meeting index reconcile complete (\(metas.count, privacy: .public) meetings)")
        }
    }

    /// The single in-code meeting template, built from the user's editable summary
    /// instructions.
    ///
    /// Replaces the bundled per-type template library for meetings.
    private static let meetingTemplateID = UUID(uuidString: "A4E3C2B1-0000-4000-8000-000000000001")!
    private func meetingTemplate() -> Template {
        Template.makeBuiltIn(
            id: Self.meetingTemplateID,
            name: "Meeting",
            description: "",
            systemPrompt: environment.state.meetingSummaryInstructions,
            outputSections: [],
            dynamicSections: true
        )
    }

    /// Re-run the augmented-notes merge for a saved meeting (transcript + notes →
    /// template → summary), streaming it into the model and overwriting summary.md.
    private func regenerateSavedSummary(meta: SessionMetadata, model: MeetingLiveModel, steer: String) async {
        guard let router = self.router else { return }
        let template = meetingTemplate()
        let transcript = model.turns
            .map { "\(model.displayName(for: $0.speakerID)): \($0.text)" }
            .joined(separator: "\n")
        guard !transcript.isEmpty else {
            model.setSummary("No speech was captured in this meeting, so there's nothing to summarize.", isFinal: true)
            return
        }
        // Skip the LLM on a near-empty transcript — avoids hallucinated summaries.
        guard model.turns.map(\.text).joined(separator: " ").split(separator: " ").count >= 6 else {
            model.setSummary("Not enough was said in this meeting to summarize.", isFinal: true)
            return
        }
        // Final conversation-state digest (BAS-33) so a regenerated summary gets the
        // same context as a freshly finalized one; "" on failure.
        let stateExtractor = ConversationStateExtractor(model: RoutedConversationStateModel(router: router))
        let conversationState =
            (try? await stateExtractor.update(
                withRecentTranscript: String(transcript.prefix(16000))
            ))?.digest ?? ""
        model.setSummary("", isFinal: false)
        do {
            let result = try await MeetingNotesMerger(router: router).generate(
                template: template,
                transcript: transcript,
                scratchpad: model.notes,
                calendarText: "",
                priorNotes: "",
                conversationState: conversationState,
                projectID: nil,
                steer: steer,
                onToken: { [weak model] token in await model?.appendSummaryDelta(token) }
            )
            model.setSummary(result.markdown, isFinal: true)
            let url = URL(fileURLWithPath: meta.sessionDirPath).appendingPathComponent("summary.md")
            try? result.markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Loggers.meeting.error("Regenerate summary failed: \(error.localizedDescription, privacy: .public)")
            model.setSummary("Couldn't build the summary.\n\n\(self.summaryFailureHint(error))", isFinal: true)
        }
    }

    /// A human reason for a failed summary merge — surfaces the Apple FM
    /// availability reason when Apple FM is the configured notes provider.
    private func summaryFailureHint(_ error: Error) -> String {
        switch environment.state.meetingNotesProvider {
        case .appleFM, .deterministic:
            let probe = AppleFmProbe.probe()
            if !probe.available {
                return (probe.reason ?? "Apple Intelligence isn't available.")
                    + "\n\nOr pick a different notes model in Settings → Meetings."
            }
        case .ollama:
            return
                "Couldn't reach the Ollama model. Make sure Ollama is running and the chosen model is installed, then try again — or pick a different notes model in Settings → Meetings."
        case .openRouter:
            return
                "The OpenRouter request didn't go through. Check your connection and the chosen model in Settings → Meetings, then try again."
        case .anthropic, .chatgpt, .minimax:
            let name = environment.state.meetingNotesProvider.modelProvider?.displayName ?? "the chosen provider"
            return
                "The \(name) request didn't go through. Confirm it's still connected in Settings → LLM Router → Connect providers, then try again."
        }
        return "Please try again, or pick a different notes model in Settings → Meetings."
    }

    // MARK: Coach (in-meeting assistant overlay)

    /// Lazily build the Coach pipeline, reusing the app's ModelRouter + database.
    ///
    /// RAG embeddings route to Ollama (`nomic-embed-text`); utterance
    /// classification + card content route to Apple FM. Returns nil until
    /// bootstrap has provided the database + router.
    private func ensureCoachOrchestrator() -> CoachOrchestrator? {
        if let coachOrchestrator { return coachOrchestrator }
        guard let db = database, let router = self.router else { return nil }
        let embedConfig = ragEmbedConfig()
        let vectorSearch = VectorSearch(cache: KbCache(db: db), config: embedConfig)
        self.coachVectorSearch = vectorSearch
        let detector = EmbeddingDetector(
            embedder: EmbeddingClient(router: router, config: embedConfig, task: .embeddingsLive),
            vectorSearch: vectorSearch
        )
        let orchestrator = CoachOrchestrator(
            config: effectiveCoachConfig(),
            embeddingDetector: detector,
            classifier: AppleFmUtteranceClassifier(router: router),
            smartRouter: AppleFmSmartRouter(router: router),
            antiFabChecker: AppleFmAntiFabricationChecker(router: router)
        )
        self.coachConversationStateExtractor = ConversationStateExtractor(
            model: RoutedConversationStateModel(router: router)
        )
        self.coachOrchestrator = orchestrator
        return orchestrator
    }

    /// The live Coach config: the user's persisted behavior config with `enabled`
    /// forced to the master `coachEnabled` switch — the single source of truth for
    /// Coach on/off.
    private func effectiveCoachConfig() -> CoachConfig {
        var cfg = environment.state.coachConfig
        cfg.enabled = environment.state.coachEnabled
        return cfg
    }

    /// The Coach config for a meeting in a given project (BAS-23): the project's
    /// per-project coach config when set, else the global one — always gated by
    /// the master `coachEnabled` switch AND the project's own enabled flag (so a
    /// project can turn Coach off even when it's globally on).
    private func effectiveCoachConfig(projectID: String?) async -> CoachConfig {
        guard let projectID, let uuid = UUID(uuidString: projectID),
            let store = environment.projectStore,
            let record = try? await store.fetch(id: uuid),
            let projectCfg = CoachConfig.fromProjectJSON(record.coachConfigJson)
        else { return effectiveCoachConfig() }
        var resolved = projectCfg
        resolved.enabled = environment.state.coachEnabled && projectCfg.enabled
        return resolved
    }

    /// (Re)builds the global triple-tap monitor from the user's Coach manual-
    /// trigger config (key, tap count, window).
    ///
    /// Started only when the manual
    /// trigger is enabled; a disabled config leaves no monitor installed.
    private func rebuildTripleTapMonitor() {
        tripleTapMonitor?.stop()
        let manual = environment.state.coachConfig.manualTrigger
        guard manual.enabled else {
            tripleTapMonitor = nil
            return
        }
        let key: ModifierTapKey
        switch manual.modifierKeyCode {
        case 54: key = .rightCommand
        case 62: key = .rightControl
        default: key = .rightOption
        }
        let detector = TripleTapDetector(
            key: key,
            tapCount: manual.tapCount,
            window: Double(manual.windowMilliseconds) / 1000.0
        )
        let monitor = TripleTapMonitor(detector: detector) {
            NotificationCenter.default.post(name: .traceCoachManualTrigger, object: nil)
        }
        monitor.start()
        tripleTapMonitor = monitor
    }

    /// Coach settings changed: rebuild the triple-tap monitor from the new manual-
    /// trigger config, push the new behavior config into a running orchestrator so
    /// mode / budget / throttle / anti-fabrication edits take effect mid-meeting,
    /// and — if the master switch was turned off — tear down a live overlay.
    ///
    /// (Turning it back on mid-meeting takes effect on the next meeting.)
    private func applyCoachConfigChange() {
        rebuildTripleTapMonitor()
        // Push the config for the ACTIVE meeting's project (if any) so a global
        // Coach-settings edit mid-meeting doesn't overwrite a project's
        // per-project Coach config. effectiveCoachConfig(projectID:) is async, so
        // resolve it inside the Task.
        if coachOrchestrator != nil {
            let projectID = activeMeetingProjectID
            Task { [weak self] in
                guard let self, let orchestrator = self.coachOrchestrator else { return }
                await orchestrator.updateConfig(self.effectiveCoachConfig(projectID: projectID))
            }
        }
        if !environment.state.coachEnabled {
            coachSubscriptionTask?.cancel()
            coachSubscriptionTask = nil
            coachConversationStateTask?.cancel()
            coachConversationStateTask = nil
            coachOverlay?.update(activeCard: nil)
            coachOverlay?.update(conversationState: "")
            coachOverlay?.hide()
        }
    }

    /// Present the coach overlay and subscribe it to the meeting's live utterance
    /// stream.
    ///
    /// Each committed utterance runs the Coach pipeline; surfaced cards
    /// (and suppressed-but-detected moments) update the overlay.
    private func startCoach(runtime: MeetingRuntime, projectName: String, config: CoachConfig) {
        // `config` is the project-aware effective config: a project may turn
        // Coach off (config.enabled false) even when globally on.
        guard config.enabled, let orchestrator = ensureCoachOrchestrator() else { return }
        coachRecentText.removeAll()
        coachOverlay?.applyAppearance(environment.state.appearancePreference)
        // Start in the compact listening pill — don't auto-pop a full card at
        // meeting start. A real card flips it open (CoachOverlayController.update).
        coachOverlay?.minimizeToPill()
        coachOverlay?.present(projectName: projectName)
        coachOverlay?.update(conversationState: "")
        coachSubscriptionTask?.cancel()
        // Capture the active meeting's project so the coach scopes grounded
        // retrieval to it (plus global playbooks) instead of every past meeting.
        let projectID = activeMeetingProjectID
        coachSubscriptionTask = Task { [weak self] in
            // Adopt this project's coach behavior config, then reset per-meeting
            // surface budget + throttle and load any indexed playbook embeddings.
            await orchestrator.updateConfig(config)
            await orchestrator.beginMeeting(projectID: projectID)
            try? await self?.coachVectorSearch?.refresh()
            for await utt in runtime.utteranceStream() {
                guard let self else { break }
                self.appendCoachWindow(utt.text)
                let cu = CoachUtterance(
                    speakerId: utt.speaker.rawValue,
                    text: utt.text,
                    timestamp: Date(),
                    userRequested: false
                )
                do {
                    let result = try await orchestrator.ingest(
                        utterance: cu, windowText: self.coachWindowText()
                    )
                    self.applyCoachResult(result)
                } catch {
                    Loggers.bridges.debug("Coach ingest failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        startCoachConversationState(orchestrator: orchestrator)
    }

    /// Periodically (~30s) roll the conversation-state summary forward via the
    /// routed extractor (prior state + latest transcript window) and feed its
    /// digest to the orchestrator, so the smart router runs with live context
    /// (topic / open questions / tensions / decisions) instead of blind.
    ///
    /// The
    /// extractor accumulates across ticks, so context persists for the whole
    /// meeting without ever sending the full transcript. Reset once per meeting,
    /// then gated per-tick by `conversationStateEnabled` so the stage can be
    /// toggled mid-meeting.
    private func startCoachConversationState(orchestrator: CoachOrchestrator) {
        coachConversationStateTask?.cancel()
        guard let extractor = coachConversationStateExtractor else { return }
        coachConversationStateTask = Task { [weak self] in
            await extractor.reset()
            while !Task.isCancelled {
                // Read the cadence each loop so a mid-meeting change applies to the
                // next tick. Floor at 5s as a safety rail against a bad value.
                guard let intervalSeconds = self?.environment.state.coachConfig.conversationStateIntervalSeconds else {
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(max(5, intervalSeconds)) * 1_000_000_000)
                guard !Task.isCancelled, let self else { break }
                guard self.environment.state.coachConfig.conversationStateEnabled else {
                    // Stage toggled off mid-meeting → clear the overlay's state row.
                    self.coachOverlay?.update(conversationState: "")
                    continue
                }
                let transcript = self.coachRecentText.joined(separator: "\n")
                guard !transcript.isEmpty else { continue }
                do {
                    let state = try await extractor.update(withRecentTranscript: transcript)
                    await orchestrator.updateConversationState(state.digest)
                    // Surface the coach's live read on the overlay (BAS-48).
                    self.coachOverlay?.update(conversationState: state.overlayLine)
                } catch {
                    Loggers.bridges.debug(
                        "Coach conversation-state update failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Tear down the coach subscription and hide the overlay when a meeting ends.
    private func stopCoach() {
        coachSubscriptionTask?.cancel()
        coachSubscriptionTask = nil
        coachConversationStateTask?.cancel()
        coachConversationStateTask = nil
        coachRecentText.removeAll()
        activeMeetingProjectID = nil
        coachOverlay?.update(activeCard: nil)
        coachOverlay?.update(conversationState: "")
        coachOverlay?.hide()
    }

    /// Route a pipeline result to the overlay: surface the card and record the
    /// moment in the recent-trigger history (surfaced, or detected-but-suppressed).
    private func applyCoachResult(_ result: CoachOrchestrator.PipelineResult) {
        guard let overlay = coachOverlay else { return }
        if let card = result.card {
            overlay.update(activeCard: card)
            overlay.appendRecentTrigger(
                RecentTrigger(label: card.title, mode: card.mode, wasSurfaced: true)
            )
        } else if result.classification != .none, let routing = result.routingOutput, routing.mode != .silent {
            overlay.appendRecentTrigger(
                RecentTrigger(label: routing.title, mode: routing.mode, wasSurfaced: false)
            )
        }
    }

    private func appendCoachWindow(_ text: String) {
        coachRecentText.append(text)
        if coachRecentText.count > 12 {
            coachRecentText.removeFirst(coachRecentText.count - 12)
        }
    }

    private func coachWindowText() -> String {
        coachRecentText.suffix(6).joined(separator: " ")
    }

    private func engineLabel(for job: FileBatchJob) async -> String {
        let task = job.resolvedASRTask()
        guard let asrRouter else { return task.rawValue }
        let projectID = job.projectID.flatMap(UUID.init(uuidString:))
        let route = await asrRouter.route(for: task, projectID: projectID)
        return "\(route.engineIdentifier):\(route.modelIdentifier)"
    }

    private func runStartDictation() {
        // Building the runtime the first time loads (and on a fresh install
        // downloads) the speech model — Parakeet's weights are ~700 MB. Show a
        // "Getting ready…" HUD during that first build instead of a recording
        // timer that looks live but isn't, then flip to the real session once
        // the model is ready. Subsequent dictations skip this (runtime cached).
        let firstBuild = (dictationRuntime == nil)
        environment.state.activeCapture.beginDictation(sessionId: "dictation-\(Int(Date().timeIntervalSince1970))")
        installEnterInterceptorIfEnabled()
        notchHUD?.showCompact(timer: "0:00", kind: firstBuild ? .preparing : .listening)
        Loggers.dictation.info("AppCommands.startDictation invoked (firstBuild=\(firstBuild, privacy: .public))")
        Task { [weak self] in
            guard let self else { return }
            // If dictation runs on Parakeet and the weights aren't downloaded
            // yet, wait for the download (showing live progress) instead of
            // dead-ending. Pressing ⌥Space is the approval to fetch it. We never
            // silently fall back to another engine — the user either waits, or
            // switches to Apple Speech in Settings.
            guard await self.awaitDictationModelIfNeeded() else {
                Loggers.dictation.error("startDictation: speech model download failed")
                self.notchHUD?.setKind(.downloadFailed)
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                self.abortDictationStartup()
                return
            }
            guard let runtime = await self.ensureDictationRuntime() else {
                Loggers.dictation.error("startDictation: runtime unavailable")
                self.notchHUD?.setKind(.unavailable)
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                self.abortDictationStartup()
                return
            }
            if firstBuild {
                // Model finished loading/downloading — start the recording clock
                // now and flip the HUD from "Getting ready…" to the live session.
                self.notchHUD?.state.startedAt = Date()
                self.notchHUD?.setKind(.listening)
            }
            do {
                try await runtime.controller.startCapture(mode: .toggle)
            } catch {
                Loggers.dictation.error(
                    "startCapture failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Ensure the on-device dictation model is present before building the
    /// runtime.
    ///
    /// Only Parakeet ships a download we gate on here; every other
    /// engine (Apple Speech, cloud, or WhisperKit/Qwen3 which fetch via their
    /// own `prepare()`) returns `true` immediately. When Parakeet isn't cached
    /// yet, this starts the long-lived install download — owned by
    /// `AppEnvironment`, so it persists even if the user is mid-onboarding — and
    /// drives a live "DOWNLOADING …%" HUD until it's ready. Returns `false` only
    /// if the download finished without producing the model, so the caller can
    /// surface an actionable failure rather than falling back to another engine.
    private func awaitDictationModelIfNeeded() async -> Bool {
        guard environment.state.dictationASREngine == .parakeet else { return true }
        let install = environment.asrInstall
        await install.probeReadiness()
        if install.parakeetReady { return true }
        install.start()
        while !install.parakeetReady && install.isDownloading {
            let pct = Int((install.parakeetFraction * 100).rounded())
            notchHUD?.setKind(.downloading(pct))
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return install.parakeetReady
    }

    private func runStopDictation(submitAfterInsert: Bool = false) {
        // Always retire the Return interceptor first: dictation is ending, and
        // tearing it down before we post any synthetic Return rules out a loop.
        teardownEnterInterceptor()
        environment.state.activeCapture.end()
        // Update just the label — keep the same startedAt so the elapsed
        // timer counts from when the user first hit ⌥Space instead of
        // resetting to 0:00. The label is model-adaptive: a streaming engine
        // already showed the transcript live, so the post-stop work is just
        // cleanup; a batch engine (Parakeet) is genuinely transcribing now.
        let streamedLive =
            environment.state.dictationShowLivePartials
            && environment.state.dictationASREngine.supportsStreaming
        notchHUD?.setKind(streamedLive ? .cleaning : .transcribing)
        Loggers.dictation.info("AppCommands.stopDictation invoked")
        Task { [weak self] in
            guard let self else { return }
            guard let runtime = self.dictationRuntime else {
                self.notchHUD?.hide()
                return
            }
            do {
                let result = try await runtime.controller.stopCapture()
                if let result {
                    Loggers.dictation.info(
                        "stopCapture finalized rawLen=\(result.rawText.count, privacy: .public) cleanedLen=\(result.cleanedText.count, privacy: .public) pasted=\(result.pasted, privacy: .public) strategy=\(String(describing: result.pasteStrategy), privacy: .public)"
                    )
                    if result.cleanedText.isEmpty {
                        self.notchHUD?.setKind(.noAudio)
                    } else if !result.pasted {
                        // Text only made it to the clipboard (no Accessibility /
                        // AX insert) — there's nothing in the field to submit, so
                        // never fire Return here.
                        self.notchHUD?.setKind(.copied)
                    } else {
                        self.notchHUD?.setKind(.inserted)
                        if submitAfterInsert {
                            await self.submitReturnAfterInsert()
                        }
                    }
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                }
            } catch {
                Loggers.dictation.error(
                    "stopCapture failed: \(String(describing: error), privacy: .public)"
                )
                self.notchHUD?.setKind(.failed)
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            }
            self.notchHUD?.hide()
        }
    }

    private func toggleDictation() {
        if environment.state.activeCapture.mode == .dictation {
            runStopDictation()
        } else {
            runStartDictation()
        }
    }

    /// Arm the "press Return to send" interceptor for this dictation, if enabled.
    ///
    /// The pref is read live, so flipping the Settings toggle takes effect on the
    /// very next dictation with no runtime rebuild. When Accessibility isn't
    /// granted the active tap can't be created — we log and leave Return alone
    /// rather than degrading silently (the paste path owns the grant prompt).
    private func installEnterInterceptorIfEnabled() {
        teardownEnterInterceptor()
        guard environment.state.dictationEnterSends else { return }
        let interceptor = EnterKeyInterceptor { [weak self] in
            self?.runStopDictation(submitAfterInsert: true)
        }
        switch interceptor.start() {
        case .started:
            enterKeyInterceptor = interceptor
        case .missingPermission:
            Loggers.dictation.info(
                "Return-to-send: Accessibility not granted; leaving Return alone this session"
            )
        case .failed:
            Loggers.dictation.error("Return-to-send: event tap creation failed")
        }
    }

    private func teardownEnterInterceptor() {
        enterKeyInterceptor?.stop()
        enterKeyInterceptor = nil
    }

    /// Clean up a dictation that never got off the ground (model download failed,
    /// runtime unavailable): retire the Return interceptor and clear the capture
    /// chrome. These early-exit paths don't run through `runStopDictation` (which
    /// would kick off transcription), so they own their own teardown.
    private func abortDictationStartup() {
        teardownEnterInterceptor()
        environment.state.activeCapture.end()
        notchHUD?.hide()
    }

    /// Fire a synthetic Return to submit, a beat after the transcript landed.
    ///
    /// Only reached when the insert genuinely succeeded with non-empty text, so
    /// we never submit an empty or clipboard-only message. The short delay lets
    /// the focused app finish ingesting the inserted text (enable its send
    /// button, update its editor model) before Return arrives.
    private func submitReturnAfterInsert() async {
        try? await Task.sleep(nanoseconds: 70_000_000)
        let sent = await CGEventKeySynthesizer().send(.returnKey)
        Loggers.dictation.info("Return-to-send: submitted=\(sent, privacy: .public)")
    }

    private func runStartVoiceMemo() {
        environment.state.activeCapture.beginVoiceMemo(sessionId: "memo-\(Int(Date().timeIntervalSince1970))")
        notchHUD?.showCompact(timer: "0:00", kind: .voiceMemo)
        Loggers.files.info("AppCommands.startVoiceMemo invoked")
        Task { [weak self] in
            guard let self else { return }
            guard let runtime = await self.ensureDictationRuntime() else {
                self.environment.state.activeCapture.end()
                self.notchHUD?.hide()
                return
            }
            do {
                try await runtime.voiceMemo.start()
                Loggers.files.info("VoiceMemoCapture.start succeeded")
            } catch {
                // Never leave a fake "recording" timer running when the mic never
                // actually started — tear the capture state down and flag it.
                Loggers.files.error("VoiceMemoCapture.start failed: \(error.localizedDescription, privacy: .public)")
                self.environment.state.activeCapture.end()
                self.notchHUD?.setKind(.failed)
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                self.notchHUD?.hide()
            }
        }
    }

    private func runStopVoiceMemo() {
        Loggers.files.info("AppCommands.stopVoiceMemo invoked")
        Task { [weak self] in
            guard let self, let runtime = self.dictationRuntime else {
                self?.environment.state.activeCapture.end()
                return
            }
            do {
                // File the memo into the project the user is currently viewing
                // (mirrors how a meeting started in a project files into it).
                let job = try await runtime.voiceMemo.stop(
                    projectID: self.environment.state.currentProjectContext
                )
                if let controller = await self.ensureFileBatchController() {
                    try await controller.enqueue(job, engine: await self.engineLabel(for: job))
                    await controller.startRunLoop()
                }
                Loggers.files.info("VoiceMemoCapture.stop produced job \(job.id.uuidString, privacy: .public)")
                self.environment.state.activeCapture.end()
                self.notchHUD?.hide()
            } catch {
                // A genuine stop failure (e.g. nothing was captured) must be loud,
                // not a silently-vanishing recording UI.
                Loggers.files.error("VoiceMemoCapture.stop failed: \(error.localizedDescription, privacy: .public)")
                self.environment.state.activeCapture.end()
                self.notchHUD?.setKind(.failed)
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                self.notchHUD?.hide()
            }
        }
    }

    private func toggleVoiceMemo() {
        if environment.state.activeCapture.mode == .voiceMemo {
            runStopVoiceMemo()
        } else {
            runStartVoiceMemo()
        }
    }

    private func runStartMeeting() {
        Loggers.meeting.info("AppCommands.startMeeting invoked")
        // We're capturing now — stop any armed auto-detect poll + dismiss prompt.
        autoDetectTask?.cancel()
        autoDetectTask = nil
        meetingPromptTimeoutTask?.cancel()
        meetingPromptTimeoutTask = nil
        meetingSessionEpoch += 1
        let epoch = meetingSessionEpoch
        Task { [weak self] in
            guard let self, let runtime = await self.ensureMeetingRuntime() else { return }
            do {
                let projectContext = self.environment.state.currentProjectContext
                let sessionID = try await runtime.start(
                    title: "Meeting \(Self.timestampLabel())",
                    projectId: projectContext
                )
                self.notchHUD?.showCompact(timer: "0:00", kind: .meeting)
                self.activeMeetingProjectID = projectContext
                let coachConfig = await self.effectiveCoachConfig(projectID: projectContext)
                // If the meeting was stopped (or another start fired) while this one
                // was still spinning up, don't pop the coach for a meeting that's no
                // longer active — that's the start/stop race that left the pill stuck.
                guard self.meetingSessionEpoch == epoch else {
                    Loggers.meeting.info("Meeting superseded during startup; skipping coach")
                    return
                }
                self.startCoach(runtime: runtime, projectName: "Meeting", config: coachConfig)
                await self.environment.state.meetingLibrary.refresh()
                Loggers.meeting.info(
                    "Meeting capture started: \(sessionID, privacy: .public)"
                )
            } catch {
                self.environment.state.activeCapture.end()
                self.notchHUD?.hide()
                Loggers.meeting.error(
                    "Meeting capture start failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func toggleMeeting() {
        if environment.state.activeCapture.mode == .meeting {
            runStopMeeting()
        } else {
            runStartMeeting()
        }
    }

    private func runStopMeeting() {
        Loggers.meeting.info("AppCommands.stopMeeting invoked")
        // Invalidate any meeting still spinning up, so its async startup won't pop
        // the coach pill after we've stopped (the start/stop race).
        meetingSessionEpoch += 1
        Task { [weak self] in
            guard let self else { return }
            guard let runtime = self.meetingRuntime else {
                self.environment.state.activeCapture.end()
                self.notchHUD?.hide()
                return
            }
            await runtime.stop()
            self.stopCoach()
            self.notchHUD?.hide()
            await self.environment.state.meetingLibrary.refresh()
            await self.runAutoCategorization()
            await self.indexFinalizedMeeting()
            // A finished meeting may have enrolled / refreshed voiceprints.
            await self.refreshRememberedSpeakerCount()
            Loggers.meeting.info("Meeting capture finalized")
            // Keep retained recordings under the cache budget (BAS-44).
            self.pruneAudioArchiveToBudget()
            // Re-arm a fresh detector for the next meeting (no-op when pref OFF).
            self.rearmMeetingAutoDetect()
        }
    }

    /// After a meeting finalizes, score it against the user's projects and
    /// silently file it into the best one when confidence is high (§8.2 bucket
    /// `> 0.75`).
    ///
    /// Lower confidence stays in Inbox — the user files it by hand
    /// from the meetings library, which sets a sticky manual override (§8.3).
    /// Signals today are project-name + attendee overlap; the richer content /
    /// recurring / history signals are tracked in BAS-9.
    private func runAutoCategorization() async {
        guard let repo = ensureLibraryRepository(),
            let projectStore = environment.projectStore,
            let latest = environment.state.meetingLibrary.meetings.first,
            latest.projectId == nil  // never re-file an already-filed meeting
        else { return }
        let projectRecords = (try? await projectStore.list()) ?? []
        guard !projectRecords.isEmpty else { return }
        let candidates = projectRecords.map { ProjectCandidate(id: $0.id, name: $0.name) }
        let saved = await repo.loadSavedMeeting(latest)
        let transcriptPrefix = String(
            saved.utterances.prefix(60).map(\.text).joined(separator: " ").prefix(2000)
        )

        // Best-effort calendar context near the meeting's start: attendees feed the
        // attendee signal, the event title helps the LLM classifier. Degrades to
        // empty when calendar access isn't granted / no event is found.
        var attendeeEmails: [String] = []
        var calendarTitle: String?
        if environment.state.meetingCalendarEnabled,
            let event = await MeetingCalendarResolver(reader: CalendarReader())
                .resolveCurrentEvent(
                    now: latest.startedAt, windowMinutes: environment.state.meetingCalendarWindowMinutes)
        {
            attendeeEmails = event.attendees
            calendarTitle = event.title
        }

        let input = MeetingCategorizationInput(
            manualOverride: false, transcriptPrefix: transcriptPrefix, attendeeEmails: attendeeEmails
        )
        // Deterministic signals + the configurable LLM "final classifier" (§8.2).
        let categorizer = RoutedProjectCategorizer(
            base: ProjectCategorizer(signalProvider: MeetingCategorizationSignalProvider()),
            classifier: self.router.map { MeetingProjectClassifier(router: $0) }
        )
        guard
            let result = try? await categorizer.categorize(
                input, projects: candidates, calendarTitle: calendarTitle
            )
        else { return }

        let liveModel = environment.state.meetingLive
        let sessionId = latest.sessionId
        // The banner's one-tap buttons file the meeting (sticky manual override).
        liveModel.assignProjectFromSuggestion = { [weak self] projectID in
            guard let self, let repo = self.ensureLibraryRepository() else { return }
            try? await repo.assignProject(sessionId: sessionId, projectId: projectID, manualOverride: true)
            await self.environment.state.meetingLibrary.refresh()
        }

        switch result.bucket {
        case .autoAssign:
            guard let top = result.scores.first else { return }
            try? await repo.assignProject(
                sessionId: sessionId, projectId: top.project.id.uuidString,
                manualOverride: false, confidence: top.confidence
            )
            await environment.state.meetingLibrary.refresh()
            liveModel.setCategorization(Self.categorizationSuggestion(from: result, autoFiled: true))
            Loggers.meeting.info(
                "Auto-categorized meeting → \(top.project.name, privacy: .public) @ \(top.confidence, privacy: .public)"
            )
        case .askUser:
            liveModel.setCategorization(Self.categorizationSuggestion(from: result, autoFiled: false))
            try? await CategorizationNotifier().notifyIfNeeded(result: result, meetingTitle: liveModel.title)
            Loggers.meeting.info(
                "Meeting categorization uncertain → surfacing \(result.scores.prefix(3).count, privacy: .public) candidate(s)"
            )
        case .inbox, .manualOverride:
            break  // stays in Inbox; the user files it from the library when ready
        }
    }

    /// Build the meeting-detail banner from a categorization result (BAS-9): the
    /// auto-filed confirmation, or the top candidates to choose from.
    private static func categorizationSuggestion(
        from result: CategorizationResult, autoFiled: Bool
    ) -> MeetingCategorizationSuggestion {
        let candidates = result.scores.prefix(3).map {
            MeetingCategorizationSuggestion.Candidate(
                id: $0.project.id.uuidString, name: $0.project.name, confidence: $0.confidence
            )
        }
        let headline: String
        if autoFiled, let top = candidates.first {
            headline = "Filed in \(top.name) · AI \(Int((top.confidence * 100).rounded()))%"
        } else {
            headline = "Suggested project"
        }
        return MeetingCategorizationSuggestion(
            headline: headline, candidates: Array(candidates), isAutoFiled: autoFiled
        )
    }

    private func runTranscribeFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            runTranscribeFiles(urls: panel.urls)
        }
    }

    private func runTranscribeFiles(urls: [URL]) {
        // Carry the current project context so a file transcribed while viewing a
        // project files into it. enqueueFiles filters unsupported URLs.
        let projectID = environment.state.currentProjectContext
        Task { [weak self] in
            await self?.enqueueFiles(urls: urls, origin: .dragDrop, projectID: projectID)
        }
    }

    private func runOpenLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    private func runOpenSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func runManualCoachTrigger(intent: CoachIntent? = nil) {
        // The coach overlay only belongs on screen during an ACTIVE meeting. A
        // manual trigger fired outside one — a stray Right-⌘ triple-tap while
        // dictating, a hotkey, a leftover Ask — must NOT pop the pill, or it
        // appears when it shouldn't and lingers. Gate on the live capture state
        // BEFORE presenting anything (the old code presented first, then bailed,
        // leaving the pill stuck).
        guard meetingRuntime?.isCapturing == true else {
            Loggers.bridges.info("Manual coach trigger ignored — no active meeting")
            return
        }
        environment.state.coachOverlayVisible = true
        coachOverlay?.applyAppearance(environment.state.appearancePreference)
        coachOverlay?.present()
        Loggers.bridges.info("Manual coach trigger invoked (intent: \(intent?.rawValue ?? "none", privacy: .public))")
        // Force a card from the recent conversation window, bypassing detection
        // gates (userRequested). No-op when nothing's been said yet (window empty).
        guard let orchestrator = ensureCoachOrchestrator() else { return }
        let window = coachWindowText()
        guard !window.isEmpty else { return }
        Task { [weak self] in
            let cu = CoachUtterance(
                speakerId: "you", text: window, timestamp: Date(),
                userRequested: true, intent: intent
            )
            if let result = try? await orchestrator.ingest(utterance: cu, windowText: window) {
                self?.applyCoachResult(result)
            }
        }
    }

    private static func timestampLabel() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

private actor RuntimeASRBackendResolver {
    private let router: ASRRouter
    private var backends: [String: any TranscriptionBackend] = [:]

    init(router: ASRRouter) {
        self.router = router
    }

    func resolve(task: ASRTaskClass, projectID: UUID? = nil) async -> (any SampleTranscribing)? {
        // Honor per-project ASR overrides (BAS-23): a file/voice-memo job filed
        // into a project uses that project's engine for its task class.
        let route = await router.route(for: task, projectID: projectID)
        return await resolve(route: route)
    }

    /// Resolves a prepared transcriber for an explicit dictation engine choice,
    /// bypassing the router's task-class default.
    ///
    /// Used for meeting capture so the
    /// user's `meetingASREngine` selection drives the live transcription instead
    /// of the fixed `.meetingCaptureLive` default. Reuses the same backend
    /// build/prepare path as `resolve(task:)` (no engine fallback — failure is nil).
    /// `cloudProvider` only matters when the engine is `.cloud`.
    func resolve(
        engine: DictationASREngine,
        cloudProvider: CloudASRProvider = .openai
    ) async -> (any SampleTranscribing)? {
        // Engine→route mapping is shared with `ASREngineRegistry` via
        // `DictationASREngine.asrRoute`; construction lives in `ASRBackendFactory`.
        // A FRESH (uncached) backend per call: meeting capture resolves one
        // transcriber per audio stream (mic + system), and each needs its OWN
        // decoder state so the two streams don't bleed into each other's decoding.
        // The heavy model isn't reloaded — engines like Parakeet share one warm
        // model process-wide, so a fresh backend only allocates its own decode state.
        let route = engine.asrRoute(cloudProvider: cloudProvider)
        let label = "\(route.engineIdentifier):\(route.modelIdentifier)"
        guard let backend = ASRBackendFactory.makeBackend(for: route) else {
            Loggers.files.error("No ASR backend registered for route \(label, privacy: .public)")
            return nil
        }
        do {
            try await prepare(backend, label: label, field: route.engineIdentifier)
            return TranscriptionBackendAdapter(backend: backend)
        } catch {
            // No silent Apple Speech fallback (by design) — see `resolve(route:)`.
            Loggers.files.error(
                "ASR backend \(label, privacy: .public) failed to start (no fallback): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func resolve(route: ASRRoute) async -> (any SampleTranscribing)? {
        let label = "\(route.engineIdentifier):\(route.modelIdentifier)"
        guard let backend = backend(for: route) else {
            Loggers.files.error("No ASR backend registered for route \(label, privacy: .public)")
            return nil
        }
        do {
            try await prepare(backend, label: label, field: route.engineIdentifier)
            return TranscriptionBackendAdapter(backend: backend)
        } catch {
            // No silent Apple Speech fallback (by design): a chosen engine that fails
            // to start surfaces as `nil` so the caller fails loudly and the user fixes
            // the engine in Settings — instead of recording a whole meeting on a
            // downgraded engine without knowing.
            Loggers.files.error(
                "ASR backend \(label, privacy: .public) failed to start (no fallback): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func prepare(
        _ backend: any TranscriptionBackend,
        label: String,
        field: String
    ) async throws {
        switch await backend.checkStatus() {
        case .loaded:
            return
        case .unavailable(let reason):
            throw TraceError.configInvalid(field: field, reason: reason)
        default:
            try await backend.prepare(
                onStatus: { status in
                    Loggers.files.info(
                        "ASR backend \(label, privacy: .public) status \(String(describing: status), privacy: .public)"
                    )
                },
                onProgress: { progress in
                    Loggers.files.info(
                        "ASR backend \(label, privacy: .public) prepare \(progress, privacy: .public)"
                    )
                }
            )
        }
    }

    private func backend(for route: ASRRoute) -> (any TranscriptionBackend)? {
        let key = "\(route.engineIdentifier):\(route.modelIdentifier)"
        if let existing = backends[key] { return existing }

        // Construction (incl. the cloud-provider branch) lives in the shared,
        // unit-tested `ASRBackendFactory`; the resolver only adds the instance
        // cache on top (BAS-21). There is no engine fallback — a failed prepare
        // surfaces as nil in `resolve(route:)`.
        guard let backend = ASRBackendFactory.makeBackend(for: route) else { return nil }
        backends[key] = backend
        return backend
    }
}
