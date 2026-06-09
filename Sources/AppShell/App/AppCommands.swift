import AppKit
import Foundation

@MainActor
public final class AppCommands: ObservableObject {
    public var startDictation: @MainActor () -> Void
    public var stopDictation: @MainActor () -> Void
    public var startVoiceMemo: @MainActor () -> Void
    public var stopVoiceMemo: @MainActor () -> Void
    public var startMeeting: @MainActor () -> Void
    public var stopMeeting: @MainActor () -> Void
    public var transcribeFile: @MainActor () -> Void
    public var openLibrary: @MainActor () -> Void
    public var openSettings: @MainActor () -> Void
    public var quit: @MainActor () -> Void

    public init(
        startDictation: @escaping @MainActor () -> Void = AppCommands.defaultStartDictation,
        stopDictation: @escaping @MainActor () -> Void = AppCommands.defaultStopDictation,
        startVoiceMemo: @escaping @MainActor () -> Void = AppCommands.defaultStartVoiceMemo,
        stopVoiceMemo: @escaping @MainActor () -> Void = AppCommands.defaultStopVoiceMemo,
        startMeeting: @escaping @MainActor () -> Void = AppCommands.defaultStartMeeting,
        stopMeeting: @escaping @MainActor () -> Void = AppCommands.defaultStopMeeting,
        transcribeFile: @escaping @MainActor () -> Void = AppCommands.defaultTranscribeFile,
        openLibrary: @escaping @MainActor () -> Void = AppCommands.defaultOpenLibrary,
        openSettings: @escaping @MainActor () -> Void = AppCommands.defaultOpenSettings,
        quit: @escaping @MainActor () -> Void = AppCommands.defaultQuit
    ) {
        self.startDictation = startDictation
        self.stopDictation = stopDictation
        self.startVoiceMemo = startVoiceMemo
        self.stopVoiceMemo = stopVoiceMemo
        self.startMeeting = startMeeting
        self.stopMeeting = stopMeeting
        self.transcribeFile = transcribeFile
        self.openLibrary = openLibrary
        self.openSettings = openSettings
        self.quit = quit
    }

    public static func defaultStartDictation() {
        NotificationCenter.default.post(name: .traceStartDictation, object: nil)
    }

    public static func defaultStopDictation() {
        NotificationCenter.default.post(name: .traceStopDictation, object: nil)
    }

    public static func defaultStartVoiceMemo() {
        NotificationCenter.default.post(name: .traceStartVoiceMemo, object: nil)
    }

    public static func defaultStopVoiceMemo() {
        NotificationCenter.default.post(name: .traceStopVoiceMemo, object: nil)
    }

    public static func defaultStartMeeting() {
        NotificationCenter.default.post(name: .traceStartMeeting, object: nil)
    }

    public static func defaultStopMeeting() {
        NotificationCenter.default.post(name: .traceStopMeeting, object: nil)
    }

    public static func defaultTranscribeFile() {
        NotificationCenter.default.post(name: .traceRequestTranscribeFile, object: nil)
    }

    public static func defaultOpenLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    public static func defaultOpenSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    public static func defaultQuit() {
        NSApp.terminate(nil)
    }
}

/// Typed payload for `.traceOpenMeeting` — travels as the notification
/// `object` (replaces the former stringly-typed `userInfo` dictionary).
///
/// A
/// Library citation / keyword hit posts one to open a meeting, optionally
/// seeking the transcript to a timestamp.
public struct OpenMeetingRequest: Sendable, Hashable {
    public let meetingId: String
    /// Transcript seek offset in seconds, when the source was timestamp-anchored.
    public let timestamp: Double?

    public init(meetingId: String, timestamp: Double? = nil) {
        self.meetingId = meetingId
        self.timestamp = timestamp
    }

    /// The single decode seam: pull a request out of a `.traceOpenMeeting`
    /// notification's `object`, or nil if it isn't one.
    public static func from(_ notification: Notification) -> OpenMeetingRequest? {
        notification.object as? OpenMeetingRequest
    }
}

extension Notification.Name {
    public static let traceStartDictation = Notification.Name("app.trace.startDictation")
    public static let traceStopDictation = Notification.Name("app.trace.stopDictation")
    public static let traceStartVoiceMemo = Notification.Name("app.trace.startVoiceMemo")
    public static let traceStopVoiceMemo = Notification.Name("app.trace.stopVoiceMemo")
    public static let traceStartMeeting = Notification.Name("app.trace.startMeeting")
    public static let traceStopMeeting = Notification.Name("app.trace.stopMeeting")
    public static let traceCoachManualTrigger = Notification.Name("app.trace.coachManualTrigger")
    /// Posted by the overlay "Ask:" bar. `object` carries a `CoachIntent` for a
    /// directed (Answer / Reframe / Sound smart / Fact check) on-demand request.
    public static let traceCoachAsk = Notification.Name("app.trace.coachAsk")
    /// Posted to surface the Library search pane (⌘K) and focus its field.
    public static let traceOpenSearch = Notification.Name("app.trace.openSearch")
    /// Posted to open the in-window Settings takeover at a specific tab. The
    /// target tab travels via `AppStateModel.pendingSettingsTab` (not the
    /// notification payload) so a Settings view that mounts *after* the post —
    /// the takeover flips selection first — still finds it waiting. Used by
    /// notice-banner recovery buttons ("Open Settings → AI models").
    public static let traceOpenSettingsTab = Notification.Name("app.trace.openSettingsTab")
    /// Posted to open a meeting in the content pane, optionally seeking to a
    /// timestamp.
    ///
    /// The payload is an `OpenMeetingRequest` passed as the `object`.
    public static let traceOpenMeeting = Notification.Name("app.trace.openMeeting")
    /// Posted to navigate to a non-meeting Library item (dictation / file / voice
    /// memo) from a keyword hit.
    ///
    /// Payload is an `OpenLibraryItemRequest` `object`.
    public static let traceOpenLibraryItem = Notification.Name("app.trace.openLibraryItem")
    /// Posted when the Library Q&A model/provider changes so the router re-routes
    /// the `.libraryQA` task class live.
    public static let traceLibraryQAConfigChanged = Notification.Name("app.trace.libraryQAConfigChanged")
    /// Posted when the conversation-state stage's model/provider changes so the
    /// router re-routes the `.conversationStateExtractor` task class live.
    public static let traceConversationStateConfigChanged = Notification.Name(
        "app.trace.conversationStateConfigChanged")
    /// Posted when the embedding provider/model changes (BAS-17) so the coordinator
    /// re-routes `.embeddingsIndex`/`.embeddingsLive` and rebuilds the cached RAG
    /// components (vector search, Q&A pipeline, meeting indexer) against the new
    /// fingerprint.
    public static let traceEmbeddingConfigChanged = Notification.Name("app.trace.embeddingConfigChanged")
    /// Posted when a model provider is connected/disconnected — a key saved or a
    /// ChatGPT sign-in/out (BAS-60) — so the per-stage routing pickers refresh
    /// which connected providers they offer.
    public static let traceProvidersChanged = Notification.Name("app.trace.providersChanged")
    /// Posted when the cache budget changes (BAS-44) so the coordinator prunes the
    /// retained audio recordings to the new soft cap.
    public static let traceCacheBudgetChanged = Notification.Name("app.trace.cacheBudgetChanged")
    /// Posted by Settings → Updates "Check for Updates" (BAS-24); the AppDelegate
    /// (which owns the Sparkle updater) runs the check.
    public static let traceCheckForUpdates = Notification.Name("app.trace.checkForUpdates")
    /// Posted when the auto-update preference changes (BAS-24) so the AppDelegate
    /// applies it to the Sparkle updater.
    public static let traceUpdaterPrefsChanged = Notification.Name("app.trace.updaterPrefsChanged")
    /// Posted when Coach settings (master toggle or behavior config) change so a
    /// running orchestrator adopts the new config mid-meeting and the triple-tap
    /// monitor is rebuilt from the new manual-trigger config.
    public static let traceCoachConfigChanged = Notification.Name("app.trace.coachConfigChanged")
    /// Posted by the coach overlay's "Hide" button — the controller orders the panel out.
    public static let traceCoachOverlayHide = Notification.Name("app.trace.coachOverlayHide")
    public static let traceRequestTranscribeFile = Notification.Name("app.trace.requestTranscribeFile")
    public static let traceTranscribeFiles = Notification.Name("app.trace.transcribeFiles")
    /// Posted when the user changes the ASR engine or cleanup provider in
    /// Settings.
    ///
    /// AppRuntimeCoordinator listens and invalidates its cached
    /// LiveDictationRuntime so the next capture picks up the new selection.
    public static let traceDictationPrefsChanged = Notification.Name("app.trace.dictationPrefsChanged")
    /// Posted when the user toggles opt-in meeting auto-detection in Settings.
    ///
    /// AppRuntimeCoordinator listens and (re-)arms or disarms its
    /// `AppActivityMonitor` accordingly.
    public static let traceMeetingAutoDetectChanged = Notification.Name("app.trace.meetingAutoDetectChanged")
    /// Posted when the user changes live-summary configuration (enabled/cadence)
    /// in Settings.
    ///
    /// AppRuntimeCoordinator listens and invalidates its cached
    /// MeetingRuntime so the next meeting rebuilds with the new settings; an
    /// in-progress meeting is left untouched.
    public static let traceMeetingConfigChanged = Notification.Name("app.trace.meetingConfigChanged")
    /// Posted by Settings → Meetings "Forget remembered speakers".
    ///
    /// The coordinator
    /// wipes the on-device cross-meeting speaker-memory DB and refreshes the count.
    public static let traceClearSpeakerMemory = Notification.Name("app.trace.clearSpeakerMemory")
    /// Posted by the notch meeting-detected prompt's "Later" button.
    ///
    /// The
    /// coordinator dismisses the prompt and backs off auto-detect briefly.
    public static let traceMeetingPromptDismiss = Notification.Name("app.trace.meetingPromptDismiss")
    /// Posted by the notch "Call ended?" prompt's "Keep recording" / ✕ button —
    /// the coordinator restores the recording HUD and keeps the meeting going.
    public static let traceMeetingEndPromptKeep = Notification.Name("app.trace.meetingEndPromptKeep")
    /// Posted when the user adds/removes a watched folder or toggles iPhone
    /// Voice-Memo iCloud sync in Settings.
    ///
    /// AppRuntimeCoordinator listens and
    /// (re-)starts the `WatchedFolderSession`s to match (BAS-22).
    public static let traceWatchedFoldersChanged = Notification.Name("app.trace.watchedFoldersChanged")
    /// Posted when a project's per-project overrides (model/ASR routes, coach
    /// config, vocabulary, calendar matchers) change.
    ///
    /// AppRuntimeCoordinator
    /// listens and re-hydrates the routers' per-project overrides (BAS-23).
    public static let traceProjectOverridesChanged = Notification.Name("app.trace.projectOverridesChanged")

}
