import CoachModule
import Foundation
import Observation
import SharedCore
import SwiftUI

/// Cleanup model surfaced in Settings → LLM Router.
///
/// Drives which provider
/// `ModelRouter` routes `.dictationCleanup` to, plus a `.deterministic`
/// option that skips the LLM entirely and uses our local fixer.
public enum DictationCleanupProvider: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case deterministic
    case appleFM
    case ollama
    case openRouter
    // BAS-60: the connected cloud providers (`ModelProvider` in SharedCore),
    // routable per stage once signed in. Raw values match `ModelProvider`
    // exactly so the two bridge 1:1 via `modelProvider`.
    case anthropic
    case chatgpt
    case minimax

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deterministic: return "Deterministic (no LLM)"
        case .appleFM, .ollama, .openRouter, .anthropic, .chatgpt, .minimax:
            return modelProvider?.displayName ?? rawValue
        }
    }

    /// The catalog entry (`ModelProvider`) this case bridges to — every case
    /// except `.deterministic` (the no-LLM fixer, which has no provider).
    ///
    /// The
    /// single seam that lets a per-stage choice reuse the catalog's wire kind,
    /// base URL, Keychain account, and suggested models (BAS-36 / BAS-60).
    public var modelProvider: ModelProvider? { ModelProvider(rawValue: rawValue) }
}

/// User-controlled appearance preference. `.system` follows macOS Light/Dark
/// automatic switching; `.light` and `.dark` lock the app regardless of OS.
public enum AppearancePreference: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Returns `nil` for `.system` so SwiftUI's `.preferredColorScheme(nil)`
    /// hands control back to macOS.
    public var preferredScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@Observable
@MainActor
public final class AppStateModel {

    public enum ActiveScene: Sendable, Hashable {
        case onboarding
        case main
    }

    public var activeScene: ActiveScene
    public var onboardingComplete: Bool
    public var coachOverlayVisible: Bool
    public var notchHudVisible: Bool
    public var appearancePreference: AppearancePreference {
        didSet {
            UserDefaults.standard.set(appearancePreference.rawValue, forKey: AppStateModel.appearanceKey)
        }
    }
    /// Selected ASR engine for dictation.
    ///
    /// Persisted to UserDefaults so the
    /// next launch boots the same engine. The dictation runtime is rebuilt
    /// when this changes.
    public var dictationASREngine: DictationASREngine {
        didSet {
            UserDefaults.standard.set(dictationASREngine.rawValue, forKey: AppStateModel.dictationASRKey)
            // Invalidate the cached dictation runtime so the new engine takes
            // effect on the next capture instead of after an app restart.
            NotificationCenter.default.post(name: .traceDictationPrefsChanged, object: nil)
        }
    }
    /// The specific on-device model (an `ASRModelCatalog` id, e.g. `whisper-small`
    /// or `qwen3-asr-0.6b-int8`) selected in the dictation-models catalog.
    ///
    /// Picks
    /// the exact variant within the coarse `dictationASREngine` family; the
    /// runtime honors it only when its family matches the engine. Persisted so the
    /// choice survives relaunch, and a change rebuilds the dictation runtime.
    public var dictationLocalModelID: String {
        didSet {
            UserDefaults.standard.set(dictationLocalModelID, forKey: AppStateModel.dictationLocalModelKey)
            NotificationCenter.default.post(name: .traceDictationPrefsChanged, object: nil)
        }
    }
    /// Which cloud ASR provider the `.cloud` dictation engine talks to (BAS-21).
    ///
    /// Only consulted when `dictationASREngine == .cloud`; the matching API key
    /// lives in the Keychain. Persisted so the choice survives relaunch, and a
    /// change rebuilds the dictation runtime via the same notification.
    public var dictationCloudProvider: CloudASRProvider {
        didSet {
            UserDefaults.standard.set(dictationCloudProvider.rawValue, forKey: AppStateModel.dictationCloudProviderKey)
            NotificationCenter.default.post(name: .traceDictationPrefsChanged, object: nil)
        }
    }

    /// Which cloud ASR provider the **meeting** capture uses when
    /// `meetingASREngine == .cloud` (BAS-58).
    ///
    /// Mirror of `dictationCloudProvider`
    /// for the meeting path; read fresh when the meeting runtime is (re)built.
    public var meetingCloudProvider: CloudASRProvider {
        didSet {
            UserDefaults.standard.set(meetingCloudProvider.rawValue, forKey: AppStateModel.meetingCloudProviderKey)
            // Mirror `meetingASREngine`: a provider change must rebuild the meeting
            // runtime, otherwise the new provider is silently ignored until some
            // other meeting setting changes or the app restarts.
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }

    /// The language live **meeting** transcription decodes (BAS-74). `.auto` lets
    /// the engine detect it (WhisperKit) or falls back to the system locale; a
    /// specific language (e.g. Mandarin) stops a non-English meeting being mangled
    /// as English.
    ///
    /// Read fresh when the meeting runtime is (re)built.
    public var meetingTranscriptionLanguage: TranscriptionLanguage {
        didSet {
            UserDefaults.standard.set(meetingTranscriptionLanguage.rawValue, forKey: AppStateModel.meetingLanguageKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }

    /// The language **dictation** transcription decodes (BAS-74) — mirror of
    /// `meetingTranscriptionLanguage` for the dictation path.
    ///
    /// Writing rebuilds the
    /// dictation runtime on the next capture.
    public var dictationTranscriptionLanguage: TranscriptionLanguage {
        didSet {
            UserDefaults.standard.set(
                dictationTranscriptionLanguage.rawValue, forKey: AppStateModel.dictationLanguageKey)
            NotificationCenter.default.post(name: .traceDictationPrefsChanged, object: nil)
        }
    }

    /// Dense-arm cosine relevance floor for cross-meeting Q&A (BAS-30): dense hits
    /// below this are dropped before fusion so weak/garbage chunks aren't fed to the
    /// LLM. `0` disables the gate; the lexical (FTS) arm is never floored.
    ///
    /// The Settings
    /// slider bounds it to 0…0.9 and persisted values are clamped on load. Writing posts
    /// `traceLibraryQAConfigChanged` so the pipeline rebuilds with the new floor.
    public var qaRelevanceFloor: Double {
        didSet {
            UserDefaults.standard.set(qaRelevanceFloor, forKey: AppStateModel.qaRelevanceFloorKey)
            NotificationCenter.default.post(name: .traceLibraryQAConfigChanged, object: nil)
        }
    }
    /// Generalized per-task LLM routing preferences, one per `LLMRouteStage`
    /// (BAS-49).
    ///
    /// The single source of truth behind the named cleanup / notes /
    /// title / categorization / library-Q&A / conversation-state projections
    /// below. Mutated only through `setProvider`/`setModel`, which persist to the
    /// stage's legacy UserDefaults keys and post its config-changed notification.
    private var routeStages: [LLMRouteStage: RoutedStagePreference]

    // MARK: Per-task LLM routing (generalized — BAS-49)

    /// The chosen provider for `stage` (its default when nothing is persisted).
    public func provider(for stage: LLMRouteStage) -> DictationCleanupProvider {
        routeStages[stage]?.provider ?? stage.defaultProvider
    }

    /// Set + persist `stage`'s provider, then post its config-changed notification.
    /// No-op when the provider is unchanged — so applying a preset (or nudging a
    /// slider) only persists + notifies the stages that actually moved.
    public func setProvider(_ provider: DictationCleanupProvider, for stage: LLMRouteStage) {
        guard var pref = routeStages[stage], pref.provider != provider else { return }
        pref.provider = provider
        routeStages[stage] = pref
        pref.persist()
        NotificationCenter.default.post(name: stage.configChangedNotification, object: nil)
    }

    /// The model `stage` should use for `provider` — the user's override if set,
    /// otherwise the stage default (incl. the library-Q&A / conversation-state
    /// cross-reference to the notes Ollama model).
    public func model(for stage: LLMRouteStage, provider: DictationCleanupProvider) -> String {
        if let override = routeStages[stage]?.modelOverride(for: provider) { return override }
        return stage.defaultModel(
            for: provider,
            notesOllamaModel: {
                self.routeStages[.meetingNotes]?.modelOverride(for: .ollama)
                    ?? AppStateModel.defaultCleanupModel(for: .ollama)
            })
    }

    /// Set (or clear) `stage`'s model override for `provider`, persist, and post
    /// its config-changed notification. Clearing: always on blank; cleanup-family
    /// stages also clear when the value equals the base default model.
    public func setModel(_ model: String, for stage: LLMRouteStage, provider: DictationCleanupProvider) {
        guard var pref = routeStages[stage] else { return }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = pref.models
        let matchesBaseDefault = trimmed == AppStateModel.defaultCleanupModel(for: provider)
        if trimmed.isEmpty || (stage.clearsModelMatchingBaseDefault && matchesBaseDefault) {
            next.removeValue(forKey: provider.rawValue)
        } else {
            next[provider.rawValue] = trimmed
        }
        guard next != pref.models else { return }
        pref.models = next
        routeStages[stage] = pref
        pref.persist()
        NotificationCenter.default.post(name: stage.configChangedNotification, object: nil)
    }

    /// Apply a routing preset across every stage (BAS-6 / BAS-35).
    ///
    /// Each stage's
    /// provider is set + persisted + its config-changed notification posted, so
    /// the routes take effect live; per-provider model overrides are preserved.
    public func applyRoutePreset(_ preset: LLMRoutePreset) {
        for stage in LLMRouteStage.allCases {
            setProvider(preset.provider(for: stage), for: stage)
        }
    }

    /// The preset whose provider set matches every stage's current provider, or
    /// `nil` (= "Custom") when the user has deviated from all presets.
    public var activeRoutePreset: LLMRoutePreset? {
        LLMRoutePreset.allCases.first { preset in
            LLMRouteStage.allCases.allSatisfy { provider(for: $0) == preset.provider(for: $0) }
        }
    }

    // MARK: Named everyday projections over the route stages (thin forwarders)

    /// Cleanup provider preference (Settings → LLM Router) — projection over the
    /// `.dictationCleanup` route stage. `.deterministic` disables the LLM and
    /// uses our local capitalize+punctuate fixer.
    public var dictationCleanupProvider: DictationCleanupProvider {
        get { provider(for: .dictationCleanup) }
        set { setProvider(newValue, for: .dictationCleanup) }
    }

    /// The model the cleanup step should use for `provider` — override or default.
    public func cleanupModel(for provider: DictationCleanupProvider) -> String {
        model(for: .dictationCleanup, provider: provider)
    }

    /// Set (or clear, when blank/default) the cleanup model override for `provider`.
    public func setCleanupModel(_ model: String, for provider: DictationCleanupProvider) {
        setModel(model, for: .dictationCleanup, provider: provider)
    }

    /// The built-in default model for each cleanup provider. `nonisolated` so the
    /// `LLMRouteStage` descriptor (a value type) can resolve stage defaults.
    public nonisolated static func defaultCleanupModel(for provider: DictationCleanupProvider) -> String {
        // Single source of truth: the catalog's default model (empty for the
        // no-LLM `.deterministic` case). Free-text in the UI, so a newer id is
        // never blocked by this.
        provider.modelProvider?.defaultModel ?? ""
    }
    /// Show live interim transcript in the notch while dictating.
    ///
    /// Only takes
    /// effect when the selected ASR engine reports `supportsStreaming`; the
    /// Settings toggle is disabled otherwise.
    public var dictationShowLivePartials: Bool {
        didSet {
            UserDefaults.standard.set(dictationShowLivePartials, forKey: AppStateModel.livePartialsKey)
            NotificationCenter.default.post(name: .traceDictationPrefsChanged, object: nil)
        }
    }
    /// Press **Return** to finish dictation and send in one keystroke.
    ///
    /// While you’re dictating you’re speaking, not typing, so the Return key is
    /// free to repurpose. When this is on, a plain Return stops the capture,
    /// waits for the cleaned transcript to land in the focused app, then fires a
    /// Return to submit it (e.g. send the chat message). Your dictation hotkey
    /// still stops *without* sending, so you keep both options; Shift/⌘/Ctrl/⌥ +
    /// Return are never hijacked, and nothing is sent if the insert was empty or
    /// failed.
    ///
    /// Read once at the start of each dictation, so toggling it never rebuilds
    /// the runtime — there’s deliberately no notification posted here.
    public var dictationEnterSends: Bool {
        didSet {
            UserDefaults.standard.set(dictationEnterSends, forKey: AppStateModel.dictationEnterSendsKey)
        }
    }
    /// Opt-in meeting auto-detection.
    ///
    /// When `true`, the runtime arms an
    /// `AppActivityMonitor`. On detection it drops a notch prompt asking whether
    /// to start (unless `meetingAutoStartOnDetect` is on). Default `false` so we
    /// never surprise-record; manual ⌥M is unaffected. Writing posts a
    /// notification so the runtime coordinator (re-)arms or disarms the detector.
    public var meetingAutoDetectEnabled: Bool {
        didSet {
            UserDefaults.standard.set(meetingAutoDetectEnabled, forKey: AppStateModel.meetingAutoDetectKey)
            NotificationCenter.default.post(name: .traceMeetingAutoDetectChanged, object: nil)
        }
    }
    /// When auto-detect fires: `false` (default) drops a notch prompt asking to
    /// start taking notes; `true` starts recording immediately.
    ///
    /// Kept off so a
    /// false positive (e.g. a WhatsApp voice note) never auto-records.
    public var meetingAutoStartOnDetect: Bool {
        didSet {
            UserDefaults.standard.set(meetingAutoStartOnDetect, forKey: AppStateModel.meetingAutoStartKey)
        }
    }
    /// Bundle IDs the user has explicitly switched OFF for meeting auto-detect
    /// (Settings → Meetings → Auto-detect apps).
    ///
    /// We never auto-mute; this set is
    /// changed only by the user. Persisted.
    public private(set) var meetingMutedApps: Set<String>

    /// True when the user has turned this app off for auto-detect.
    public func isMeetingAppMuted(_ bundleID: String) -> Bool {
        meetingMutedApps.contains(bundleID)
    }

    /// Turn auto-detect for `bundleID` on/off and persist.
    public func setMeetingAppMuted(_ bundleID: String, muted: Bool) {
        if muted { meetingMutedApps.insert(bundleID) } else { meetingMutedApps.remove(bundleID) }
        if let data = try? JSONEncoder().encode(meetingMutedApps) {
            UserDefaults.standard.set(data, forKey: AppStateModel.meetingMutedAppsKey)
        }
    }

    /// User-added meeting apps (bundle IDs) beyond the built-in `MeetingAppCatalog`.
    ///
    /// These become both auto-detectable (the signal source unions them in) and
    /// listed in Settings → Meetings → Auto-detect apps. Persisted.
    public private(set) var meetingCustomApps: Set<String>

    /// Add a user-picked app to the auto-detect catalog and persist.
    public func addMeetingCustomApp(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        meetingCustomApps.insert(bundleID)
        // A freshly added app should be detectable — clear any stale mute first.
        meetingMutedApps.remove(bundleID)
        if let data = try? JSONEncoder().encode(meetingMutedApps) {
            UserDefaults.standard.set(data, forKey: AppStateModel.meetingMutedAppsKey)
        }
        persistMeetingCustomApps()
    }

    /// Remove a previously user-added app (built-in catalog apps can't be removed).
    public func removeMeetingCustomApp(_ bundleID: String) {
        meetingCustomApps.remove(bundleID)
        persistMeetingCustomApps()
    }

    private func persistMeetingCustomApps() {
        if let data = try? JSONEncoder().encode(meetingCustomApps) {
            UserDefaults.standard.set(data, forKey: AppStateModel.meetingCustomAppsKey)
        }
        // Re-arm the detector so the added/removed app is (un)recognized at once.
        NotificationCenter.default.post(name: .traceMeetingAutoDetectChanged, object: nil)
    }
    /// Whether the rolling in-meeting summary runs during a live meeting.
    ///
    /// When
    /// `false`, no `LiveSummaryEngine` is wired into the meeting runtime (the
    /// finalized augmented-notes merge at stop is unaffected). Default `true`.
    /// Writing posts a notification so the runtime coordinator rebuilds the
    /// meeting runtime before the NEXT meeting (an in-progress meeting keeps its
    /// current configuration).
    public var meetingLiveSummaryEnabled: Bool {
        didSet {
            UserDefaults.standard.set(meetingLiveSummaryEnabled, forKey: AppStateModel.meetingLiveSummaryEnabledKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }
    /// Master switch for per-speaker diarization (**beta**).
    ///
    /// OFF (default) keeps
    /// the standard You / Others transcript; ON identifies remote
    /// participants as Speaker 1, 2, … The live/offline sub-toggles below only
    /// apply when this is on, and even then a meeting only diarizes once
    /// `diarizationReadiness` is `.ready`. Writing posts
    /// `traceMeetingConfigChanged` so the coordinator prepares models + rebuilds
    /// before the next meeting (BAS-10).
    public var meetingDiarizationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(meetingDiarizationEnabled, forKey: AppStateModel.meetingDiarizationEnabledKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }

    /// Whether the on-device diarization models are prepared (downloaded +
    /// compiled).
    ///
    /// Seeded from a persisted flag (the model cache survives
    /// launches); the coordinator prepares them in the background when the feature
    /// is enabled. Meetings only diarize when this is `.ready` — otherwise they
    /// fall back to You / Others rather than stalling on a first-use download.
    public let diarizationReadiness: DiarizationModelReadiness

    /// Whether live (display-only) per-speaker diarization runs on the system
    /// stream, labeling remote turns `remote_1 / remote_2 / …` as people speak.
    ///
    /// Cheap + on-device. Default `true`. Only applies when `meetingDiarizationEnabled`.
    /// Writing posts `traceMeetingConfigChanged` so the NEXT meeting's runtime
    /// picks it up (BAS-10).
    public var meetingLiveDiarizationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                meetingLiveDiarizationEnabled, forKey: AppStateModel.meetingLiveDiarizationEnabledKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }
    /// Whether the heavyweight offline pass re-diarizes the recorded system audio
    /// at finalize and rewrites the transcript with stable per-speaker labels (the
    /// source of truth).
    ///
    /// Records the system stream to disk during capture when on.
    /// On-device. Default `true`. Writing posts `traceMeetingConfigChanged` (BAS-10).
    public var meetingOfflineDiarizationRefinementEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                meetingOfflineDiarizationRefinementEnabled,
                forKey: AppStateModel.meetingOfflineDiarizationRefinementEnabledKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }
    /// Whether the offline pass also remembers speakers ACROSS meetings: the
    /// per-speaker voiceprints from refinement are matched against a project-scoped,
    /// on-device speaker DB, so a "Speaker 2 → Sarah" rename made once auto-applies
    /// to future meetings (BAS-11, design §14.3).
    ///
    /// Opt-in → default `false`; the
    /// voiceprints stay on your Mac and can be cleared. Only meaningful when
    /// `meetingOfflineDiarizationRefinementEnabled` is on (that pass is the only
    /// source of the embeddings). Writing posts `traceMeetingConfigChanged` so
    /// the next meeting's runtime picks it up.
    public var meetingSpeakerMemoryEnabled: Bool {
        didSet {
            UserDefaults.standard.set(meetingSpeakerMemoryEnabled, forKey: AppStateModel.meetingSpeakerMemoryEnabledKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }
    /// How many speaker voiceprints are remembered on this Mac (all projects).
    ///
    /// Runtime-only (not persisted) — the coordinator refreshes it at launch, after
    /// each meeting, and after a clear; shown in Settings next to "Forget remembered
    /// speakers" so the on-device memory is legible (BAS-11).
    public var meetingRememberedSpeakerCount: Int = 0
    /// Keep the on-device call recording (`sys.caf`) after the offline pass refines
    /// it, so speakers can be re-refined later (BAS-41).
    ///
    /// Default `false` → the
    /// recording (~230 MB/hour) is deleted once refined, so recordings don't pile
    /// up. Only meaningful when offline refinement is on (it makes the recording).
    public var meetingKeepCallRecordingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                meetingKeepCallRecordingEnabled, forKey: AppStateModel.meetingKeepCallRecordingEnabledKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }
    /// Cadence, in seconds, for the rolling in-meeting summary.
    ///
    /// The
    /// `LiveSummaryEngine` gates on this elapsed time before producing a new
    /// rolling summary. Only meaningful when `meetingLiveSummaryEnabled` is
    /// `true`. Default `60`. Writing posts `traceMeetingConfigChanged`.
    public var meetingLiveSummaryCadenceSeconds: Int {
        didSet {
            UserDefaults.standard.set(
                meetingLiveSummaryCadenceSeconds, forKey: AppStateModel.meetingLiveSummaryCadenceKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }
    /// ASR engine used for live meeting transcription (`.meetingCaptureLive`).
    ///
    /// Persisted; default `.parakeet` (offline, multilingual, reliable for the
    /// two-stream meeting capture). Writing posts `traceMeetingConfigChanged`
    /// so the runtime coordinator rebuilds the meeting runtime before the NEXT
    /// meeting (an in-progress meeting keeps its current engine).
    public var meetingASREngine: DictationASREngine {
        didSet {
            UserDefaults.standard.set(meetingASREngine.rawValue, forKey: AppStateModel.meetingASRKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }
    /// Provider for the meeting notes & summary LLM — projection over the
    /// `.meetingNotes` route stage (drives `.meetingSummary` + `.meetingAugmentedMerge`).
    public var meetingNotesProvider: DictationCleanupProvider {
        get { provider(for: .meetingNotes) }
        set { setProvider(newValue, for: .meetingNotes) }
    }
    /// Provider for the meeting-title LLM (`.titleGeneration`, BAS-29).
    public var meetingTitleProvider: DictationCleanupProvider {
        get { provider(for: .meetingTitle) }
        set { setProvider(newValue, for: .meetingTitle) }
    }
    /// Provider for the auto-categorization classifier (`.projectCategorization`, BAS-9).
    public var meetingCategorizationProvider: DictationCleanupProvider {
        get { provider(for: .meetingCategorization) }
        set { setProvider(newValue, for: .meetingCategorization) }
    }

    /// The LLM stages that make up the end-of-meeting pass — notes, title, and
    /// auto-categorization.
    ///
    /// These are configured as ONE choice in Settings (the
    /// user shouldn't have to pick a model three separate times); power users can
    /// still override an individual stage in the LLM Router (Advanced) section.
    public static let meetingAIStages: [LLMRouteStage] = [.meetingNotes, .meetingTitle, .meetingCategorization]

    /// The single "Meeting AI model" provider that drives every `meetingAIStages`
    /// stage.
    ///
    /// Setting it fans the choice (provider AND the active model) out to all
    /// of them, so the three stages always agree unless individually overridden in
    /// the Advanced LLM Router. Reads from `.meetingNotes` as the canonical stage.
    /// The MODEL fan-out across `meetingAIStages` is done by the settings UI via
    /// `StageModelRow.mirrorStages` — keep the two in sync if either changes.
    public var meetingAIProvider: DictationCleanupProvider {
        get { provider(for: .meetingNotes) }
        set {
            let model = model(for: .meetingNotes, provider: newValue)
            for stage in Self.meetingAIStages {
                setProvider(newValue, for: stage)
                setModel(model, for: stage, provider: newValue)
            }
        }
    }

    /// The LLM stages that make up the live in-meeting coach — the card content
    /// the user reads as "the coach", the smart-routing classifier behind it, and
    /// the running conversation-state summary that grounds it.
    ///
    /// Configured as ONE
    /// choice in Settings → Coach (the user shouldn't pick a model three times);
    /// power users can still override an individual stage in the LLM Router
    /// (Advanced). `.coachCardContent` is the canonical stage the group reads.
    public static let coachAIStages: [LLMRouteStage] = [.coachCardContent, .coachSmartRouting, .conversationState]

    /// The single "Coach AI model" provider that drives every `coachAIStages`
    /// stage.
    ///
    /// Setting it fans the choice (provider AND the active model) out to all
    /// of them, so the coach always runs on one coherent model unless individually
    /// overridden in the Advanced LLM Router. Reads from `.coachCardContent`.
    /// The MODEL fan-out across `coachAIStages` is done by the settings UI via
    /// `StageModelRow.mirrorStages` — keep the two in sync if either changes.
    public var coachAIProvider: DictationCleanupProvider {
        get { provider(for: .coachCardContent) }
        set {
            let model = model(for: .coachCardContent, provider: newValue)
            for stage in Self.coachAIStages {
                setProvider(newValue, for: stage)
                setModel(model, for: stage, provider: newValue)
            }
        }
    }

    /// Provider for cross-meeting Q&A / library search (`.libraryQA`).
    public var libraryQAProvider: DictationCleanupProvider {
        get { provider(for: .libraryQA) }
        set { setProvider(newValue, for: .libraryQA) }
    }
    /// Provider for the in-meeting conversation-state extractor (`.conversationStateExtractor`, BAS-16).
    public var conversationStateProvider: DictationCleanupProvider {
        get { provider(for: .conversationState) }
        set { setProvider(newValue, for: .conversationState) }
    }
    /// Seconds of continuous silence (no committed speech on either stream)
    /// before the meeting runtime offers the "Call ended?" notch prompt.
    ///
    /// Default
    /// `60`. Writing posts `traceMeetingConfigChanged` so the NEXT meeting
    /// rebuilds with the new threshold (an in-progress meeting keeps its own).
    public var meetingSilenceThresholdSeconds: Int {
        didSet {
            UserDefaults.standard.set(meetingSilenceThresholdSeconds, forKey: AppStateModel.meetingSilenceThresholdKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }
    /// Seconds of *captured-speech* silence (VAD, both streams) after which an
    /// auto-detected meeting hard-stops + finalizes (BAS-13) — separate from and
    /// longer than the soft "Call ended?" prompt above.
    ///
    /// Default `600` (10 min).
    /// Only applies while `meetingAutoDetectEnabled` is on (manual meetings stay
    /// manual). Writing posts `traceMeetingConfigChanged` so the next meeting
    /// picks it up.
    public var meetingAutoStopSilenceSeconds: Int {
        didSet {
            UserDefaults.standard.set(meetingAutoStopSilenceSeconds, forKey: AppStateModel.meetingAutoStopSilenceKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }
    /// Seconds the notch auto-detect / "Call ended?" prompts stay up before they
    /// auto-dismiss (the faint countdown line tracks this).
    ///
    /// Default `15`. Read
    /// live at prompt time, so a change applies to the next prompt immediately.
    public var meetingPromptTimeoutSeconds: Int {
        didSet {
            UserDefaults.standard.set(meetingPromptTimeoutSeconds, forKey: AppStateModel.meetingPromptTimeoutKey)
        }
    }
    /// The single editable system prompt for the meeting summarizer — replaces
    /// the per-type template library.
    ///
    /// One prompt, plus an optional per-regenerate
    /// "emphasis" steer. Persisted.
    public var meetingSummaryInstructions: String {
        didSet {
            UserDefaults.standard.set(meetingSummaryInstructions, forKey: AppStateModel.meetingSummaryInstructionsKey)
        }
    }

    public static let defaultMeetingSummaryInstructions = """
        Write clear, accurate meeting notes from the transcript and the user's notes. \
        Organize them under headings that fit what was actually discussed — group related points into topics and \
        name each section for its content, instead of using a fixed set of sections. \
        If any decisions, commitments, action items (with owners), deadlines, or dates were stated, always capture \
        them explicitly so nothing actionable is lost. \
        Keep every point grounded in what was actually said; never invent anything, and leave out anything that didn't come up.
        """
    /// Master switch for the in-meeting Coach overlay.
    ///
    /// When on, starting a
    /// meeting presents the screen-share-invisible coach panel and runs the
    /// detection pipeline. Default on; per-mode config lives in Coach settings.
    public var coachEnabled: Bool {
        didSet {
            UserDefaults.standard.set(coachEnabled, forKey: AppStateModel.coachEnabledKey)
            NotificationCenter.default.post(name: .traceCoachConfigChanged, object: nil)
        }
    }
    /// Behavior config for the in-meeting Coach — which card modes may surface,
    /// the per-meeting surface budget, adaptive throttle, the optional
    /// anti-fabrication post-check, and the manual triple-tap trigger.
    ///
    /// The master
    /// on/off is `coachEnabled`; this is consulted while Coach is enabled.
    /// Persisted as JSON. Writing posts `traceCoachConfigChanged` so a live
    /// meeting's orchestrator adopts the change immediately and the triple-tap
    /// monitor is rebuilt from the new trigger config.
    public var coachConfig: CoachConfig {
        didSet {
            if let data = try? JSONEncoder().encode(coachConfig) {
                UserDefaults.standard.set(data, forKey: AppStateModel.coachConfigKey)
            }
            NotificationCenter.default.post(name: .traceCoachConfigChanged, object: nil)
        }
    }

    /// Meeting notes & summary model for `provider` — override or default.
    public func meetingNotesModel(for provider: DictationCleanupProvider) -> String {
        model(for: .meetingNotes, provider: provider)
    }
    /// Set (or clear) the meeting notes model override for `provider`.
    public func setMeetingNotesModel(_ model: String, for provider: DictationCleanupProvider) {
        setModel(model, for: .meetingNotes, provider: provider)
    }

    // Title / categorization / library-Q&A / conversation-state stages have no
    // named model accessors — their settings rows read/write the generalized
    // model(for:provider:) / setModel(_:for:provider:) directly via StageModelRow.

    // MARK: Embedding provider (BAS-17 — a separate axis from the LLM stages)

    /// Embedding provider — local Ollama (default) or a cloud OpenAI-compatible
    /// endpoint (OpenAI / Voyage).
    ///
    /// Drives the `.embeddingsIndex`/`.embeddingsLive`
    /// routes + the shared RAG fingerprint. Writing posts
    /// `traceEmbeddingConfigChanged` so the coordinator re-routes + rebuilds the
    /// cached RAG components.
    public var embeddingProvider: EmbeddingProviderChoice {
        didSet {
            UserDefaults.standard.set(embeddingProvider.rawValue, forKey: AppStateModel.embeddingProviderKey)
            NotificationCenter.default.post(name: .traceEmbeddingConfigChanged, object: nil)
        }
    }
    /// Per-provider embedding model override, keyed by `EmbeddingProviderChoice.rawValue`.
    public var embeddingModels: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(embeddingModels) {
                UserDefaults.standard.set(data, forKey: AppStateModel.embeddingModelsKey)
            }
            NotificationCenter.default.post(name: .traceEmbeddingConfigChanged, object: nil)
        }
    }

    /// The model the embedding step should use for `choice` — override or default.
    public func embeddingModel(for choice: EmbeddingProviderChoice) -> String {
        let override = embeddingModels[choice.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return choice.defaultModel
    }

    /// Set (or clear, when blank/default) the embedding model override for `choice`.
    public func setEmbeddingModel(_ model: String, for choice: EmbeddingProviderChoice) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = embeddingModels
        if trimmed.isEmpty || trimmed == choice.defaultModel {
            next.removeValue(forKey: choice.rawValue)
        } else {
            next[choice.rawValue] = trimmed
        }
        guard next != embeddingModels else { return }
        embeddingModels = next
    }

    /// The router embedding route for the current choice + model.
    public func embeddingRoute() -> EmbeddingRoute {
        embeddingProvider.route(model: embeddingModel(for: embeddingProvider))
    }

    /// The shared embedding config (fingerprint + normalization) for the current choice + model.
    public func embeddingConfig() -> EmbeddingConfig {
        embeddingProvider.config(model: embeddingModel(for: embeddingProvider))
    }

    // MARK: Storage / cache budget (BAS-44)

    /// Soft cap (GB) on retained audio recordings.
    ///
    /// The audio archive is pruned
    /// oldest-first to stay under it. Writing posts `traceCacheBudgetChanged`
    /// so the coordinator prunes immediately when the budget is lowered.
    public var cacheBudgetGb: Double {
        didSet {
            UserDefaults.standard.set(cacheBudgetGb, forKey: AppStateModel.cacheBudgetKey)
            NotificationCenter.default.post(name: .traceCacheBudgetChanged, object: nil)
        }
    }
    /// Human-readable summary of the last prune (runtime-only; set by the
    /// coordinator).
    ///
    /// Surfaced in Settings → Library & Storage so pruning is legible.
    public var lastCachePruneSummary: String?

    // MARK: Updates (BAS-24)

    /// Whether Sparkle checks for updates automatically.
    ///
    /// Writing posts
    /// `traceUpdaterPrefsChanged` so the AppDelegate applies it to the updater.
    public var autoUpdatesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoUpdatesEnabled, forKey: AppStateModel.autoUpdatesKey)
            NotificationCenter.default.post(name: .traceUpdaterPrefsChanged, object: nil)
        }
    }
    /// Update channel label ("Stable" / "Beta").
    ///
    /// Persisted; the channel→feed-URL
    /// switch is tracked as a follow-up.
    public var updateChannel: String {
        didSet { UserDefaults.standard.set(updateChannel, forKey: AppStateModel.updateChannelKey) }
    }

    // MARK: Calendar (BAS-24)

    /// Whether meeting capture consults the calendar (EventKit) to contextualize a
    /// recording.
    ///
    /// Persisted; read by the meeting calendar resolution. Writing posts
    /// `traceMeetingConfigChanged` so the next meeting runtime re-reads it.
    public var meetingCalendarEnabled: Bool {
        didSet {
            UserDefaults.standard.set(meetingCalendarEnabled, forKey: AppStateModel.meetingCalendarEnabledKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }
    /// ± window (minutes) for matching a recording to a calendar event.
    ///
    /// Persisted.
    public var meetingCalendarWindowMinutes: Int {
        didSet {
            UserDefaults.standard.set(meetingCalendarWindowMinutes, forKey: AppStateModel.meetingCalendarWindowKey)
            NotificationCenter.default.post(name: .traceMeetingConfigChanged, object: nil)
        }
    }

    /// User-customized global hotkey bindings, keyed by `HotkeyAction.rawValue`.
    ///
    /// Persisted as JSON in UserDefaults. Writing posts a notification so the
    /// runtime coordinator re-registers the Carbon hotkeys.
    public var hotkeyBindings: [String: HotkeyDescriptor] {
        didSet {
            if let data = try? JSONEncoder().encode(hotkeyBindings) {
                UserDefaults.standard.set(data, forKey: AppStateModel.hotkeyKey)
            }
            NotificationCenter.default.post(name: AppStateModel.hotkeysChangedNotification, object: nil)
        }
    }

    /// Resolves the descriptor for an action, falling back to its default.
    public func descriptor(for actionID: String, default fallback: HotkeyDescriptor) -> HotkeyDescriptor {
        hotkeyBindings[actionID] ?? fallback
    }

    public var activeCapture: ActiveCaptureModel
    /// Rich live-meeting state (transcript, per-speaker partials, notes, summary).
    ///
    /// The meeting runtime is the only writer; the tri-column meeting UI binds to it.
    /// Distinct from `activeCapture`, which is the coarse mode/timer for chrome.
    public var meetingLive: MeetingLiveModel
    /// Browsable history of past meetings for the "All meetings" library.
    ///
    /// Reads
    /// are wired by AppRuntimeCoordinator (which owns the database + markdown).
    public let meetingLibrary = MeetingLibraryModel()
    /// Backs Library → Playbooks (per-project reference folders for the Coach).
    public let playbooks = PlaybooksModel()
    /// Backs Library → Search / cross-meeting Q&A (the ⌘K / Inbox surface).
    public let librarySearch = LibrarySearchModel()
    /// Backs the Files & Voice Memos surfaces (batch queue + completed lists).
    public let fileBatch = FileBatchModel()
    /// The project the user is currently viewing in the sidebar (nil = Inbox/All).
    ///
    /// Ephemeral UI context: a meeting started while viewing a project files into
    /// it. Set by the main window when the sidebar selection changes.
    public var currentProjectContext: String?

    /// User-added watched folders.
    ///
    /// Each is scanned + watched; new audio/video
    /// files are auto-enqueued for transcription under the folder's project /
    /// template rules. Persisted as JSON. Writing posts
    /// `.traceWatchedFoldersChanged` so the coordinator (re-)starts watchers.
    public var watchedFolders: [WatchedFolderConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(watchedFolders) {
                UserDefaults.standard.set(data, forKey: AppStateModel.watchedFoldersKey)
            }
            NotificationCenter.default.post(name: .traceWatchedFoldersChanged, object: nil)
        }
    }
    /// iPhone Voice Memos iCloud sync.
    ///
    /// Default OFF — opt-in, never surprise-import
    /// (see beta/opt-in convention). When on, the coordinator watches the iCloud
    /// Voice Memos folder and transcribes new recordings as voice memos. Writing
    /// posts `.traceWatchedFoldersChanged`.
    public var voiceMemoSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceMemoSyncEnabled, forKey: AppStateModel.voiceMemoSyncKey)
            NotificationCenter.default.post(name: .traceWatchedFoldersChanged, object: nil)
        }
    }
    /// Whether enabling Voice-Memo sync also imports recordings already in the
    /// folder (the one-time retroactive import).
    ///
    /// Default OFF — first-enable
    /// watches only NEW recordings unless the user opts into the backlog.
    public var voiceMemoImportExisting: Bool {
        didSet {
            UserDefaults.standard.set(voiceMemoImportExisting, forKey: AppStateModel.voiceMemoImportExistingKey)
        }
    }

    public init(onboardingComplete: Bool = false) {
        self.onboardingComplete = onboardingComplete
        self.activeScene = onboardingComplete ? .main : .onboarding
        self.coachOverlayVisible = false
        self.notchHudVisible = false
        let appearanceRaw = UserDefaults.standard.string(forKey: AppStateModel.appearanceKey)
        self.appearancePreference = appearanceRaw.flatMap(AppearancePreference.init(rawValue:)) ?? .system
        let asrRaw = UserDefaults.standard.string(forKey: AppStateModel.dictationASRKey)
        // Default to Parakeet: Apple's on-device SFSpeechRecognizer proved
        // unreliable for dictation (intermittent empty batch results, chunked
        // streaming that drops words). Parakeet (FluidAudio, offline) transcribes
        // the whole buffer in one reliable pass.
        self.dictationASREngine = asrRaw.flatMap(DictationASREngine.init(rawValue:)) ?? .parakeet
        self.dictationLocalModelID =
            UserDefaults.standard.string(forKey: AppStateModel.dictationLocalModelKey) ?? "parakeet-tdt-v3"
        let cloudASRRaw = UserDefaults.standard.string(forKey: AppStateModel.dictationCloudProviderKey)
        self.dictationCloudProvider = cloudASRRaw.flatMap(CloudASRProvider.init(rawValue:)) ?? .openai
        let meetingCloudASRRaw = UserDefaults.standard.string(forKey: AppStateModel.meetingCloudProviderKey)
        self.meetingCloudProvider = meetingCloudASRRaw.flatMap(CloudASRProvider.init(rawValue:)) ?? .openai
        self.dictationTranscriptionLanguage =
            UserDefaults.standard.string(forKey: AppStateModel.dictationLanguageKey)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .auto
        self.meetingTranscriptionLanguage =
            UserDefaults.standard.string(forKey: AppStateModel.meetingLanguageKey)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .auto
        // BAS-30: `object(forKey:)` (not `double`) so an unset key restores the
        // default floor rather than 0 (which would disable the gate); clamp on load.
        let storedFloor = UserDefaults.standard.object(forKey: AppStateModel.qaRelevanceFloorKey) as? Double
        self.qaRelevanceFloor =
            storedFloor.map { min(max($0, 0), 0.9) }
            ?? Double(QASearchPipeline.defaultDenseFloor)
        // Generalized per-task LLM routing preferences (BAS-49): restore every
        // stage from its legacy keys in one loop instead of N isomorphic blocks.
        self.routeStages = Dictionary(
            uniqueKeysWithValues: LLMRouteStage.allCases.map { ($0, RoutedStagePreference(stage: $0)) }
        )
        // Embedding provider (BAS-17): all-local Ollama default.
        self.embeddingProvider =
            UserDefaults.standard.string(forKey: AppStateModel.embeddingProviderKey)
            .flatMap(EmbeddingProviderChoice.init(rawValue:)) ?? .ollama
        if let embeddingModelData = UserDefaults.standard.data(forKey: AppStateModel.embeddingModelsKey),
            let decodedEmbeddingModels = try? JSONDecoder().decode([String: String].self, from: embeddingModelData)
        {
            self.embeddingModels = decodedEmbeddingModels
        } else {
            self.embeddingModels = [:]
        }
        // Cache budget (BAS-44): default 10 GB soft cap on retained recordings.
        self.cacheBudgetGb = UserDefaults.standard.object(forKey: AppStateModel.cacheBudgetKey) as? Double ?? 10
        // Updates + Calendar prefs (BAS-24).
        self.autoUpdatesEnabled = UserDefaults.standard.object(forKey: AppStateModel.autoUpdatesKey) as? Bool ?? true
        self.updateChannel = UserDefaults.standard.string(forKey: AppStateModel.updateChannelKey) ?? "Stable"
        self.meetingCalendarEnabled =
            UserDefaults.standard.object(forKey: AppStateModel.meetingCalendarEnabledKey) as? Bool ?? true
        self.meetingCalendarWindowMinutes =
            UserDefaults.standard.object(forKey: AppStateModel.meetingCalendarWindowKey) as? Int ?? 15
        self.dictationShowLivePartials =
            UserDefaults.standard.object(forKey: AppStateModel.livePartialsKey) as? Bool ?? true
        // Default ON: the requested ergonomic — Return ends dictation and sends.
        self.dictationEnterSends =
            UserDefaults.standard.object(forKey: AppStateModel.dictationEnterSendsKey) as? Bool ?? true
        // Default OFF: never surprise-record. Only an explicit opt-in arms the detector.
        self.meetingAutoDetectEnabled =
            UserDefaults.standard.object(forKey: AppStateModel.meetingAutoDetectKey) as? Bool ?? false
        self.meetingAutoStartOnDetect =
            UserDefaults.standard.object(forKey: AppStateModel.meetingAutoStartKey) as? Bool ?? false
        if let data = UserDefaults.standard.data(forKey: AppStateModel.meetingMutedAppsKey),
            let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
        {
            self.meetingMutedApps = decoded
        } else {
            self.meetingMutedApps = []
        }
        if let data = UserDefaults.standard.data(forKey: AppStateModel.meetingCustomAppsKey),
            let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
        {
            self.meetingCustomApps = decoded
        } else {
            self.meetingCustomApps = []
        }
        self.meetingSilenceThresholdSeconds =
            UserDefaults.standard.object(forKey: AppStateModel.meetingSilenceThresholdKey) as? Int ?? 60
        // Hard auto-stop after sustained silence (BAS-13): default 600s (10 min).
        self.meetingAutoStopSilenceSeconds =
            UserDefaults.standard.object(forKey: AppStateModel.meetingAutoStopSilenceKey) as? Int ?? 600
        self.meetingPromptTimeoutSeconds =
            UserDefaults.standard.object(forKey: AppStateModel.meetingPromptTimeoutKey) as? Int ?? 15
        self.meetingSummaryInstructions =
            UserDefaults.standard.string(forKey: AppStateModel.meetingSummaryInstructionsKey)
            ?? AppStateModel.defaultMeetingSummaryInstructions
        self.coachEnabled = UserDefaults.standard.object(forKey: AppStateModel.coachEnabledKey) as? Bool ?? true
        if let coachConfigData = UserDefaults.standard.data(forKey: AppStateModel.coachConfigKey),
            let decodedCoachConfig = try? JSONDecoder().decode(CoachConfig.self, from: coachConfigData)
        {
            self.coachConfig = decodedCoachConfig
        } else {
            self.coachConfig = CoachConfig()
        }
        // Default ON: the rolling summary is a core meeting affordance.
        self.meetingLiveSummaryEnabled =
            UserDefaults.standard.object(forKey: AppStateModel.meetingLiveSummaryEnabledKey) as? Bool ?? true
        self.meetingLiveSummaryCadenceSeconds =
            UserDefaults.standard.object(forKey: AppStateModel.meetingLiveSummaryCadenceKey) as? Int ?? 60
        // Per-speaker diarization (BAS-10): master OFF by default (beta opt-in →
        // standard You / Others); sub-passes default ON so enabling the master
        // gives the full experience. Readiness seeds from the persisted
        // prepared-once flag (the model cache survives launches).
        self.meetingDiarizationEnabled =
            UserDefaults.standard.object(forKey: AppStateModel.meetingDiarizationEnabledKey) as? Bool ?? false
        self.diarizationReadiness = DiarizationModelReadiness(
            preparedBefore: UserDefaults.standard.bool(forKey: AppStateModel.diarizationModelsPreparedOnceKey)
        )
        self.meetingLiveDiarizationEnabled =
            UserDefaults.standard.object(forKey: AppStateModel.meetingLiveDiarizationEnabledKey) as? Bool ?? true
        self.meetingOfflineDiarizationRefinementEnabled =
            UserDefaults.standard.object(forKey: AppStateModel.meetingOfflineDiarizationRefinementEnabledKey) as? Bool
            ?? true
        // Cross-meeting speaker memory (BAS-11): opt-in, default OFF — on-device
        // voiceprints that stay on your Mac until you enable it (and are wipeable).
        self.meetingSpeakerMemoryEnabled =
            UserDefaults.standard.object(forKey: AppStateModel.meetingSpeakerMemoryEnabledKey) as? Bool ?? false
        // Keep call recordings (BAS-41): default OFF → sys.caf is deleted once the
        // offline pass refines it, so meeting recordings don't accumulate on disk.
        self.meetingKeepCallRecordingEnabled =
            UserDefaults.standard.object(forKey: AppStateModel.meetingKeepCallRecordingEnabledKey) as? Bool ?? false
        let meetingASRRaw = UserDefaults.standard.string(forKey: AppStateModel.meetingASRKey)
        // Default to Parakeet for the same reliability reasons as dictation: the
        // offline single-pass engine handles the two-stream meeting capture well.
        self.meetingASREngine = meetingASRRaw.flatMap(DictationASREngine.init(rawValue:)) ?? .parakeet
        if let data = UserDefaults.standard.data(forKey: AppStateModel.hotkeyKey),
            let decoded = try? JSONDecoder().decode([String: HotkeyDescriptor].self, from: data)
        {
            self.hotkeyBindings = decoded
        } else {
            self.hotkeyBindings = [:]
        }
        if let data = UserDefaults.standard.data(forKey: AppStateModel.watchedFoldersKey),
            let decoded = try? JSONDecoder().decode([WatchedFolderConfig].self, from: data)
        {
            self.watchedFolders = decoded
        } else {
            self.watchedFolders = []
        }
        self.voiceMemoSyncEnabled = UserDefaults.standard.bool(forKey: AppStateModel.voiceMemoSyncKey)
        self.voiceMemoImportExisting = UserDefaults.standard.bool(forKey: AppStateModel.voiceMemoImportExistingKey)
        self.activeCapture = ActiveCaptureModel()
        self.meetingLive = MeetingLiveModel()
    }

    /// The four AI modes the onboarding "AI for your text" step offers. `.off`
    /// is the default: no LLM calls, deterministic dictation cleanup, and the
    /// LLM-backed extras (coach, live meeting summary) disabled so nothing
    /// reaches out.
    ///
    /// The other three route every generative stage to a single
    /// provider and re-enable those extras.
    public enum AIMode: Sendable, Hashable {
        case off
        case cloud(DictationCleanupProvider)
        case appleFM
        case ollama
    }

    /// Apply the chosen AI mode across the routing stages + the LLM-backed
    /// feature toggles.
    ///
    /// Synchronous + MainActor so an onboarding button action
    /// can call it directly (the executor bug forbids hopping back onto
    /// MainActor from a Task). Never sets a model override — the provider's
    /// catalog default model is used, and per-task routing stays in Settings.
    public func applyAIMode(_ mode: AIMode) {
        // The generative stages onboarding speaks for. We deliberately route the
        // whole set to one provider here; power users re-split them in Settings.
        let generativeStages: [LLMRouteStage] = [
            .dictationCleanup, .meetingNotes, .meetingTitle, .meetingCategorization,
            .libraryQA, .conversationState, .coachSmartRouting, .coachCardContent,
        ]
        switch mode {
        case .off:
            // No LLM anywhere: deterministic cleanup + disable the extras that
            // would otherwise call out. Other stages keep their (unused) routes;
            // nothing invokes them while coach/live-summary are off and cleanup
            // is deterministic.
            dictationCleanupProvider = .deterministic
            coachEnabled = false
            meetingLiveSummaryEnabled = false
        case .cloud(let provider):
            for stage in generativeStages {
                setProvider(provider, for: stage)
            }
            coachEnabled = true
            meetingLiveSummaryEnabled = true
        case .appleFM:
            for stage in generativeStages {
                setProvider(.appleFM, for: stage)
            }
            coachEnabled = true
            meetingLiveSummaryEnabled = true
        case .ollama:
            for stage in generativeStages {
                setProvider(.ollama, for: stage)
            }
            coachEnabled = true
            meetingLiveSummaryEnabled = true
        }
    }

    public func markOnboardingComplete() {
        onboardingComplete = true
        activeScene = .main
        UserDefaults.standard.set(true, forKey: AppStateModel.onboardingKey)
    }

    /// Re-run onboarding (About → "Re-run setup", BAS-24): clear the persisted
    /// completion flag and return to the onboarding scene.
    public func resetOnboarding() {
        onboardingComplete = false
        activeScene = .onboarding
        UserDefaults.standard.removeObject(forKey: AppStateModel.onboardingKey)
    }

    private static let onboardingKey = "app.trace.onboardingComplete"
    private static let appearanceKey = "app.trace.appearancePreference"
    static let dictationASRKey = "app.trace.dictation.asrEngine"
    static let dictationLocalModelKey = "app.trace.dictation.localModelID"
    static let dictationCloudProviderKey = "app.trace.dictation.cloudASRProvider"
    static let meetingCloudProviderKey = "app.trace.meeting.cloudASRProvider"
    static let dictationLanguageKey = "app.trace.dictation.language"
    static let meetingLanguageKey = "app.trace.meeting.language"
    static let qaRelevanceFloorKey = "app.trace.library.qaRelevanceFloor"
    static let watchedFoldersKey = "app.trace.files.watchedFolders"
    static let voiceMemoSyncKey = "app.trace.files.voiceMemoSyncEnabled"
    static let voiceMemoImportExistingKey = "app.trace.files.voiceMemoImportExisting"
    static let embeddingProviderKey = "app.trace.embedding.provider"
    static let embeddingModelsKey = "app.trace.embedding.models"
    static let cacheBudgetKey = "app.trace.storage.cacheBudgetGb"
    static let autoUpdatesKey = "app.trace.updates.autoEnabled"
    static let updateChannelKey = "app.trace.updates.channel"
    static let meetingCalendarEnabledKey = "app.trace.meeting.calendarEnabled"
    static let meetingCalendarWindowKey = "app.trace.meeting.calendarWindowMinutes"
    static let hotkeyKey = "app.trace.hotkeyBindings"
    static let livePartialsKey = "app.trace.dictation.showLivePartials"
    static let dictationEnterSendsKey = "app.trace.dictation.enterSends"
    static let meetingAutoDetectKey = "app.trace.meeting.autoDetectEnabled"
    static let meetingAutoStartKey = "app.trace.meeting.autoStartOnDetect"
    static let meetingMutedAppsKey = "app.trace.meeting.mutedApps"
    static let meetingCustomAppsKey = "app.trace.meeting.customApps"
    static let meetingSilenceThresholdKey = "app.trace.meeting.silenceThresholdSeconds"
    static let meetingAutoStopSilenceKey = "app.trace.meeting.autoStopSilenceSeconds"
    static let meetingPromptTimeoutKey = "app.trace.meeting.promptTimeoutSeconds"
    static let meetingSummaryInstructionsKey = "app.trace.meeting.summaryInstructions"
    static let coachEnabledKey = "app.trace.coach.enabled"
    static let coachConfigKey = "app.trace.coach.config"
    static let meetingLiveSummaryEnabledKey = "app.trace.meeting.liveSummaryEnabled"
    static let meetingLiveSummaryCadenceKey = "app.trace.meeting.liveSummaryCadenceSeconds"
    static let meetingDiarizationEnabledKey = "app.trace.meeting.diarizationEnabled"
    static let diarizationModelsPreparedOnceKey = "app.trace.meeting.diarizationModelsPreparedOnce"
    static let meetingLiveDiarizationEnabledKey = "app.trace.meeting.liveDiarizationEnabled"
    static let meetingOfflineDiarizationRefinementEnabledKey = "app.trace.meeting.offlineDiarizationRefinementEnabled"
    static let meetingSpeakerMemoryEnabledKey = "app.trace.meeting.speakerMemoryEnabled"
    static let meetingKeepCallRecordingEnabledKey = "app.trace.meeting.keepCallRecordingEnabled"
    static let meetingASRKey = "app.trace.meeting.asrEngine"
    public static let hotkeysChangedNotification = Notification.Name("app.trace.hotkeysChanged")

    public static func persistedOnboardingComplete() -> Bool {
        UserDefaults.standard.bool(forKey: onboardingKey)
    }

    static func clearPersistedOnboardingCompleteForTesting() {
        UserDefaults.standard.removeObject(forKey: onboardingKey)
    }
}

@Observable
@MainActor
public final class ActiveCaptureModel {

    public enum CaptureMode: String, Sendable, Hashable, Codable {
        case idle
        case dictation
        case meeting
        case voiceMemo
    }

    public var mode: CaptureMode
    public var sessionId: String?
    public var startedAt: Date?
    public var pendingPartialTranscript: String
    public var liveSpeakers: [String]

    public init() {
        self.mode = .idle
        self.sessionId = nil
        self.startedAt = nil
        self.pendingPartialTranscript = ""
        self.liveSpeakers = []
    }

    public func beginDictation(sessionId: String) {
        mode = .dictation
        self.sessionId = sessionId
        self.startedAt = Date()
        self.pendingPartialTranscript = ""
    }

    public func beginVoiceMemo(sessionId: String) {
        mode = .voiceMemo
        self.sessionId = sessionId
        self.startedAt = Date()
        self.pendingPartialTranscript = ""
    }

    public func beginMeeting(sessionId: String) {
        mode = .meeting
        self.sessionId = sessionId
        self.startedAt = Date()
    }

    public func end() {
        mode = .idle
        sessionId = nil
        startedAt = nil
        pendingPartialTranscript = ""
        liveSpeakers = []
    }
}
