import CoachModule
import SharedCore
import SwiftUI

/// Per-project settings editor (BAS-23).
///
/// Presented as a sheet from the sidebar
/// or the LLM Router "Per-project overrides" list. Everyday fields (name, color,
/// coach) are up front; the per-task model/ASR route tables, vocabulary, and
/// calendar matchers live under a collapsed "Advanced" disclosure. Saving writes
/// the whole record via `ProjectStore.update` and posts
/// `.traceProjectOverridesChanged` so the coordinator re-hydrates the routers.
@MainActor
public struct ProjectSettingsView: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID
    let store: ProjectStore?
    /// Called after a successful save so the sidebar can refresh names/colors.
    var onSaved: () -> Void

    @State private var loaded = false
    @State private var name = ""
    @State private var color = "#ff3300"
    @State private var defaultTemplateId: UUID?
    @State private var coach = CoachConfig()
    @State private var modelChoices: [LLMTaskClass: ProjectLLMProvider] = [:]
    @State private var modelModels: [LLMTaskClass: String] = [:]
    @State private var asrChoices: [ASRTaskClass: ProjectASREngine] = [:]
    @State private var vocabulary: [String] = []
    @State private var newTerm = ""
    @State private var matchers: [CalendarMatcher] = []
    @State private var newMatcherText = ""
    @State private var newMatcherKind: MatcherKind = .titleRegex
    @State private var showAdvanced = false
    @State private var saveError: String?

    public init(projectID: UUID, store: ProjectStore?, onSaved: @escaping () -> Void) {
        self.projectID = projectID
        self.store = store
        self.onSaved = onSaved
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameAndColor
                    coachSection
                    advancedDisclosure
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 620)
        .background(palette.background.color)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(loaded ? "Project · \(name)" : "Project settings")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
            Spacer()
            BrutalistButton("Cancel", kind: .ghost) { dismiss() }
            BrutalistButton("Save", kind: .primary) { Task { await save() } }
        }
        .padding(16)
        .background(palette.bgTertiary.color)
    }

    // MARK: Everyday

    private var nameAndColor: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Name")
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
            if let saveError {
                Text(saveError).font(BrutalistTypography.caption).foregroundStyle(palette.primary.color)
            }
            sectionTitle("Colour")
            ColorSwatchRow(selection: $color)
        }
    }

    private var coachSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("In-meeting Coach")
            Toggle("Enable Coach for this project's meetings", isOn: $coach.enabled)
            Text("Overrides the global Coach default for meetings filed into this project.")
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
            if coach.enabled {
                Toggle("Grounded cue cards (from playbooks)", isOn: $coach.modes.grounded)
                Toggle("Synthesized suggestions", isOn: $coach.modes.synthesized)
                Toggle("General knowledge", isOn: $coach.modes.general)
            }
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advancedDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                Text("Advanced — per-task models, custom words & calendar rules")
                    .font(BrutalistTypography.labelEmphasis)
                Spacer()
            }
            .foregroundStyle(palette.fg.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showAdvanced {
            modelRoutingSection
            asrRoutingSection
            vocabularySection
            calendarMatchersSection
        }
    }

    private var modelRoutingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Which model handles each task")
            Text("“Inherit” keeps your global choice. Pick a provider to override it for this project.")
                .font(BrutalistTypography.caption).foregroundStyle(palette.fgMuted.color)
            ForEach(LLMTaskClass.allCases, id: \.self) { task in
                HStack(spacing: 10) {
                    Text(Self.label(task)).font(BrutalistTypography.label).frame(width: 200, alignment: .leading)
                    Picker("", selection: bindingModel(task)) {
                        ForEach(ProjectLLMProvider.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                    if (modelChoices[task] ?? .inherit) != .inherit {
                        TextField("model", text: bindingModelName(task))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var asrRoutingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Which speech model handles each task")
            ForEach(ASRTaskClass.allCases, id: \.self) { task in
                HStack(spacing: 10) {
                    Text(Self.label(task)).font(BrutalistTypography.label).frame(width: 200, alignment: .leading)
                    Picker("", selection: bindingASR(task)) {
                        ForEach(ProjectASREngine.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                    Spacer()
                }
            }
        }
    }

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Custom words")
            Text("Names & jargon specific to this project (applied to transcription & notes).")
                .font(BrutalistTypography.caption).foregroundStyle(palette.fgMuted.color)
            ForEach(vocabulary, id: \.self) { term in
                HStack {
                    Text(term).font(BrutalistTypography.body).foregroundStyle(palette.fg.color)
                    Spacer()
                    Button {
                        vocabulary.removeAll { $0 == term }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(palette.fgMuted.color)
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                TextField("Add a term…", text: $newTerm).textFieldStyle(.roundedBorder)
                    .onSubmit { addTerm() }
                BrutalistButton("Add", kind: .ghost) { addTerm() }
            }
        }
    }

    private var calendarMatchersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Calendar rules")
            Text("Rules that automatically file meetings into this project.")
                .font(BrutalistTypography.caption).foregroundStyle(palette.fgMuted.color)
            ForEach(Array(matchers.enumerated()), id: \.offset) { idx, matcher in
                HStack {
                    Text(Self.describe(matcher)).font(BrutalistTypography.body).foregroundStyle(palette.fg.color)
                    Spacer()
                    Button {
                        matchers.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(palette.fgMuted.color)
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $newMatcherKind) {
                    ForEach(MatcherKind.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 150)
                if newMatcherKind != .recurringSeries {
                    TextField(newMatcherKind == .titleRegex ? "weekly sync" : "domain", text: $newMatcherText)
                        .textFieldStyle(.roundedBorder)
                }
                BrutalistButton("Add", kind: .ghost) { addMatcher() }
            }
            if newMatcherKind == .titleRegex {
                Text("Matches when this text appears in the meeting title.")
                    .font(BrutalistTypography.caption).foregroundStyle(palette.fgMuted.color)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(BrutalistTypography.captionEmphasis)
            .foregroundStyle(palette.fgMuted.color)
    }

    // MARK: Bindings

    private func bindingModel(_ task: LLMTaskClass) -> Binding<ProjectLLMProvider> {
        Binding(get: { modelChoices[task] ?? .inherit }, set: { modelChoices[task] = $0 })
    }
    private func bindingModelName(_ task: LLMTaskClass) -> Binding<String> {
        Binding(get: { modelModels[task] ?? "" }, set: { modelModels[task] = $0 })
    }
    private func bindingASR(_ task: ASRTaskClass) -> Binding<ProjectASREngine> {
        Binding(get: { asrChoices[task] ?? .inherit }, set: { asrChoices[task] = $0 })
    }

    private func addTerm() {
        let t = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !vocabulary.contains(t) else { return }
        vocabulary.append(t)
        newTerm = ""
    }

    private func addMatcher() {
        let text = newMatcherText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch newMatcherKind {
        case .titleRegex where !text.isEmpty: matchers.append(.titleRegex(text))
        case .attendeeDomain where !text.isEmpty: matchers.append(.attendeeDomain(text))
        case .recurringSeries: if !matchers.contains(.recurringSeries) { matchers.append(.recurringSeries) }
        default: return
        }
        newMatcherText = ""
    }

    // MARK: Load / Save

    private func load() async {
        guard !loaded, let store, let record = try? await store.fetch(id: projectID) else {
            loaded = true
            return
        }
        name = record.name
        color = record.indicatorColor
        defaultTemplateId = record.defaultTemplateId
        if let decoded = CoachConfig.fromProjectJSON(record.coachConfigJson) {
            coach = decoded
        }
        let overrides = record.overrides
        for (task, route) in overrides.modelRouteOverrides {
            modelChoices[task] = ProjectLLMProvider(route.provider)
            modelModels[task] = route.model
        }
        for (task, route) in overrides.asrRouteOverrides {
            asrChoices[task] = ProjectASREngine(route.engineIdentifier)
        }
        vocabulary = overrides.vocabulary
        matchers = overrides.calendarMatchers
        loaded = true
    }

    private func save() async {
        guard let store else {
            dismiss()
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveError = "Give the project a name."
            return
        }

        var overrides = ProjectOverrides()
        for task in LLMTaskClass.allCases {
            guard let choice = modelChoices[task], choice != .inherit else { continue }
            overrides.modelRouteOverrides[task] = choice.route(model: modelModels[task] ?? "")
        }
        for task in ASRTaskClass.allCases {
            guard let choice = asrChoices[task], choice != .inherit, let route = choice.route() else { continue }
            overrides.asrRouteOverrides[task] = route
        }
        overrides.vocabulary = vocabulary
        overrides.calendarMatchers = matchers

        let coachJSON = coach.projectJSON()
        do {
            try await store.update(
                id: projectID, name: trimmed, indicatorColor: color,
                defaultTemplateId: defaultTemplateId, coachConfigJson: coachJSON, overrides: overrides
            )
            NotificationCenter.default.post(name: .traceProjectOverridesChanged, object: nil)
            onSaved()
            dismiss()
        } catch {
            saveError = ProjectsViewModel.friendlyError(error, name: trimmed)
        }
    }

    // MARK: Display helpers

    enum MatcherKind: String, CaseIterable, Identifiable, Hashable {
        case titleRegex, attendeeDomain, recurringSeries
        var id: String { rawValue }
        var label: String {
            switch self {
            case .titleRegex: return "Title pattern"
            case .attendeeDomain: return "Attendee domain"
            case .recurringSeries: return "Recurring series"
            }
        }
    }

    private static func describe(_ m: CalendarMatcher) -> String {
        switch m {
        case .titleRegex(let p): return "Title matches \"\(p)\""
        case .attendeeDomain(let d): return "Attendee @\(d)"
        case .recurringSeries: return "Recurring series"
        }
    }

    private static func label(_ task: LLMTaskClass) -> String {
        switch task {
        case .dictationCleanup: return "Dictation cleanup"
        case .titleGeneration: return "Title generation"
        case .projectCategorization: return "Project sorting"
        case .meetingSummary: return "Meeting summary"
        case .meetingAugmentedMerge: return "Augmented notes merge"
        case .coachSmartRouting: return "Coach routing"
        case .coachCardContent: return "Coach card content"
        case .libraryQA: return "Library Q&A"
        case .conversationStateExtractor: return "Conversation state"
        }
    }

    private static func label(_ task: ASRTaskClass) -> String {
        switch task {
        case .liveDictation: return "Live dictation"
        case .meetingCaptureLive: return "Meeting capture"
        case .fileBatchEnglish: return "File (English)"
        case .fileBatchMulti: return "File (multilingual)"
        case .fileBatchCJK: return "File (CJK)"
        case .voiceMemo: return "Voice memo"
        case .sensitiveLocalOnly: return "Sensitive (local-only)"
        case .qualityBatch: return "Quality batch"
        case .mandarinHighQuality: return "Mandarin (high quality)"
        }
    }
}

/// A row of selectable color swatches, shared by the create sheet and the
/// project settings editor. `selection` is the chosen hex string.
@MainActor
struct ColorSwatchRow: View {
    @Environment(\.brutalistPalette) private var palette
    @Binding var selection: String

    static let swatches = ["#ff3300", "#ff9500", "#ffcc00", "#34c759", "#007aff", "#5856d6", "#bdbdbd", "#7a7a7a"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.swatches, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(palette.fg.color, lineWidth: selection == hex ? 2 : 0))
                    .contentShape(Circle())
                    .onTapGesture { selection = hex }
            }
        }
    }
}

/// Lightweight "create project" sheet — name + color swatch.
///
/// Shown from the
/// sidebar `+`. `onCreate` returns whether the create succeeded (so the sheet
/// stays open to show a duplicate-name error).
@MainActor
struct NewProjectSheet: View {
    @Environment(\.brutalistPalette) private var palette
    @Binding var name: String
    @Binding var color: String
    let error: String?
    let onCreate: (String, String) async -> Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New project")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { _ = await onCreate(name, color) } }
            ColorSwatchRow(selection: $color)
            if let error {
                Text(error).font(BrutalistTypography.caption).foregroundStyle(palette.primary.color)
            }
            HStack {
                Spacer()
                BrutalistButton("Cancel", kind: .ghost) { onCancel() }
                BrutalistButton("Create", kind: .primary) { Task { _ = await onCreate(name, color) } }
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(palette.background.color)
    }
}

/// Per-project LLM provider choice; `inherit` means no override.
enum ProjectLLMProvider: String, CaseIterable, Identifiable, Hashable {
    case inherit, appleFM, ollama, openRouter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inherit: return "Inherit"
        case .appleFM: return "Apple FM"
        case .ollama: return "Ollama"
        case .openRouter: return "OpenRouter"
        }
    }
    init(_ kind: LLMProviderKind) {
        switch kind {
        case .appleFM: self = .appleFM
        case .ollama: self = .ollama
        // All cloud / OpenAI-compatible providers (incl. BAS-37's Anthropic +
        // Codex-subscription) collapse to the single per-project "OpenRouter" choice.
        case .openAICompat, .anthropicMessages, .codexSubscription: self = .openRouter
        }
    }
    /// The `LLMRoute` for this choice + model — delegates to the `ModelProvider`
    /// catalog's single `route(model:)` builder, so per-project routes match the
    /// global ones (`AppRuntimeCoordinator.providerRoute`) by construction.
    func route(model: String) -> LLMRoute {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .inherit, .appleFM: return ModelProvider.appleFM.route(model: m)
        case .ollama: return ModelProvider.ollama.route(model: m)
        case .openRouter: return ModelProvider.openRouter.route(model: m)
        }
    }
}

/// Per-project ASR engine choice; `inherit` means no override.
enum ProjectASREngine: String, CaseIterable, Identifiable, Hashable {
    case inherit, parakeet, whisperkit, qwen3, appleSpeech
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inherit: return "Inherit"
        case .parakeet: return "Parakeet (local)"
        case .whisperkit: return "WhisperKit (local)"
        case .qwen3: return "Qwen3 (local — Chinese, Japanese, Korean)"
        case .appleSpeech: return "Apple Speech"
        }
    }
    init(_ engineIdentifier: String) {
        switch engineIdentifier {
        case "parakeet": self = .parakeet
        case "whisperkit": self = .whisperkit
        case "qwen3": self = .qwen3
        case "apple-speech": self = .appleSpeech
        default: self = .inherit
        }
    }
    func route() -> ASRRoute? {
        switch self {
        case .inherit: return nil
        case .parakeet: return ASRRoute(engineIdentifier: "parakeet", modelIdentifier: "tdt-v3", allowsCloud: false)
        case .whisperkit:
            return ASRRoute(engineIdentifier: "whisperkit", modelIdentifier: "large-v3-turbo", allowsCloud: false)
        case .qwen3:
            return ASRRoute(engineIdentifier: "qwen3", modelIdentifier: "qwen3-asr-0.6b-int8", allowsCloud: false)
        case .appleSpeech:
            return ASRRoute(engineIdentifier: "apple-speech", modelIdentifier: "on-device", allowsCloud: false)
        }
    }
}

extension CoachConfig {
    /// Decode a project's stored `coach_config` JSON. `"{}"` (the column
    /// default) → nil meaning "no per-project override".
    ///
    /// Single decode site
    /// shared by the settings editor and the runtime coordinator — `CoachConfig`
    /// lives in CoachModule, so this can't be a computed property on the
    /// SharedCore `ProjectRecord`.
    static func fromProjectJSON(_ json: String) -> CoachConfig? {
        guard json != "{}", let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(CoachConfig.self, from: data)
        else { return nil }
        return decoded
    }

    /// Encode for storage in `projects.coach_config` (`"{}"` on failure).
    func projectJSON() -> String {
        guard let data = try? JSONEncoder().encode(self),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
