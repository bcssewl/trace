import CoachModule
import Combine
import SharedCore
import SwiftUI

@MainActor
public struct AppearanceSettingsView: View {
    /// Live binding to the global appearance preference.
    ///
    /// Settings windows
    /// receive the same AppStateModel reference, so writing here flips the
    /// whole app's color scheme via `.preferredColorScheme(...)` on AppRootView.
    @Bindable var state: AppStateModel
    @State private var density: String = "Comfortable"

    public init(state: AppStateModel = AppStateModel()) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Appearance") {
                SettingsRow(
                    key: "Theme",
                    hint: "Pick System to match your Mac’s light or dark setting, or lock Trace to one look."
                ) {
                    Picker("", selection: $state.appearancePreference) {
                        ForEach(AppearancePreference.allCases) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
            SettingsGroup("Density") {
                SettingsRow(
                    key: "Row spacing",
                    hint: "Comfortable gives everything room to breathe. Compact fits a little more on screen."
                ) {
                    Picker("", selection: $density) {
                        Text("Comfortable").tag("Comfortable")
                        Text("Compact").tag("Compact")
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
        }
    }
}

@MainActor
public struct LibraryStorageSettingsView: View {
    var state: AppStateModel?
    @State private var sqlitePath = "~/Library/Application Support/Trace/index.sqlite"
    @State private var audioArchivePath = "~/Library/Application Support/Trace/audio-archive"
    /// Live slider value; committed to `state.cacheBudgetGb` only on release so a
    /// drag doesn't fire a notification/prune per tick (BAS-44).
    @State private var draftBudget: Double = 10

    public init(state: AppStateModel? = nil) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Where things are saved") {
                SettingsRow(
                    key: "Library", hint: "Your projects, meetings, dictations, and notes — all stored on this Mac."
                ) {
                    pathLabel(sqlitePath)
                }
                SettingsRow(
                    key: "Recordings",
                    hint:
                        "Saved meeting and call recordings. The oldest are removed first when you hit the limit below.",
                    showDivider: false
                ) {
                    pathLabel(audioArchivePath)
                }
            }
            SettingsGroup("Storage limit", tag: "\(Int(draftBudget)) GB") {
                SettingsRow(
                    key: "Keep recordings up to",
                    hint:
                        "How much space saved recordings can use. When you go over, Trace removes the oldest ones to make room.",
                    showDivider: state?.lastCachePruneSummary != nil
                ) {
                    HStack {
                        Slider(
                            value: $draftBudget, in: 1...100,
                            onEditingChanged: { editing in
                                if !editing { state?.cacheBudgetGb = draftBudget }
                            }
                        )
                        .frame(width: 200)
                        Text("\(Int(draftBudget)) GB")
                            .font(BrutalistTypography.mono11)
                            .foregroundStyle(.primary)
                    }
                }
                if let summary = state?.lastCachePruneSummary {
                    SettingsRow(key: "Last cleanup", hint: summary, showDivider: false) { EmptyView() }
                }
            }
        }
        .task {
            draftBudget = state?.cacheBudgetGb ?? 10
            sqlitePath = (try? DatabasePaths().indexDatabaseURL().path) ?? sqlitePath
            audioArchivePath = (try? DatabasePaths().audioArchiveDirectory().path) ?? audioArchivePath
        }
    }

    private func pathLabel(_ path: String) -> some View {
        Text(path)
            .font(BrutalistTypography.mono11)
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .frame(width: 320, alignment: .trailing)
    }
}

@MainActor
public struct UpdatesSettingsView: View {
    var state: AppStateModel?

    public init(state: AppStateModel? = nil) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Updates") {
                SettingsRow(
                    key: "Install updates automatically",
                    hint:
                        "Trace checks for new versions each day, downloads them in the background, and asks before installing."
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { state?.autoUpdatesEnabled ?? true },
                            set: { state?.autoUpdatesEnabled = $0 }
                        )
                    ).labelsHidden()
                }
                SettingsRow(
                    key: "Update type",
                    hint:
                        "Stable gives you polished releases. Beta gets you early features sooner, with the odd rough edge."
                ) {
                    Picker(
                        "",
                        selection: Binding(
                            get: { state?.updateChannel ?? "Stable" },
                            set: { state?.updateChannel = $0 }
                        )
                    ) {
                        Text("Stable").tag("Stable")
                        Text("Beta").tag("Beta")
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                SettingsRow(key: "Check for updates", hint: "Look for a new version right now.", showDivider: false) {
                    BrutalistButton("Check now", kind: .primary) {
                        NotificationCenter.default.post(name: .traceCheckForUpdates, object: nil)
                    }
                }
            }
        }
    }
}

/// A small eye-icon button that reveals a plain-language explanation popover, so a
/// setting can be demystified on demand without a wall of hint text on the row.
private struct ExplainEye: View {
    @Environment(\.brutalistPalette) private var palette
    let title: String
    let message: String
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "eye")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.fgMuted.color)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("What is this?")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(BrutalistTypography.labelEmphasis)
                    .foregroundStyle(palette.fg.color)
                Text(message)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}

@MainActor
public struct LLMRouterSettingsView: View {
    @Environment(\.brutalistPalette) private var palette
    var state: AppStateModel?
    @State private var availability: DictationAvailability = .unknown
    @State private var showAdvanced: Bool = false
    @State private var ollamaModels: [String] = []
    /// Which connect-card providers (Anthropic / ChatGPT / MiniMax) have a
    /// credential right now — gates whether they appear in the stage pickers
    /// (BAS-60).
    ///
    /// Refreshed on appear + on `traceProvidersChanged`.
    @State private var connectedProviders: Set<ModelProvider> = []
    @State private var embeddingKeyDraft: String = ""
    @State private var embeddingKeyStatus: String = ""
    private let keychain = KeychainSecrets()
    /// Real projects for the "Per-project overrides" list (BAS-23).
    @State private var projectRecords: [ProjectRecord] = []
    @State private var editingProject: ProjectRecord?

    public init(state: AppStateModel? = nil) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let state {
                SettingsGroup("Tidy up dictation", tag: support.groupTag(for: state.dictationCleanupProvider)) {
                    providerSelectList(
                        stage: .dictationCleanup,
                        current: state.dictationCleanupProvider,
                        state: state
                    ) { state.dictationCleanupProvider = $0 }
                    StageModelRow(
                        state: state,
                        stage: .dictationCleanup,
                        installedOllamaModels: ollamaModels,
                        label: "Model",
                        openRouterPlaceholder: "google/gemini-3.1-flash-lite",
                        openRouterHint:
                            "The OpenRouter model name — for example anthropic/claude-sonnet-4.6, openai/gpt-4o-mini, or google/gemini-2.0-flash."
                    )
                }
                libraryQAGroup(state: state)
            }

            // Provider setup — connect the AI services the app can use.
            // Consolidated here from the old separate Apple FM / Ollama /
            // OpenAI tabs. A simple user just adds a key here; the advanced
            // routing table below is collapsed by default.
            AppleFMSettingsView()
            OllamaSettingsView()
            // Every BYOK key (OpenRouter / OpenAI direct / Anthropic / MiniMax)
            // + ChatGPT OAuth sign-in — one unified set of provider cards.
            ProvidersSettingsView()

            // Advanced: per-task routing. Collapsed so casual users aren't
            // confronted with the full 9-task table.
            advancedDisclosure
        }
        .task {
            connectedProviders = ModelProvider.routingConnectedSet()
            availability = await DictationAvailabilityProbe().probe()
            ollamaModels = await OllamaModels.installed()
            // If the configured Ollama cleanup model isn't installed, default to
            // the first installed one so cleanup doesn't fail on a missing model.
            if let state, state.dictationCleanupProvider == .ollama, !ollamaModels.isEmpty,
                !ollamaModels.contains(state.cleanupModel(for: .ollama))
            {
                state.setCleanupModel(ollamaModels[0], for: .ollama)
            }
            await loadProjects()
        }
        .onReceive(NotificationCenter.default.publisher(for: .traceProvidersChanged)) { _ in
            connectedProviders = ModelProvider.routingConnectedSet()
        }
        .sheet(item: $editingProject) { record in
            ProjectSettingsView(projectID: record.id, store: BootContext.current?.projectStore) {
                Task { await loadProjects() }
            }
        }
    }

    private func loadProjects() async {
        guard let store = BootContext.current?.projectStore else { return }
        projectRecords = (try? await store.list()) ?? []
    }

    /// A one-line summary of a project's overrides for the row hint.
    private static func overridesSummary(_ record: ProjectRecord) -> String {
        let o = record.overrides
        var parts: [String] = []
        if !o.modelRouteOverrides.isEmpty { parts.append("\(o.modelRouteOverrides.count) model") }
        if !o.asrRouteOverrides.isEmpty { parts.append("\(o.asrRouteOverrides.count) speech") }
        if !o.vocabulary.isEmpty { parts.append("\(o.vocabulary.count) vocab") }
        if !o.calendarMatchers.isEmpty { parts.append("\(o.calendarMatchers.count) calendar") }
        if record.coachConfigJson != "{}" { parts.append("coach customized") }
        return parts.isEmpty ? "Using your global settings — no custom settings yet" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var advancedDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.fgMuted.color)
                Text("Advanced — send each task to a specific model")
                    .font(BrutalistTypography.labelEmphasis)
                    .foregroundStyle(palette.fg.color)
                Spacer()
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showAdvanced, let state {
            SettingsGroup("Quick setup") {
                SettingsRow(
                    key: "Choose a starting point",
                    hint: state.activeRoutePreset?.detail
                        ?? "Custom — you’ve picked your own model for one or more tasks below.",
                    showDivider: false
                ) {
                    HStack(spacing: 8) {
                        ForEach(LLMRoutePreset.allCases) { preset in
                            presetPill(preset.displayName, active: state.activeRoutePreset == preset) {
                                withAnimation(.easeInOut(duration: 0.15)) { state.applyRoutePreset(preset) }
                            }
                        }
                        // "Custom" reflects the no-preset-match state; not applicable.
                        presetPill("Custom", active: state.activeRoutePreset == nil, action: nil)
                    }
                }
            }
            SettingsGroup("Model for each task", tag: "\(LLMRouteStage.userConfigurable.count) tasks") {
                let stages = LLMRouteStage.userConfigurable
                ForEach(Array(stages.enumerated()), id: \.element) { idx, stage in
                    perTaskRoutingRows(state: state, stage: stage, isLast: idx == stages.count - 1)
                }
            }
            SettingsGroup("Per-project settings") {
                if projectRecords.isEmpty {
                    SettingsRow(
                        key: "No projects yet",
                        hint:
                            "Add a project from the sidebar (the + button) to give it its own models, speech, vocabulary, and coach settings.",
                        showDivider: false
                    ) { EmptyView() }
                } else {
                    ForEach(Array(projectRecords.enumerated()), id: \.element.id) { idx, record in
                        SettingsRow(
                            key: record.name,
                            hint: Self.overridesSummary(record),
                            showDivider: idx < projectRecords.count - 1
                        ) {
                            BrutalistButton("Edit", kind: .ghost) { editingProject = record }
                        }
                    }
                }
            }
        }
    }

    /// The shared provider-picker helper, seeded with this view's live snapshot.
    private var support: ProviderPickerSupport {
        ProviderPickerSupport(availability: availability, connectedProviders: connectedProviders)
    }

    /// A provider SELECTION list (the `BrutalistSelectRow` idiom, with brand
    /// logos) for `stage`.
    ///
    /// Renders one dotted row per offered provider, each
    /// showing the live "local / cloud · state" detail — so the saved selection
    /// always paints with its real label (fixing the transient Apple-FM flash the
    /// native `Picker` had while the availability probe was still in flight).
    @ViewBuilder
    private func providerSelectList(
        stage: LLMRouteStage,
        current: DictationCleanupProvider,
        state: AppStateModel,
        onSelect: @escaping (DictationCleanupProvider) -> Void
    ) -> some View {
        let offered = support.offered(for: stage, current: current)
        ForEach(offered) { provider in
            BrutalistSelectRow(
                title: provider.displayName,
                detail: support.detail(for: provider),
                selected: current == provider,
                showDivider: true,
                logo: provider.brandLogo
            ) {
                onSelect(provider)
            }
        }
    }

    // MARK: Library Q&A (cross-meeting) routing

    @ViewBuilder
    private func libraryQAGroup(state: AppStateModel) -> some View {
        SettingsGroup("Ask your library", tag: support.groupTag(for: state.libraryQAProvider)) {
            providerSelectList(
                stage: .libraryQA,
                current: state.libraryQAProvider,
                state: state
            ) { state.libraryQAProvider = $0 }
            StageModelRow(
                state: state,
                stage: .libraryQA,
                installedOllamaModels: ollamaModels,
                label: "Model",
                openRouterPlaceholder: "google/gemini-3.1-flash-lite",
                openRouterHint: "The OpenRouter model name — for example anthropic/claude-sonnet-4.6 or openai/gpt-4o.",
                showDivider: true
            )
            embeddingRows(state: state)
            qaRelevanceFloorRow(state: state)
        }
    }

    /// BAS-30: dense-arm cosine relevance floor — a power-user threshold that drops
    /// weak semantic matches before they reach the LLM. 0 disables it; keyword
    /// (FTS) matches are never floored.
    @ViewBuilder
    private func qaRelevanceFloorRow(state: AppStateModel) -> some View {
        SettingsRow(
            key: "Ignore weak matches",
            hint:
                "Higher means only closely related notes are used to answer, so loosely related ones don’t muddy the response. Set it to 0 to use everything. Exact word matches are always kept.",
            showDivider: false
        ) {
            HStack {
                Slider(
                    value: Binding(
                        get: { state.qaRelevanceFloor },
                        set: { state.qaRelevanceFloor = $0 }
                    ), in: 0...0.9, step: 0.01
                )
                .frame(width: 180)
                Text(String(format: "%.2f", state.qaRelevanceFloor))
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.primary.color)
                    .frame(width: 44)
            }
        }
    }

    // MARK: Embedding provider/model (BAS-17)

    @ViewBuilder
    private func embeddingRows(state: AppStateModel) -> some View {
        // Plain caption intro (not a SettingsRow): a SettingsRow header here would
        // render an empty trailing-control gutter and its own divider, stacking a
        // second separator on top of the first list row's divider just below.
        VStack(alignment: .leading, spacing: 3) {
            Text("Search across meetings")
                .font(BrutalistTypography.label)
                .foregroundStyle(palette.fg.color)
            Text(
                "This is what lets Trace search by meaning across all your meetings and answer questions about your library, and it’s what the coach draws on. Ollama runs free and private on your Mac; a cloud option needs a key. If you switch models, your existing content is re-processed the next time it’s indexed."
            )
            .font(BrutalistTypography.caption)
            .foregroundStyle(palette.fgMuted.color)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.borderSoft.color)
                .frame(height: BrutalistMetrics.hairline)
                .padding(.leading, 14)
        }
        ForEach(offeredEmbeddingChoices(state: state)) { choice in
            BrutalistSelectRow(
                title: choice.displayName,
                detail: embeddingDetail(choice),
                selected: state.embeddingProvider == choice,
                showDivider: true,
                logo: choice.brandLogo
            ) {
                state.embeddingProvider = choice
            }
        }
        embeddingModelRow(state: state)
    }

    @ViewBuilder
    private func embeddingModelRow(state: AppStateModel) -> some View {
        let choice = state.embeddingProvider
        if choice == .ollama {
            OllamaModelPicker(
                installed: ollamaModels,
                key: "Search model",
                value: Binding(
                    get: { state.embeddingModel(for: .ollama) },
                    set: { state.setEmbeddingModel($0, for: .ollama) }
                )
            )
        } else {
            SettingsRow(
                key: "Search model",
                hint: choice.modelHint,
                showDivider: true
            ) {
                TextField(
                    choice.defaultModel,
                    text: Binding(
                        get: { state.embeddingModel(for: choice) },
                        set: { state.setEmbeddingModel($0, for: choice) }
                    )
                )
                .textFieldStyle(.plain)
                .font(BrutalistTypography.body)
                .frame(width: 320)
            }
            embeddingKeyRow(for: choice)
        }
    }

    @ViewBuilder
    private func embeddingKeyRow(for choice: EmbeddingProviderChoice) -> some View {
        switch choice {
        case .ollama:
            EmptyView()
        case .openAI:
            SettingsRow(
                key: "API key",
                hint: "This uses the OpenAI key you’ve already added below — no need to enter it again.",
                showDivider: false
            ) {
                EmptyView()
            }
        case .voyage:
            SettingsRow(
                key: "Voyage API key",
                hint: embeddingKeyStatus.isEmpty
                    ? "Kept private on this Mac. Trace also uses it to sharpen your library answers."
                    : embeddingKeyStatus,
                showDivider: false
            ) {
                HStack(spacing: 8) {
                    SecureField("pa-…", text: $embeddingKeyDraft)
                        .textFieldStyle(.plain)
                        .font(BrutalistTypography.body)
                        .frame(width: 200)
                    BrutalistButton("Save", kind: .primary) { saveEmbeddingKey(account: "voyage") }
                }
            }
        case .openRouter:
            SettingsRow(
                key: "API key",
                hint: "This uses the OpenRouter key you’ve already added below — no need to enter it again.",
                showDivider: false
            ) {
                EmptyView()
            }
        }
    }

    private func saveEmbeddingKey(account: String) {
        let trimmed = embeddingKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.save(account: account, value: trimmed)
            embeddingKeyStatus = "Saved ✓"
            embeddingKeyDraft = ""
        } catch {
            embeddingKeyStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Embedding providers offered in the picker: local Ollama always, plus each
    /// cloud provider only once its key is present (OpenAI → Keychain account
    /// "openai", Voyage → "voyage") — so you can't select a cloud embedder you have
    /// no key for.
    ///
    /// OpenRouter is not a choice: it exposes no embeddings API. The
    /// current selection is always kept so the picker never goes blank.
    private func offeredEmbeddingChoices(state: AppStateModel) -> [EmbeddingProviderChoice] {
        var list = EmbeddingProviderChoice.allCases.filter { choice in
            guard let account = choice.keychainAccount else { return true }  // local Ollama
            return keychain.hasValue(account: account)
        }
        let current = state.embeddingProvider
        if !list.contains(current) { list.append(current) }
        return list
    }

    /// Compact "local / cloud · state" detail for an embedding-choice list row.
    private func embeddingDetail(_ choice: EmbeddingProviderChoice) -> String {
        switch choice {
        case .ollama: return availability.ollamaReachable ? "On your Mac" : "On your Mac · not running"
        case .openAI, .voyage, .openRouter:
            let keyed = choice.keychainAccount.map { keychain.hasValue(account: $0) } ?? true
            return keyed ? "Cloud · connected" : "Cloud · needs a key"
        }
    }

    private func presetPill(_ name: String, active: Bool, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Text(name)
                .font(BrutalistTypography.caption)
                .foregroundStyle(active ? palette.primary.color : palette.fg.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? palette.primary.color.opacity(0.12) : palette.secondary.color)
                )
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    /// One stage's rows in the Advanced per-task routing table: a provider picker
    /// plus the shared model row.
    ///
    /// Bound to the generalized routing accessors, so
    /// each selection drives the real `ModelRouter` route for every `LLMTaskClass`
    /// the stage covers (BAS-6 / BAS-35).
    @ViewBuilder
    private func perTaskRoutingRows(state: AppStateModel, stage: LLMRouteStage, isLast: Bool) -> some View {
        // The stage name as a quiet header row, then one selectable list row per
        // offered provider (logos + live state), then the shared model row.
        SettingsRow(key: stage.displayName, showDivider: true) { EmptyView() }
        ForEach(support.offered(for: stage, current: state.provider(for: stage))) { provider in
            BrutalistSelectRow(
                title: provider.displayName,
                detail: support.detail(for: provider),
                selected: state.provider(for: stage) == provider,
                showDivider: true,
                logo: provider.brandLogo
            ) {
                state.setProvider(provider, for: stage)
            }
        }
        StageModelRow(
            state: state,
            stage: stage,
            installedOllamaModels: ollamaModels,
            label: "↳ Model",
            showDivider: !isLast
        )
    }
}

@MainActor
public struct CoachTriggersSettingsView: View {
    let appState: AppStateModel?

    public init(appState: AppStateModel? = nil) {
        self.appState = appState
    }

    public var body: some View {
        if let appState {
            CoachTriggersBody(state: appState)
        } else {
            // Coach settings bind to the live app model; nothing to show without it.
            Color.clear
        }
    }
}

/// Bound Coach Triggers controls.
///
/// Every control writes through to the persisted
/// `CoachConfig` (and the `coachEnabled` master), which posts
/// `traceCoachConfigChanged` so a running meeting's orchestrator and the
/// global triple-tap monitor adopt the change immediately.
@MainActor
private struct CoachTriggersBody: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable var state: AppStateModel

    /// Availability + connected-provider state powering the Coach model picker,
    /// mirroring the LLM Router view.
    ///
    /// Refreshed on appear + on `traceProvidersChanged`.
    @State private var availability: DictationAvailability = .unknown
    @State private var connectedProviders: Set<ModelProvider> = []
    @State private var ollamaModels: [String] = []
    @State private var showAdvanced = false

    /// Honest label for the rolling card allowance: names the actual window
    /// (default quarter-hour), and stays truthful if the window is changed
    /// under Advanced.
    private var cardsAllowanceKey: String {
        switch state.coachConfig.effectiveSurfaceWindowMinutes {
        case 15: return "Most cards per quarter-hour"
        case 1: return "Most cards per minute"
        case let minutes: return "Most cards per \(minutes) minutes"
        }
    }

    /// The window named in plain words for the hint text.
    private var cardsWindowPhrase: String {
        switch state.coachConfig.effectiveSurfaceWindowMinutes {
        case 15: return "quarter-hour"
        case 1: return "one-minute"
        case let minutes: return "\(minutes)-minute"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Meeting coach") {
                SettingsRow(
                    key: "Turn on the coach",
                    hint:
                        "Show helpful cards on screen while you’re in a meeting — answers to what’s being asked, things recalled from your notes, suggestions for what to say. While it’s on, the live meeting transcript is sent to the cloud model you choose below."
                ) {
                    Toggle("", isOn: $state.coachEnabled).labelsHidden()
                }
            }
            coachModelGroup
            SettingsGroup("How often it speaks up") {
                SettingsRow(
                    key: cardsAllowanceKey,
                    hint:
                        "The most cards the coach will show on its own in any \(cardsWindowPhrase) stretch. The allowance tops back up as the meeting moves on, so help is spread across a long meeting rather than spent in the opening minutes. Asking for one yourself (triple-tap or the Ask buttons) never counts toward this.",
                    showDivider: false
                ) {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(state.coachConfig.surfaceBudget) },
                                set: { state.coachConfig.surfaceBudget = Int($0) }
                            ), in: 1...10
                        )
                        .frame(width: 180)
                        Text("\(state.coachConfig.surfaceBudget)")
                            .font(BrutalistTypography.mono11)
                            .foregroundStyle(palette.primary.color)
                            .frame(width: 30)
                    }
                }
            }
            SettingsGroup("Ask the coach yourself") {
                SettingsRow(
                    key: "Tap a key to ask for a tip",
                    hint:
                        "Tap a modifier key three times to bring up a coach tip on the spot, even if it wouldn’t have shown one on its own."
                ) {
                    Toggle("", isOn: $state.coachConfig.manualTrigger.enabled).labelsHidden()
                }
                SettingsRow(key: "Key to tap", hint: "Which key Trace listens for.") {
                    Picker("", selection: $state.coachConfig.manualTrigger.modifierKeyCode) {
                        Text("Right Option").tag(61)
                        Text("Right Command").tag(54)
                        Text("Right Control").tag(62)
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsRow(key: "Number of taps", hint: "Three taps helps avoid setting it off by accident.") {
                    HStack(spacing: 8) {
                        ForEach([2, 3, 4], id: \.self) { n in
                            Text("\(n)")
                                .font(BrutalistTypography.mono11)
                                .foregroundStyle(
                                    state.coachConfig.manualTrigger.tapCount == n
                                        ? palette.primary.color : palette.fg.color
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .overlay(
                                    Rectangle().stroke(
                                        state.coachConfig.manualTrigger.tapCount == n
                                            ? palette.primary.color : palette.border.color,
                                        lineWidth: BrutalistMetrics.hairline
                                    )
                                )
                                .onTapGesture { state.coachConfig.manualTrigger.tapCount = n }
                        }
                    }
                }
                SettingsRow(
                    key: "Time allowed between taps",
                    hint: "How quickly the taps need to come to count as one gesture.", showDivider: false
                ) {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(state.coachConfig.manualTrigger.windowMilliseconds) },
                                set: { state.coachConfig.manualTrigger.windowMilliseconds = Int($0) }
                            ), in: 200...1000
                        )
                        .frame(width: 180)
                        Text("\(state.coachConfig.manualTrigger.windowMilliseconds) ms")
                            .font(BrutalistTypography.mono11)
                            .foregroundStyle(palette.primary.color)
                            .frame(width: 60)
                    }
                }
            }
            advancedDisclosure
            HStack {
                Spacer()
                BrutalistButton("Reset coach to defaults", kind: .ghost) {
                    state.coachEnabled = true
                    state.coachConfig = CoachConfig()
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
        }
        .task {
            connectedProviders = ModelProvider.routingConnectedSet()
            availability = await DictationAvailabilityProbe().probe()
            ollamaModels = await OllamaModels.installed()
        }
        .onReceive(NotificationCenter.default.publisher(for: .traceProvidersChanged)) { _ in
            connectedProviders = ModelProvider.routingConnectedSet()
        }
    }

    /// Collapsed power-user knobs, per the Advanced-section convention.
    @ViewBuilder
    private var advancedDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.fgMuted.color)
                Text("Advanced")
                    .font(BrutalistTypography.labelEmphasis)
                    .foregroundStyle(palette.fg.color)
                Spacer()
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showAdvanced {
            SettingsGroup("Checking pace") {
                SettingsRow(
                    key: "How often the coach checks in",
                    hint:
                        "The coach reviews the conversation at most this often when something new has been said (a question jumps the queue). More often means quicker help but more cloud calls — each check is one request to your chosen model."
                ) {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(state.coachConfig.checkCadenceSeconds) },
                                set: { state.coachConfig.checkCadenceSeconds = Int($0) }
                            ), in: 10...60, step: 5
                        )
                        .frame(width: 180)
                        Text("\(state.coachConfig.checkCadenceSeconds)s")
                            .font(BrutalistTypography.mono11)
                            .foregroundStyle(palette.primary.color)
                            .frame(width: 44)
                    }
                }
                SettingsRow(
                    key: "Card allowance window",
                    hint:
                        "How long each stretch lasts for the card allowance above. The coach shows at most that many cards on its own within any window of this length — a shorter window means the allowance tops up sooner.",
                    showDivider: false
                ) {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(state.coachConfig.surfaceWindowMinutes) },
                                set: { state.coachConfig.surfaceWindowMinutes = Int($0) }
                            ), in: 5...30, step: 5
                        )
                        .frame(width: 180)
                        Text("\(state.coachConfig.surfaceWindowMinutes) min")
                            .font(BrutalistTypography.mono11)
                            .foregroundStyle(palette.primary.color)
                            .frame(width: 44)
                    }
                }
            }
        }
    }

    /// "Coach AI model" — the single place to choose which cloud LLM powers the
    /// coach (`.coachCardContent`, the listener's only stage).
    ///
    /// CLOUD-ONLY:
    /// the list offers exclusively the connected cloud providers (OpenRouter /
    /// Anthropic / ChatGPT / MiniMax) — never Apple FM or Ollama. With nothing
    /// connected it states the gap plainly and points at Settings → AI models;
    /// the coach also refuses to start in that state (`CoachCloudGate`).
    @ViewBuilder
    private var coachModelGroup: some View {
        let support = ProviderPickerSupport(availability: availability, connectedProviders: connectedProviders)
        // `offeredProviders` is empty for the coach stage, so this is exactly
        // the connected cloud set — a cloud provider without a key is never
        // offered, and local providers never appear at all.
        let cloudChoices = LLMRouteStage.coachCardContent.everydayProviders(connected: connectedProviders)
        SettingsGroup("Which AI powers the coach", tag: support.groupTag(for: state.coachAIProvider)) {
            if cloudChoices.isEmpty {
                SettingsRow(
                    key: "No cloud model connected",
                    hint:
                        "The coach needs a cloud model — it doesn’t run on local ones. Connect OpenRouter, Anthropic, ChatGPT or MiniMax under AI models, then pick it here.",
                    showDivider: false
                ) {
                    BrutalistButton("Open AI models", kind: .ghost) {
                        state.pendingSettingsTab = .llmRouter
                        NotificationCenter.default.post(name: .traceOpenSettingsTab, object: nil)
                    }
                }
            } else {
                ForEach(cloudChoices) { provider in
                    BrutalistSelectRow(
                        title: provider.displayName,
                        detail: support.detail(for: provider),
                        selected: state.coachAIProvider == provider,
                        showDivider: true,
                        logo: provider.brandLogo
                    ) {
                        state.coachAIProvider = provider
                    }
                }
                StageModelRow(
                    state: state,
                    stage: .coachCardContent,
                    installedOllamaModels: ollamaModels,
                    label: "Model",
                    openRouterPlaceholder: "google/gemini-3.1-flash-lite",
                    openRouterHint:
                        "The OpenRouter model name — for example google/gemini-3.1-flash-lite, anthropic/claude-sonnet-4.6, or openai/gpt-4o-mini.",
                    showDivider: false
                )
            }
        }
    }
}

@MainActor
public struct HotkeysSettingsView: View {
    @Environment(\.brutalistPalette) private var palette
    var state: AppStateModel?

    /// The hotkey recorder currently armed, if any.
    ///
    /// Ensures only one row
    /// listens for keys at a time.
    @State private var activeRecorderID: String?

    /// Reference-only shortcuts that aren't (yet) user-rebindable.
    private let reference: [(String, String, [String])] = [
        ("Ask the coach for a tip", "Triple-tap Right Option during a meeting", ["⌥", "⌥", "⌥"]),
        ("Open Settings", "From anywhere", ["⌘", ","]),
    ]

    public init(state: AppStateModel? = nil) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let state {
                SettingsGroup("Shortcuts", tag: "Click a shortcut to change it") {
                    ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element.id) { idx, action in
                        editableRow(action, state: state, isLast: idx == HotkeyAction.allCases.count - 1)
                    }
                }
                HStack {
                    Spacer()
                    BrutalistButton("Reset to defaults", kind: .ghost) {
                        state.hotkeyBindings = [:]
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 2)
            }
            SettingsGroup("Other shortcuts") {
                ForEach(Array(reference.enumerated()), id: \.offset) { idx, row in
                    SettingsRow(key: row.0, hint: row.1, showDivider: idx != reference.count - 1) {
                        keycaps(row.2)
                    }
                }
            }
        }
    }

    private func editableRow(_ action: HotkeyAction, state: AppStateModel, isLast: Bool) -> some View {
        let descriptor = state.descriptor(for: action.rawValue, default: action.defaultDescriptor)
        // Dictation can also be bound to a lone right-side modifier (tap or hold),
        // so its recorder accepts a single right ⌘/⌥/⌃ in addition to combos.
        let allowsTap = action == .dictationToggle
        let hint = allowsTap ? "\(action.hint) · or hold a single right ⌘/⌥/⌃ to talk" : action.hint
        return SettingsRow(key: action.title, hint: hint, showDivider: !isLast) {
            HotkeyRecorder(
                id: action.rawValue,
                descriptor: descriptor,
                activeID: $activeRecorderID,
                allowsModifierTap: allowsTap
            ) { newDescriptor in
                state.hotkeyBindings[action.rawValue] = newDescriptor
            }
        }
    }

    private func keycaps(_ keys: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, token in
                Text(token)
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.fg.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.secondary.color)
                    )
            }
        }
    }
}

@MainActor
public struct ASREnginesSettingsView: View {
    @Environment(\.brutalistPalette) private var palette
    @State private var tab: String = "LOCAL"
    /// Per-model install status, keyed by `ASRModelCatalog` id.
    ///
    /// Probed on appear
    /// and refreshed after a download so each row shows the real READY / NOT
    /// DOWNLOADED state straight from the backend instead of a guess.
    @State private var modelStatus: [String: BackendStatus] = [:]
    /// The model currently downloading (its catalog id) + its progress fraction.
    ///
    /// Single-flight: the catalog downloads one model at a time.
    @State private var downloadingModelID: String?
    @State private var downloadFraction: Double = 0
    /// Draft API-key text per cloud ASR provider (keyed by `CloudASRProvider.rawValue`),
    /// and the set of providers that already have a key in the Keychain (BAS-21).
    @State private var cloudKeyDrafts: [String: String] = [:]
    @State private var cloudKeysPresent: Set<String> = []
    /// Per-provider Keychain failure message — a failed save/clear must never
    /// look like it worked.
    @State private var cloudKeyErrors: [String: String] = [:]
    var state: AppStateModel?

    public init(state: AppStateModel? = nil) {
        self.state = state
    }

    @ViewBuilder
    private func dictationLanguageGroup(_ state: AppStateModel) -> some View {
        SettingsGroup(
            "Language",
            tag: state.dictationTranscriptionLanguage == .auto
                ? "Detect automatically" : state.dictationTranscriptionLanguage.displayName
        ) {
            SettingsRow(
                key: "Dictation language",
                hint:
                    "Trace can detect the language on its own, or you can set one so dictation in another language comes out right.",
                showDivider: false
            ) {
                Picker(
                    "",
                    selection: Binding(
                        get: { state.dictationTranscriptionLanguage },
                        set: { state.dictationTranscriptionLanguage = $0 }
                    )
                ) {
                    ForEach(TranscriptionLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    @ViewBuilder
    private func liveTranscriptGroup(_ state: AppStateModel) -> some View {
        let engine = state.dictationASREngine
        let canStream = engine.supportsStreaming
        SettingsGroup("Live preview") {
            SettingsRow(
                key: "Show words as you speak",
                hint: canStream
                    ? "See your words appear in the notch while you talk, instead of all at once when you finish."
                    : "\(engine.displayName) writes everything out at the end, so there’s no live preview. Switch to Apple Speech to turn this on.",
                showDivider: false
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { canStream && state.dictationShowLivePartials },
                        set: { state.dictationShowLivePartials = $0 }
                    )
                )
                .labelsHidden()
                .disabled(!canStream)
            }
        }
    }

    @ViewBuilder
    private func returnToSendGroup(_ state: AppStateModel) -> some View {
        SettingsGroup("Finishing") {
            SettingsRow(
                key: "Press Return to send",
                hint:
                    "While you’re dictating, tap Return to finish and send in one go — Trace drops your words into the app, then presses Return to submit (handy for chat boxes). Your dictation shortcut still stops without sending, and Shift+Return is left alone for a new line.",
                showDivider: false
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { state.dictationEnterSends },
                        set: { state.dictationEnterSends = $0 }
                    )
                )
                .labelsHidden()
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let state {
                liveTranscriptGroup(state)
                returnToSendGroup(state)
                dictationLanguageGroup(state)
            }
            tabBar
            if tab == "LOCAL" {
                SettingsGroup("Models on this Mac", tag: "Tap to choose · download to use") {
                    ForEach(ASRModelCatalog.all) { entry in
                        engineRow(entry)
                    }
                }
            } else {
                cloudKeyConfigGroup
            }
            // Folded in from the former standalone Dictionary tab — the store
            // exists but no editor/learning loop writes it yet (honest empty
            // state, build-out tracked in the backlog).
            SettingsGroup("Personal vocabulary", tag: "Coming soon") {
                SettingsRow(
                    key: "Words you correct",
                    hint:
                        "One day, the fixes you make after dictating will be remembered here so the same words come out right next time. This isn’t available yet.",
                    showDivider: false
                ) {
                    Text("Empty")
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                }
            }
        }
        .task { await probeModelStatuses() }
    }

    /// Probe each catalog model's on-disk install state so the rows show real
    /// READY / NOT DOWNLOADED badges.
    ///
    /// Updates incrementally on the main actor so
    /// rows light up as each backend resolves. Streaming-only models (no batch
    /// backend) are skipped — their row shows "Coming soon".
    private func probeModelStatuses() async {
        for entry in ASRModelCatalog.all {
            guard let backend = entry.makeBackend() else { continue }
            modelStatus[entry.id] = await backend.checkStatus()
        }
    }

    private func engineRow(_ entry: ASRModelEntry) -> some View {
        let status = modelStatus[entry.id]
        let isReady = status == .ready || status == .loaded
        let isActive = state?.dictationLocalModelID == entry.id
        let isDownloading = downloadingModelID == entry.id
        let logo = BrandLogo.allCases.first { $0.slug == entry.brand } ?? .openAI
        return HStack(alignment: .center, spacing: 14) {
            // Logo only — selection is shown by the orange border, not a radio dot.
            BrandLogoView(logo, size: 34)
                .frame(width: 40)
            // Name + blurb
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(palette.fg.color)
                    badgePill(
                        badgeText(for: entry, isActive: isActive, isReady: isReady, status: status),
                        primary: isActive)
                }
                Text(entry.blurb)
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.fgMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Ratings + size column
            VStack(alignment: .trailing, spacing: 4) {
                metricLabel("Accuracy", value: entry.accuracy)
                metricLabel("Speed", value: entry.speed)
                Text(entry.approxSizeMB > 0 ? "\(entry.approxSizeMB) MB · \(entry.languages)" : entry.languages)
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fgMuted.color)
            }
            .frame(width: 220, alignment: .trailing)
            // Action column
            VStack(alignment: .trailing, spacing: 6) {
                actionControl(
                    for: entry, status: status, isReady: isReady, isActive: isActive, isDownloading: isDownloading)
            }
            .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(isActive ? palette.primary.color.opacity(0.06) : Color.clear)
        .overlay(
            // Selected model: orange edges (replaces the radio dot).
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.primary.color, lineWidth: 2)
                .opacity(isActive ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isReady && !entry.streamingOnly && !isActive { select(entry) }
        }
        .overlay(
            // Row divider — hidden on the selected row so it doesn't cross the border.
            Rectangle().fill(palette.borderSoft.color).frame(height: isActive ? 0 : 1),
            alignment: .bottom
        )
    }

    /// The status pill text for a catalog row.
    private func badgeText(for entry: ASRModelEntry, isActive: Bool, isReady: Bool, status: BackendStatus?) -> String {
        if isActive { return "In use" }
        if entry.streamingOnly { return "Coming soon" }
        if case .unavailable = status { return "Not available" }
        if isReady { return "Ready" }
        if status == nil { return "Checking…" }
        return "Not downloaded"
    }

    /// The right-hand action for a catalog row: select / download / progress, or
    /// an explanatory label for system + streaming-only models.
    @ViewBuilder
    private func actionControl(
        for entry: ASRModelEntry, status: BackendStatus?, isReady: Bool, isActive: Bool, isDownloading: Bool
    ) -> some View {
        if entry.streamingOnly {
            // No one-shot batch backend yet — surfaced but not selectable.
            Text("Coming soon")
                .font(BrutalistTypography.mono10)
                .foregroundStyle(palette.fgMuted.color)
        } else if case .unavailable = status {
            // System model the host can't run (e.g. Apple Speech below macOS 26).
            Text("Unavailable")
                .font(BrutalistTypography.mono10)
                .foregroundStyle(palette.fgMuted.color)
        } else if isReady {
            BrutalistButton(isActive ? "Selected" : "Use this", kind: isActive ? .ghost : .primary) {
                if !isActive { select(entry) }
            }
        } else if isDownloading {
            BrutalistButton("Downloading…", kind: .primary) {}
                .disabled(true)
            Text("\(Int(downloadFraction * 100))%")
                .font(BrutalistTypography.mono10)
                .foregroundStyle(palette.fgMuted.color)
        } else if entry.approxSizeMB > 0 {
            BrutalistButton("Download", kind: .primary) {
                Task { await download(entry) }
            }
            .disabled(downloadingModelID != nil)  // one download at a time
        } else {
            // System model still being probed.
            Text("Checking…")
                .font(BrutalistTypography.mono10)
                .foregroundStyle(palette.fgMuted.color)
        }
    }

    /// Select a ready catalog model for dictation: persist the specific model id
    /// and align the coarse engine so the runtime builds the exact backend.
    private func select(_ entry: ASRModelEntry) {
        guard let state else { return }
        // An explicit choice supersedes onboarding's deferred Parakeet take-over.
        state.parakeetTakeoverPending = false
        state.dictationLocalModelID = entry.id
        state.dictationASREngine = entry.engine.coarseDictationEngine
    }

    private func badgePill(_ text: String, primary: Bool) -> some View {
        Text(text)
            .font(BrutalistTypography.mono10)
            .foregroundStyle(primary ? palette.primary.color : palette.fgMuted.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                Rectangle().stroke(
                    primary ? palette.primary.color : palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline))
    }

    private func metricLabel(_ label: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(BrutalistTypography.mono10)
                .foregroundStyle(palette.fgMuted.color)
            Text(String(format: "%.1f", value))
                .font(BrutalistTypography.mono10)
                .foregroundStyle(palette.fg.color)
        }
    }

    /// Downloads a catalog model's on-device weights via its own backend's
    /// `prepare` — Parakeet through FluidAudio, Qwen3 through FluidAudio's Qwen3
    /// loader, Whisper variants through WhisperKit — streaming the real progress
    /// fraction into the row, then re-probing so the badge flips to READY.
    ///
    /// The
    /// backend builds the exact variant, so each Whisper size / Qwen3 precision
    /// downloads independently.
    private func download(_ entry: ASRModelEntry) async {
        guard let backend = entry.makeBackend() else { return }
        downloadingModelID = entry.id
        downloadFraction = 0
        // Bridge the backend's off-main progress callback to a stream consumed on
        // the main actor.
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        let task = Task {
            try? await backend.prepare(onStatus: { _ in }, onProgress: { continuation.yield($0) })
            continuation.finish()
        }
        for await f in stream { downloadFraction = f }
        _ = await task.value
        modelStatus[entry.id] = await backend.checkStatus()
        downloadingModelID = nil
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            tabPill("LOCAL")
            tabPill("API")
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
    }

    private func tabPill(_ name: String) -> some View {
        let label = name == "LOCAL" ? "On this Mac" : "Cloud"
        return Text(label)
            .font(BrutalistTypography.mono11)
            .foregroundStyle(tab == name ? palette.primary.color : palette.fg.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(tab == name ? palette.primary.color.opacity(0.08) : Color.clear)
            .overlay(
                Rectangle().stroke(
                    tab == name ? palette.primary.color : palette.border.color,
                    lineWidth: BrutalistMetrics.hairline
                )
            )
            .onTapGesture { tab = name }
    }

    // MARK: Cloud ASR providers (BAS-21) — real BYOK key config

    /// Real per-provider API-key configuration (replaces the old no-op mock).
    ///
    /// Keys are stored in the Keychain; a provider with a key can be made the
    /// active dictation engine right here.
    @ViewBuilder
    private var cloudKeyConfigGroup: some View {
        SettingsGroup("Cloud transcription services", tag: "Add your own key · kept private on this Mac") {
            ForEach(CloudASRProvider.allCases, id: \.self) { provider in
                cloudProviderRow(provider)
            }
        }
        .onAppear { cloudKeysPresent = CloudASRProvider.keyedProviders() }
    }

    private func cloudProviderRow(_ provider: CloudASRProvider) -> some View {
        let hasKey = cloudKeysPresent.contains(provider.rawValue)
        let isActive = state?.dictationASREngine == .cloud && state?.dictationCloudProvider == provider
        return HStack(alignment: .top, spacing: 12) {
            BrandLogoView(provider.brandLogo, size: 18)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.fg.color)
                    if isActive {
                        badgePill("In use", primary: true)
                    } else if hasKey {
                        badgePill("Key added", primary: false)
                    } else {
                        badgePill("No key yet", primary: false)
                    }
                    if provider.supportsStreaming { badgePill("Live", primary: false) }
                }
                SecureField(
                    "Paste your API key…",
                    text: Binding(
                        get: { cloudKeyDrafts[provider.rawValue] ?? "" },
                        set: { cloudKeyDrafts[provider.rawValue] = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(BrutalistTypography.mono10)
                .frame(maxWidth: 320)
                if let keyError = cloudKeyErrors[provider.rawValue] {
                    Text(keyError)
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.primary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                BrutalistButton("Save", kind: .primary) { saveCloudKey(provider) }
                if hasKey {
                    BrutalistButton("Clear", kind: .ghost) { clearCloudKey(provider) }
                    if !isActive {
                        BrutalistButton("Use for dictation", kind: .ghost) {
                            // Explicit choice supersedes the deferred take-over.
                            state?.parakeetTakeoverPending = false
                            state?.dictationCloudProvider = provider
                            state?.dictationASREngine = .cloud
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(
            Rectangle().fill(palette.borderSoft.color).frame(height: 1),
            alignment: .bottom
        )
    }

    private func saveCloudKey(_ provider: CloudASRProvider) {
        let draft = (cloudKeyDrafts[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        let account = CloudASRBackend.endpoints(for: provider).keychainAccount
        do {
            try KeychainSecrets().save(account: account, value: draft)
        } catch {
            // A swallowed failure here showed "Key added" for a key that was
            // never stored — transcription would then fail with no explanation.
            cloudKeyErrors[provider.rawValue] =
                "The key could not be saved to the Keychain (\(error.localizedDescription)). Try again."
            return
        }
        cloudKeyErrors[provider.rawValue] = nil
        cloudKeysPresent.insert(provider.rawValue)
        cloudKeyDrafts[provider.rawValue] = ""
        // Tell other open settings views (e.g. the Meetings cloud picker) to
        // re-probe, so a key added here shows up there without a relaunch.
        NotificationCenter.default.post(name: .traceProvidersChanged, object: nil)
    }

    private func clearCloudKey(_ provider: CloudASRProvider) {
        let account = CloudASRBackend.endpoints(for: provider).keychainAccount
        do {
            try KeychainSecrets().delete(account: account)
        } catch {
            cloudKeyErrors[provider.rawValue] =
                "The key could not be removed from the Keychain (\(error.localizedDescription)). Try again."
            return
        }
        cloudKeyErrors[provider.rawValue] = nil
        cloudKeysPresent.remove(provider.rawValue)
        // If this was the active dictation engine, fall back to the local default
        // so we never leave dictation pointed at a now-keyless cloud provider.
        if state?.dictationASREngine == .cloud, state?.dictationCloudProvider == provider {
            state?.dictationASREngine = .parakeet
        }
        NotificationCenter.default.post(name: .traceProvidersChanged, object: nil)
    }
}

@MainActor
public struct AppleFMSettingsView: View {
    @State private var probe: AppleFmProbeResult?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Apple Intelligence") {
                // Availability is checked automatically when this panel opens and
                // is effectively static at runtime (it only changes if you alter
                // the macOS version, toggle Apple Intelligence in System Settings,
                // or the model finishes downloading), so there's no manual probe
                // button — it would re-run the same instant check with no visible
                // effect. The value below reflects the on-appear probe.
                SettingsRow(
                    key: "On-device AI from Apple",
                    hint:
                        "Free, private AI built into macOS. Needs macOS 26 or later on an Apple silicon Mac, with Apple Intelligence turned on.",
                    value: probe?.available == true ? "Ready" : (probe?.reason ?? "Checking…"),
                    showDivider: false
                ) {
                    BrandLogoView(.apple, size: 16)
                }
            }
        }
        .task { probe = AppleFmProbe.probe() }
    }
}

@MainActor
public struct OllamaSettingsView: View {
    @State private var probe: OllamaProbeResult?
    @State private var host: String = "http://localhost:11434"
    /// Drives the Probe button's feedback: a spinner while the reachability check
    /// runs, then a brief "checked ✓" — so a click visibly does something even
    /// when Ollama's state (and therefore the result) hasn't changed.
    @State private var probing = false
    @State private var justChecked = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Ollama", tag: probe?.reachable == true ? "Connected" : "Not running") {
                SettingsRow(
                    key: "Address",
                    hint:
                        "Where Ollama is running. The default works for most setups — change it only if you run Ollama elsewhere."
                ) {
                    HStack(spacing: 8) {
                        BrandLogoView(.ollama, size: 16)
                        TextField("", text: $host)
                            .textFieldStyle(.plain)
                            .font(BrutalistTypography.mono11)
                            .frame(width: 280)
                        if probing {
                            ProgressView().controlSize(.small)
                        } else if justChecked {
                            Text("checked ✓")
                                .font(BrutalistTypography.mono10)
                                .foregroundStyle(.secondary)
                        }
                        BrutalistButton("Check connection", kind: .ghost) { runProbe() }
                            .disabled(probing)
                    }
                }
            }
            modelsGroup
            embeddingGroup
        }
        .task { runProbe() }
    }

    /// Re-check Ollama reachability + installed models, with visible feedback.
    ///
    /// Shared by the Host "Probe" button, the embedding "Re-probe" button, and the
    /// initial on-appear load so all three behave identically. Idempotent: a
    /// second click while a check is in flight is ignored.
    private func runProbe() {
        guard !probing, let url = URL(string: host) else { return }
        probing = true
        justChecked = false
        Task {
            let result = await OllamaProbe(baseURL: url).probe()
            probe = result
            probing = false
            justChecked = true
            try? await Task.sleep(for: .seconds(2))
            justChecked = false
        }
    }

    /// Explicit status for the embedding model the semantic features depend on —
    /// flagged MISSING even when other models are installed, so it's never a
    /// silent gap (you can have an LLM but no embedder and not know it).
    @ViewBuilder
    private var embeddingGroup: some View {
        let embedModel = "nomic-embed-text"
        let reachable = probe?.reachable == true
        let present = probe.map { EmbeddingAvailabilityChecker.modelPresent(embedModel, in: $0.models) } ?? false
        SettingsGroup("Search model", tag: present ? "Installed" : (reachable ? "Not installed" : "Ollama not running"))
        {
            SettingsRow(
                key: embedModel,
                hint: present
                    ? "This is what powers search by meaning, library answers, and meeting indexing."
                    : "Needed for search by meaning, library answers, and meeting indexing. In Terminal, run “ollama pull \(embedModel)”, then check again.",
                value: present ? "Ready" : (reachable ? "Not installed" : "Ollama not running")
            ) {
                if !present {
                    HStack(spacing: 8) {
                        if probing { ProgressView().controlSize(.small) }
                        BrutalistButton("Check again", kind: .ghost) { runProbe() }
                            .disabled(probing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modelsGroup: some View {
        let count = probe?.models.count ?? 0
        SettingsGroup("Installed models", tag: count == 1 ? "1 model" : "\(count) models") {
            if let models = probe?.models, !models.isEmpty {
                ForEach(models, id: \.name) { model in
                    SettingsRow(key: model.name, hint: digestHint(model)) {
                        Text(formatBytes(model.sizeBytes))
                            .font(BrutalistTypography.mono10)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                let statusText = probe?.reachable == true ? "Ready" : "Not running"
                SettingsRow(
                    key: "No models yet",
                    hint: "In Terminal, run “ollama pull nomic-embed-text” to add the model Trace uses for search.",
                    value: statusText
                ) {
                    BrutalistButton("How to install", kind: .ghost) {}
                }
            }
        }
    }

    private func digestHint(_ model: OllamaModel) -> String? {
        // The internal version hash isn't meaningful to most people, so the row
        // shows just the model name and size.
        nil
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let gb = Double(bytes) / 1_000_000_000.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000.0
        return String(format: "%.0f MB", mb)
    }
}

@MainActor
public struct CalendarSettingsView: View {
    @Environment(\.brutalistPalette) private var palette
    var state: AppStateModel?
    /// Live slider value; committed on release (avoids a meeting-runtime rebuild per tick).
    @State private var windowDraft: Double = 15

    public init(state: AppStateModel? = nil) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Calendar") {
                SettingsRow(
                    key: "Use your calendar",
                    hint:
                        "Match recordings to events in your Calendar app (iCloud, Google, or Microsoft). The event title and attendees make your meeting notes richer and help file meetings into the right project. You can grant access during setup."
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { state?.meetingCalendarEnabled ?? true },
                            set: { state?.meetingCalendarEnabled = $0 }
                        )
                    ).labelsHidden()
                }
                SettingsRow(
                    key: "Matching window",
                    hint: "How close to an event’s start time a recording has to be for Trace to link them.",
                    showDivider: false
                ) {
                    HStack {
                        Slider(
                            value: $windowDraft, in: 5...60,
                            onEditingChanged: { editing in
                                if !editing { state?.meetingCalendarWindowMinutes = Int(windowDraft) }
                            }
                        )
                        .frame(width: 200)
                        .disabled(state?.meetingCalendarEnabled == false)
                        Text("± \(Int(windowDraft)) min")
                            .font(BrutalistTypography.mono11)
                            .foregroundStyle(.primary)
                    }
                }
            }
            SettingsGroup("Filing meetings") {
                SettingsRow(
                    key: "Use attendees to sort meetings",
                    hint:
                        "When your calendar is connected, who’s on the invite helps Trace decide which project a meeting belongs to — alongside a few other signals.",
                    showDivider: false
                ) {
                    Text(state?.meetingCalendarEnabled == false ? "Off" : "On")
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                }
            }
        }
        .task { windowDraft = Double(state?.meetingCalendarWindowMinutes ?? 15) }
    }
}

@MainActor
public struct AccessibilityPasteSettingsView: View {
    @State private var status: PermissionStatus = .notDetermined
    private let requester = PermissionRequester()
    private let gate = PermissionGate()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Permission", tag: status == .granted ? "Granted" : "Not granted yet") {
                SettingsRow(
                    key: "Let Trace type for you",
                    hint:
                        "With Accessibility access, Trace can place your dictated text right where your cursor is. Without it, Trace copies the text and pastes it instead."
                ) {
                    HStack(spacing: 8) {
                        BrutalistButton("Grant access", kind: .primary) {
                            Task {
                                let result = await requester.request(.accessibility)
                                status = result
                            }
                        }
                        BrutalistButton("Open Settings", kind: .ghost) {
                            requester.openSystemSettings(for: .accessibility)
                        }
                    }
                }
            }
            SettingsGroup("How text is inserted") {
                SettingsRow(
                    key: "Method",
                    hint:
                        "Type at the cursor places text right where you’re working. Paste instead copies your text and pastes it with ⌘V."
                ) {
                    Picker("", selection: .constant("AX-first")) {
                        Text("Type at the cursor").tag("AX-first")
                        Text("Paste instead").tag("Clipboard only")
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
        }
        .task {
            let snap = await gate.snapshot()
            status = snap.accessibility
        }
    }
}

@MainActor
public struct DiagnosticsSettingsView: View {
    @Environment(\.brutalistPalette) private var palette
    var state: AppStateModel?
    @State private var exportStatus = ""

    public init(state: AppStateModel? = nil) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Real configuration snapshot (the previous latency counters were
            // fabricated — a live metrics pipeline is tracked in the backlog).
            SettingsGroup("Your current setup") {
                let rows = configRows
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    SettingsRow(key: row.0, hint: nil, value: row.1, showDivider: idx != rows.count - 1) {
                        EmptyView()
                    }
                }
            }
            SettingsGroup("Support report") {
                SettingsRow(
                    key: "Diagnostics report",
                    hint: exportStatus.isEmpty
                        ? "Save a small text file with your current setup. Handy to share if you run into a problem."
                        : exportStatus,
                    showDivider: false
                ) {
                    BrutalistButton("Export", kind: .ghost) { exportDiagnostics() }
                }
            }
            // Read-only audio-pipeline plumbing, moved here from the former
            // standalone Audio Devices tab. Capture follows the macOS system
            // default input; everything is resampled to the canonical ASR rate.
            SettingsGroup("Audio") {
                SettingsRow(
                    key: "Microphone",
                    hint: "Trace uses whichever microphone your Mac is set to. Change it in System Settings → Sound."
                ) {
                    audioInfoValue("System microphone")
                }
                SettingsRow(
                    key: "Meeting audio",
                    hint:
                        "Trace can hear the other people on a call without joining as a bot or showing up in the meeting.",
                    showDivider: false
                ) {
                    audioInfoValue("Captured on this Mac")
                }
            }
        }
    }

    private func audioInfoValue(_ text: String) -> some View {
        Text(text)
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.fgMuted.color)
            .frame(width: 240, alignment: .trailing)
    }

    private var configRows: [(String, String)] {
        guard let state else { return [("State", "unavailable")] }
        return [
            ("Dictation model", state.dictationASREngine.rawValue),
            ("Meeting model", state.meetingASREngine.rawValue),
            (
                "Search",
                "\(state.embeddingProvider.displayName) · \(state.embeddingModel(for: state.embeddingProvider))"
            ),
            ("Storage limit", "\(Int(state.cacheBudgetGb)) GB"),
        ]
    }

    private func exportDiagnostics() {
        var lines = ["Trace diagnostics", ""]
        lines += configRows.map { "\($0.0): \($0.1)" }
        lines += [
            "",
            "Full logs: run in Terminal —",
            "  log show --predicate 'subsystem == \"app.trace\"' --info --last 1h",
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-diagnostics.txt")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            exportStatus = "Wrote \(url.path)"
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// Settings → Integrations.
///
/// The former Calendar, Watched Folders, and
/// Accessibility / Paste tabs merged into one surface — they were each sparse, so
/// they read better as labeled sections under a single tab. Each section reuses
/// its original view verbatim, so all behavior (EventKit, folder watching, the AX
/// permission flow) is preserved.
@MainActor
public struct IntegrationsSettingsView: View {
    @Environment(\.brutalistPalette) private var palette
    var state: AppStateModel?

    public init(state: AppStateModel? = nil) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            sectionHeader("Calendar")
            CalendarSettingsView(state: state)
            sectionHeader("Watched folders")
            WatchedFoldersSettingsView(state: state)
            sectionHeader("Typing for you")
            AccessibilityPasteSettingsView()
        }
    }

    /// A quiet section divider/header between the merged integration areas — the
    /// SettingsGroup title style, but spanning a full section rather than a card.
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(BrutalistTypography.groupTitle)
                .foregroundStyle(palette.fg.color)
            Spacer()
        }
        .padding(.horizontal, 36)
        .padding(.top, 22)
        .padding(.bottom, 2)
    }
}

@MainActor
public struct AboutSettingsView: View {
    var state: AppStateModel?

    public init(state: AppStateModel? = nil) {
        self.state = state
    }

    private var appVersion: String {
        AppVersion.label ?? "—"
    }

    public var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Version") {
                SettingsRow(
                    key: "Trace",
                    hint: "Your Mac companion for voice — dictation, meetings, files, and a meeting coach."
                ) {
                    Text(appVersion)
                        .font(BrutalistTypography.mono10)
                        .foregroundStyle(.secondary)
                }
            }
            SettingsGroup("Setup") {
                SettingsRow(
                    key: "Run setup again",
                    hint: "Step through permissions, models, projects, and shortcuts one more time."
                ) {
                    BrutalistButton("Run setup", kind: .primary) { state?.resetOnboarding() }
                }
            }
            SettingsGroup("Built with") {
                SettingsRow(key: "FluidAudio", hint: "On-device transcription and telling speakers apart · Apache 2.0")
                {
                    EmptyView()
                }
                SettingsRow(key: "WhisperKit", hint: "On-device Whisper transcription · by Argmax · MIT") {
                    EmptyView()
                }
                SettingsRow(key: "DynamicNotchKit", hint: "The drop-down notch display · by MrKai77 · MIT") {
                    EmptyView()
                }
                SettingsRow(key: "Sparkle", hint: "Keeps Trace up to date · the Sparkle Project · MIT") {
                    EmptyView()
                }
                SettingsRow(
                    key: "And more",
                    hint: "Full credits and licences are in THIRD-PARTY-LICENSES in the source repository."
                ) {
                    EmptyView()
                }
            }
        }
    }
}
