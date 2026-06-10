import Foundation
import SharedCore

/// One generalized descriptor for every "pick a provider + model for this LLM
/// stage" setting (BAS-49).
///
/// Replaces the six hand-rolled triads (dictation
/// cleanup, meeting notes, meeting title, auto-categorization, library Q&A,
/// conversation state), each of which used to repeat the same shape across
/// `AppStateModel`, `AppRuntimeCoordinator`, and the settings views.
///
/// Each case carries, as data, everything those triads differed by: the exact
/// persisted UserDefaults keys, the all-local default provider, the
/// `.deterministic`-coercion rule, the providers the everyday picker offers, the
/// config-changed notification the coordinator listens for, the `ModelRouter`
/// task class(es) the stage drives, and the per-stage default-model logic.
/// Adding a new routed stage is now one case here plus one `StageModelGroup`
/// call — no new property/observer/route copies.
public enum LLMRouteStage: String, Sendable, Hashable, CaseIterable, Identifiable {
    case dictationCleanup
    case meetingNotes
    case meetingTitle
    case meetingCategorization
    case libraryQA
    case conversationState
    /// RETIRED: the old coach gatekeeper pipeline's classify/route stage. The
    /// listener redesign collapsed the coach onto `.coachCardContent` alone.
    /// The case survives only for persistence compatibility — its UserDefaults
    /// keys may exist on disk and `LLMTaskClass.coachSmartRouting` may appear
    /// in stored per-project override JSON. It is excluded from
    /// `userConfigurable`, so no picker offers it and no preset touches it.
    case coachSmartRouting
    case coachCardContent

    public var id: String { rawValue }

    /// The stages users can actually route — everything except the retired
    /// `.coachSmartRouting`. Settings tables, presets, and active-preset
    /// detection all iterate this, never `allCases`.
    public static let userConfigurable: [LLMRouteStage] = allCases.filter { $0 != .coachSmartRouting }

    /// Human-readable stage name for the Advanced per-task routing table.
    public var displayName: String {
        switch self {
        case .dictationCleanup: return "Tidying up dictation"
        case .meetingNotes: return "Meeting notes & summaries"
        case .meetingTitle: return "Naming meetings"
        case .meetingCategorization: return "Filing meetings into projects"
        case .libraryQA: return "Answering questions about your library"
        case .conversationState: return "Following the conversation"
        case .coachSmartRouting: return "Deciding what the coach shows (retired)"
        case .coachCardContent: return "Meeting coach"
        }
    }

    /// The `ModelRouter` task class(es) this stage routes. `meetingNotes` drives
    /// both the rolling summary and the final augmented merge, so they always
    /// point at the same provider for a coherent notes pipeline.
    public var taskClasses: [LLMTaskClass] {
        switch self {
        case .dictationCleanup: return [.dictationCleanup]
        case .meetingNotes: return [.meetingSummary, .meetingAugmentedMerge]
        case .meetingTitle: return [.titleGeneration]
        case .meetingCategorization: return [.projectCategorization]
        case .libraryQA: return [.libraryQA]
        case .conversationState: return [.conversationStateExtractor]
        case .coachSmartRouting: return [.coachSmartRouting]
        case .coachCardContent: return [.coachCardContent]
        }
    }

    /// UserDefaults key for the persisted provider.
    ///
    /// These are the *exact* legacy
    /// keys; they must not change or a user's saved preference resets on upgrade.
    public var providerKey: String {
        switch self {
        case .dictationCleanup: return "app.trace.dictation.cleanupProvider"
        case .meetingNotes: return "app.trace.meeting.notesProvider"
        case .meetingTitle: return "app.trace.meeting.titleProvider"
        case .meetingCategorization: return "app.trace.meeting.categorizationProvider"
        case .libraryQA: return "app.trace.library.qaProvider"
        case .conversationState: return "app.trace.coach.conversationStateProvider"
        case .coachSmartRouting: return "app.trace.coach.smartRoutingProvider"
        case .coachCardContent: return "app.trace.coach.cardContentProvider"
        }
    }

    /// UserDefaults key for the persisted per-provider model overrides (the
    /// `[provider.rawValue: model]` dict).
    ///
    /// Exact legacy keys — see `providerKey`.
    public var modelsKey: String {
        switch self {
        case .dictationCleanup: return "app.trace.dictation.cleanupModels"
        case .meetingNotes: return "app.trace.meeting.notesModels"
        case .meetingTitle: return "app.trace.meeting.titleModels"
        case .meetingCategorization: return "app.trace.meeting.categorizationModels"
        case .libraryQA: return "app.trace.library.qaModels"
        case .conversationState: return "app.trace.coach.conversationStateModels"
        case .coachSmartRouting: return "app.trace.coach.smartRoutingModels"
        case .coachCardContent: return "app.trace.coach.cardContentModels"
        }
    }

    /// Provider when nothing is persisted yet.
    ///
    /// Dictation cleanup starts at
    /// the deterministic fixer; library Q&A at local Ollama; the meeting coach
    /// at OpenRouter (the coach is cloud-only by design — it refuses to run on
    /// a local model); everything else at on-device Apple FM.
    public var defaultProvider: DictationCleanupProvider {
        switch self {
        case .dictationCleanup: return .deterministic
        case .libraryQA: return .ollama
        case .coachCardContent: return .openRouter
        default: return .appleFM
        }
    }

    /// A persisted `.deterministic` is only meaningful for dictation cleanup
    /// (the no-LLM fixer).
    ///
    /// Other stages have no deterministic generator, so a
    /// restored `.deterministic` coerces to this fallback. `nil` = keep it.
    public var deterministicCoercion: DictationCleanupProvider? {
        // Cleanup is the only stage that may legitimately keep `.deterministic`;
        // every other stage coerces a restored `.deterministic` to its own
        // (non-deterministic) default provider.
        defaultProvider == .deterministic ? nil : defaultProvider
    }

    /// The always-on providers a stage's picker offers regardless of credentials:
    /// the on-device / local options only.
    ///
    /// Cleanup adds the deterministic no-LLM
    /// fixer; library Q&A is generative-only (Ollama); the rest are Apple FM /
    /// Ollama. Cloud providers (OpenRouter + connect cards) are added by
    /// `everydayProviders` only once their key/credential is present.
    public var offeredProviders: [DictationCleanupProvider] {
        switch self {
        case .dictationCleanup: return [.deterministic, .appleFM, .ollama]
        case .libraryQA: return [.ollama]
        // Cloud-only: the coach offers NO local providers — its picker shows
        // only the connected cloud set from `everydayProviders`.
        case .coachCardContent: return []
        default: return [.appleFM, .ollama]
        }
    }

    /// The everyday picker's full provider list given which keyed cloud providers
    /// are currently connected: the always-on local `offeredProviders` plus each
    /// *connected* cloud provider (OpenRouter / Anthropic / ChatGPT / MiniMax),
    /// projected back to `DictationCleanupProvider`.
    ///
    /// A provider whose key/credential
    /// is absent is never offered, so it can't be picked (BAS-60). Pass
    /// `ModelProvider.routingConnectedSet()` for `connected`. A distinct name from
    /// the `offeredProviders` property (Swift disallows a property + method sharing
    /// a base name).
    public func everydayProviders(connected: Set<ModelProvider>) -> [DictationCleanupProvider] {
        offeredProviders
            + ModelProvider.keyedCloudProviders
            .filter { connected.contains($0) }
            .compactMap { DictationCleanupProvider(rawValue: $0.rawValue) }
    }

    /// The notification the coordinator observes to re-apply this stage's route
    /// when the user changes it.
    public var configChangedNotification: Notification.Name {
        switch self {
        case .dictationCleanup: return .traceDictationPrefsChanged
        case .meetingNotes, .meetingTitle, .meetingCategorization: return .traceMeetingConfigChanged
        case .libraryQA: return .traceLibraryQAConfigChanged
        case .conversationState: return .traceConversationStateConfigChanged
        case .coachSmartRouting, .coachCardContent: return .traceCoachConfigChanged
        }
    }

    /// Whether `setModel` also clears an override equal to the base default
    /// model.
    ///
    /// Cleanup-family stages do (legacy `setCleanupModel`); library-Q&A /
    /// conversation-state only clear on blank (legacy `setLibraryQAModel`).
    public var clearsModelMatchingBaseDefault: Bool {
        switch self {
        case .libraryQA, .conversationState: return false
        default: return true
        }
    }

    /// The default model for `provider` when the user has set no override.
    /// `notesOllamaModel` supplies the notes Ollama model that library-Q&A and
    /// conversation-state default to (so setting the notes Ollama model once
    /// flows through), matching the legacy getters exactly.
    public func defaultModel(
        for provider: DictationCleanupProvider,
        notesOllamaModel: () -> String
    ) -> String {
        switch (self, provider) {
        case (.libraryQA, .ollama), (.conversationState, .ollama):
            return notesOllamaModel()
        case (.libraryQA, .openRouter):
            return "google/gemini-3.1-flash-lite"
        case (.conversationState, .openRouter):
            return "anthropic/claude-3.5-haiku"
        default:
            return AppStateModel.defaultCleanupModel(for: provider)
        }
    }
}
