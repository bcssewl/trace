import Foundation
import Observation
import SharedCore

@Observable
@MainActor
public final class OnboardingStateModel {
    public struct ProjectPreset: Sendable, Hashable, Identifiable {
        public let id: String
        public let displayName: String
        public let projectName: String
        public let description: String
        public let metadata: String
        public let templateName: String
        public let color: String
    }

    // Retained for the existing unit tests (the First Project step was removed
    // from the flow, but `OnboardingStateModelTests` still exercises preset
    // selection + commit). Kept verbatim so those tests compile + pass.
    public static let projectPresets: [ProjectPreset] = [
        ProjectPreset(
            id: "work-startup",
            displayName: "Work · Startup",
            projectName: "Work",
            description: "Sales calls, customer interviews, 1:1s, board meetings, vendor calls.",
            metadata: "Sales calls · 1:1s · customer interviews · coach on",
            templateName: "Sales Call",
            color: "#ff3300"
        ),
        ProjectPreset(
            id: "classes-lectures",
            displayName: "Classes · Lectures",
            projectName: "Classes",
            description: "Recorded lectures, language classes, study sessions.",
            metadata: "Lectures · study notes · coach with general knowledge",
            templateName: "Lecture Notes",
            color: "#bdbdbd"
        ),
        ProjectPreset(
            id: "personal",
            displayName: "Personal",
            projectName: "Personal",
            description: "Voice memos, thoughts, casual conversations.",
            metadata: "Voice memos · journal · coach off",
            templateName: "Voice Memo",
            color: "#7a7a7a"
        ),
    ]

    /// The redesigned 7-step flow (replaces the old 8-step flow).
    ///
    /// Mirrors the
    /// approved prototype exactly: Welcome → Permissions → Speech → AI → Shortcuts
    /// → Try it → Done.
    public enum Step: Int, Sendable, Hashable, CaseIterable, Identifiable {
        case welcome = 1
        case permissions
        case speech
        case ai
        case shortcuts
        case tryIt
        case done

        public var id: Int { rawValue }

        public var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Permissions"
            case .speech: return "Speech → text"
            case .ai: return "AI for your text"
            case .shortcuts: return "Shortcuts"
            case .tryIt: return "Try it"
            case .done: return "Done"
            }
        }

        public var estimate: String {
            switch self {
            case .welcome: return "~10s"
            case .permissions: return "~30s"
            case .speech: return "~1 min"
            case .ai: return "~20s"
            case .shortcuts: return "~15s"
            case .tryIt: return "~20s"
            case .done: return "~5s"
            }
        }
    }

    /// The speech engine the user picks on the "Speech → text" step.
    ///
    /// Mirrors the
    /// two onboarding choices; binds to `appState.dictationASREngine` /
    /// `meetingASREngine`.
    public enum SpeechEngine: Sendable, Hashable {
        case parakeet
        case appleSpeech
    }

    public var currentStep: Step = .welcome
    public var permissionState: [PermissionRequester.Kind: PermissionStatus] = [:]
    public var appleFm: AppleFmProbeResult?
    public var ollama: OllamaProbeResult?

    // MARK: Retained project state (tests only — no longer in the flow)
    public var projectName: String = ""
    public var projectColor: String = "#ff3300"
    public var projectTemplateName: String = "Sales Call"
    public var selectedPresetID: String?
    public var firstProjectCommitted: Bool = false
    public var firstProjectCommitInFlight: Bool = false
    public var projectCreationError: String?

    /// The long-lived speech-model download (owned by `AppEnvironment`).
    ///
    /// The
    /// wizard drives it but no longer *owns* it, so an approved download keeps
    /// running after the user leaves onboarding.
    public let asrInstall: AsrModelInstallCoordinator

    /// Selected speech engine (Step 3).
    ///
    /// Default Parakeet.
    public var speechEngine: SpeechEngine = .parakeet

    /// Selected AI mode (Step 4).
    ///
    /// Off by default — no LLM calls until the user
    /// opts in.
    public var aiMode: AppStateModel.AIMode = .off
    /// The cloud provider tab selected on the AI step (when `.cloud`).
    public var cloudProvider: ModelProvider = .openRouter

    private let gate: PermissionGate
    private let requester: PermissionRequester
    private let ollamaProbe: OllamaProbe
    public let projectStore: ProjectStore?

    public init(
        gate: PermissionGate = PermissionGate(),
        requester: PermissionRequester = PermissionRequester(),
        ollamaProbe: OllamaProbe = OllamaProbe(),
        projectStore: ProjectStore? = nil,
        asrInstall: AsrModelInstallCoordinator = AsrModelInstallCoordinator()
    ) {
        self.gate = gate
        self.requester = requester
        self.ollamaProbe = ollamaProbe
        self.projectStore = projectStore
        self.asrInstall = asrInstall
        if let preset = Self.projectPresets.first {
            self.selectedPresetID = preset.id
            self.projectName = preset.projectName
            self.projectColor = preset.color
            self.projectTemplateName = preset.templateName
        }
        for kind in PermissionRequester.Kind.allCases {
            self.permissionState[kind] = .notDetermined
        }
    }

    public var totalSteps: Int { Step.allCases.count }

    public var progressFraction: Double {
        // Goal-gradient: show a little progress even on step 1 (matches prototype).
        let frac = Double(currentStep.rawValue) / Double(totalSteps)
        return 0.08 + frac * 0.92
    }

    public var selectedPreset: ProjectPreset? {
        Self.projectPresets.first { $0.id == selectedPresetID }
    }

    public var resolvedProjectName: String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let selectedPreset { return selectedPreset.projectName }
        return "Inbox"
    }

    public func go(_ next: Step) {
        currentStep = next
    }

    public func goNext() {
        let all = Step.allCases
        guard let idx = all.firstIndex(of: currentStep), idx + 1 < all.count else { return }
        currentStep = all[idx + 1]
    }

    public func goPrevious() {
        let all = Step.allCases
        guard let idx = all.firstIndex(of: currentStep), idx > 0 else { return }
        currentStep = all[idx - 1]
    }

    public func refreshPermissions() async {
        let snap = await gate.snapshot(promptForAccessibility: false)
        permissionState[.microphone] = snap.microphone
        permissionState[.systemAudio] = snap.systemAudio
        permissionState[.accessibility] = snap.accessibility
        permissionState[.speechRecognition] = snap.speechRecognition
        permissionState[.calendar] = snap.calendar
        permissionState[.notifications] = snap.notifications
        permissionState[.browserAwareness] = snap.browserAwareness
    }

    public func requestPermission(_ kind: PermissionRequester.Kind) async {
        let result = await requester.request(kind)
        permissionState[kind] = result
    }

    public func openPermissionSettings(_ kind: PermissionRequester.Kind) {
        requester.openSystemSettings(for: kind)
    }

    public func probeModels() async {
        appleFm = AppleFmProbe.probe()
        ollama = await ollamaProbe.probe()
    }

    // MARK: Project helpers (tests only)

    public func selectProjectPreset(_ preset: ProjectPreset) {
        let previousPresetName = selectedPreset?.projectName
        selectedPresetID = preset.id
        if projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projectName == previousPresetName {
            projectName = preset.projectName
        }
        projectColor = preset.color
        projectTemplateName = preset.templateName
        projectCreationError = nil
    }

    public func commitAndAdvance() {
        // See [[project-task-executor-bug]]: every state mutation + UI
        // advancement happens synchronously here; only fire-and-forget background
        // work goes in Task.detached.
        firstProjectCommitted = true
        projectCreationError = nil
        goNext()

        let store = projectStore
        let name = resolvedProjectName
        let color = projectColor
        Task.detached {
            guard let store else { return }
            do {
                let existing = try await store.list()
                if !existing.contains(where: { $0.name == name }) {
                    _ = try await store.create(name: name, indicatorColor: color)
                }
            } catch {
                Loggers.bootstrap.error("Project create failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @discardableResult
    public func commitFirstProject() async -> Bool {
        if firstProjectCommitted { return true }
        let name = resolvedProjectName
        guard let store = projectStore else {
            projectCreationError = "Project storage is not ready yet."
            return false
        }
        do {
            let existing = try await store.list()
            if existing.contains(where: { $0.name == name }) {
                firstProjectCommitted = true
                projectCreationError = nil
                return true
            }
            _ = try await store.create(name: name, indicatorColor: projectColor)
            firstProjectCommitted = true
            projectCreationError = nil
            return true
        } catch {
            projectCreationError = error.localizedDescription
            return false
        }
    }
}
