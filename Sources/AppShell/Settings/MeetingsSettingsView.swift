import AppKit
import Combine
import SharedCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Meetings.
///
/// All meeting configuration in one place: capture
/// behavior (auto-detect, live summary), and model selection as clean
/// selectable-list rows (every engine/provider visible at once, the active one
/// marked with the brutalist leading orange dot) rather than hidden dropdowns.
@MainActor
public struct MeetingsSettingsView: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable var state: AppStateModel
    @State private var availability: DictationAvailability = .unknown
    @State private var detectableApps: [DetectableApp] = []
    @State private var showAdvanced = false
    @State private var ollamaModels: [String] = []
    /// Connect-card providers with a credential right now — gates whether they
    /// appear in the notes / title / categorization pickers (BAS-60).
    @State private var connectedProviders: Set<ModelProvider> = []
    /// Cloud-ASR providers (by `rawValue`) that have a key in the Keychain.
    ///
    /// Gates
    /// the meeting Cloud-provider list so a keyless provider isn't a silent
    /// dead-end — keys live in Dictation Models → API.
    @State private var cloudASRKeysPresent: Set<String> = []

    private let cadenceChoices = [30, 45, 60, 90, 120]
    private let silenceChoices = [30, 45, 60, 90, 120, 180, 300]
    private let autoStopChoices = [300, 600, 900, 1800]
    private let promptTimeoutChoices = [10, 15, 20, 30, 45]
    /// Notes providers offered for meetings. `.deterministic` is excluded —
    /// there is no deterministic note generator; notes always route to an LLM.
    ///
    /// The notes / title / categorization groups all offer the same set — the
    /// always-on providers (BAS-49) plus any connected cloud provider (BAS-60),
    /// and the group's current selection even if it has since disconnected (so it
    /// stays visible/dotted rather than silently vanishing).
    private func notesProviders(selected: DictationCleanupProvider) -> [DictationCleanupProvider] {
        support.offered(for: .meetingNotes, current: selected)
    }

    /// Plain-language summary of how many speaker voiceprints are remembered on
    /// this Mac, shown beside the "Forget all" button (BAS-11).
    private var rememberedSpeakersHint: String {
        let count = state.meetingRememberedSpeakerCount
        let voices = count == 1 ? "1 voice" : "\(count) voices"
        return "\(voices) remembered on this Mac. Clearing forgets every saved speaker."
    }

    public init(state: AppStateModel = AppStateModel()) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            SettingsGroup("Capture") {
                SettingsRow(
                    key: "Notice when a meeting starts",
                    hint:
                        "When a call gets going, Trace can offer to take notes. Off by default, so it never starts recording without you."
                ) {
                    Toggle("", isOn: $state.meetingAutoDetectEnabled).labelsHidden()
                }
                SettingsRow(
                    key: "When a meeting is noticed",
                    hint: "Ask you first — the notch drops down to check — or just start taking notes."
                ) {
                    Picker("", selection: $state.meetingAutoStartOnDetect) {
                        Text("Ask me").tag(false)
                        Text("Start automatically").tag(true)
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .disabled(!state.meetingAutoDetectEnabled)
                }
                SettingsRow(
                    key: "Summarize as you go",
                    hint:
                        "Build up decisions, open questions, and action items during the meeting. You’ll get the full write-up at the end either way.",
                    showDivider: false
                ) {
                    Toggle("", isOn: $state.meetingLiveSummaryEnabled).labelsHidden()
                }
            }

            SettingsGroup("Tell speakers apart", tag: speakerIdentificationTag) {
                SettingsRow(
                    key: "Label who’s speaking",
                    hint:
                        "Beta · separate the other people on a call as Speaker 1, Speaker 2, and so on, instead of lumping them together as “Others”. Off keeps the simple You / Others. Runs entirely on your Mac.",
                    showDivider: state.meetingDiarizationEnabled
                ) {
                    Toggle("", isOn: $state.meetingDiarizationEnabled).labelsHidden()
                }
                if state.meetingDiarizationEnabled {
                    SettingsRow(
                        key: "Label speakers during the meeting",
                        hint:
                            "Mark who’s talking as they speak. It’s a best guess in the moment, then tidied up afterwards."
                    ) {
                        Toggle("", isOn: $state.meetingLiveDiarizationEnabled).labelsHidden()
                    }
                    SettingsRow(
                        key: "Polish the labels afterwards",
                        hint:
                            "At the end, Trace re-listens to the recording to get the speaker labels more accurate and consistent. This means keeping a recording of the call on your Mac while you meet.",
                        showDivider: state.meetingOfflineDiarizationRefinementEnabled
                    ) {
                        Toggle("", isOn: $state.meetingOfflineDiarizationRefinementEnabled).labelsHidden()
                    }
                    if state.meetingOfflineDiarizationRefinementEnabled {
                        SettingsRow(
                            key: "Remember voices between meetings",
                            hint:
                                "Recognize the same people next time, so when you rename “Speaker 2” to “Sarah” it sticks. Voice profiles stay on your Mac and are never uploaded.",
                            showDivider: true
                        ) {
                            Toggle("", isOn: $state.meetingSpeakerMemoryEnabled).labelsHidden()
                        }
                        if state.meetingSpeakerMemoryEnabled {
                            SettingsRow(
                                key: "Remembered voices",
                                hint: rememberedSpeakersHint,
                                showDivider: true
                            ) {
                                Button("Forget all") {
                                    NotificationCenter.default.post(name: .traceClearSpeakerMemory, object: nil)
                                }
                                .disabled(state.meetingRememberedSpeakerCount == 0)
                            }
                        }
                        SettingsRow(
                            key: "Keep the recording afterwards",
                            hint:
                                "Hold on to the recording so speaker labels can be improved again later. Uses about 230 MB per hour. Turn off to delete it once labels are polished.",
                            showDivider: false
                        ) {
                            Toggle("", isOn: $state.meetingKeepCallRecordingEnabled).labelsHidden()
                        }
                    }
                }
            }

            if state.meetingAutoDetectEnabled {
                SettingsGroup("Apps to watch") {
                    ForEach(Array(detectableApps.enumerated()), id: \.element.id) { _, app in
                        appToggleRow(app, showDivider: true)
                    }
                    addAppRow
                }
            }

            SettingsGroup("Transcription model") {
                ForEach(DictationASREngine.allCases, id: \.self) { engine in
                    selectRow(
                        title: engine.displayName,
                        detail: engineDetail(engine),
                        selected: state.meetingASREngine == engine,
                        showDivider: engine != DictationASREngine.allCases.last
                    ) {
                        state.meetingASREngine = engine
                    }
                }
            }

            // Cloud provider sub-picker — only when the meeting engine is Cloud
            // (BAS-58). Keys are entered once in Dictation Models → API and shared.
            if state.meetingASREngine == .cloud {
                SettingsGroup("Cloud service", tag: "Add keys under Dictation models → Cloud") {
                    let offered = offeredCloudASRProviders(selected: state.meetingCloudProvider)
                    ForEach(offered, id: \.self) { provider in
                        let hasKey = cloudASRKeysPresent.contains(provider.rawValue)
                        selectRow(
                            title: provider.displayName,
                            detail: cloudASRDetail(provider, hasKey: hasKey),
                            selected: state.meetingCloudProvider == provider,
                            showDivider: provider != offered.last,
                            logo: provider.brandLogo
                        ) {
                            state.meetingCloudProvider = provider
                        }
                    }
                    if offeredCloudASRProviders(selected: state.meetingCloudProvider).count
                        < CloudASRProvider.allCases.count
                    {
                        SettingsRow(
                            key: "Looking for another service?",
                            hint: "Add its API key under Dictation models → Cloud, and it’ll show up here.",
                            showDivider: false
                        ) { EmptyView() }
                    }
                }
            }

            SettingsGroup(
                "Language",
                tag: state.meetingTranscriptionLanguage == .auto
                    ? "Detect automatically" : state.meetingTranscriptionLanguage.displayName
            ) {
                SettingsRow(
                    key: "Meeting language",
                    hint:
                        "Trace can detect the language on its own, or you can set one — for example, pick Chinese (Mandarin) so a Chinese meeting isn’t written up as English. This applies whichever model you use.",
                    showDivider: false
                ) {
                    Picker("", selection: $state.meetingTranscriptionLanguage) {
                        ForEach(TranscriptionLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            // One control for the whole end-of-meeting LLM pass. Picking a provider
            // + model here fans the choice out to notes, title, and categorization
            // so the user configures it once instead of three times. Per-stage
            // overrides still live in Settings → LLM Router (Advanced).
            SettingsGroup("Which AI writes your notes", tag: providerGroupTag(state.meetingAIProvider)) {
                ForEach(notesProviders(selected: state.meetingAIProvider), id: \.self) { provider in
                    selectRow(
                        title: provider.displayName,
                        detail: providerDetail(provider),
                        selected: state.meetingAIProvider == provider,
                        showDivider: true,
                        logo: provider.brandLogo
                    ) {
                        state.meetingAIProvider = provider
                    }
                }
                StageModelRow(
                    state: state,
                    stage: .meetingNotes,
                    installedOllamaModels: ollamaModels,
                    label: "Model",
                    openRouterPlaceholder: "openai/gpt-5",
                    openRouterHint:
                        "The OpenRouter model name — for example openai/gpt-5, anthropic/claude-sonnet-4.6, or google/gemini-2.0-flash.",
                    mirrorStages: [.meetingTitle, .meetingCategorization]
                )
            }

            SettingsGroup("How your notes are written") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Tell Trace how you’d like every meeting written up. When you regenerate notes, you can add a one-off twist just for that version."
                    )
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    TextEditor(text: $state.meetingSummaryInstructions)
                        .font(BrutalistTypography.mono12)
                        .foregroundStyle(palette.fg.color)
                        .scrollContentBackground(.hidden)
                        .frame(height: 110)
                        .padding(8)
                        .background(palette.background.color)
                        .overlay(Rectangle().stroke(palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline))
                }
                .padding(14)
            }

            advancedSection
        }
        .onReceive(NotificationCenter.default.publisher(for: .traceProvidersChanged)) { _ in
            connectedProviders = ModelProvider.routingConnectedSet()
            // Also re-probe cloud-ASR keys: adding/removing a key on the Dictation
            // Models tab posts this same notification, and without re-reading here a
            // just-added provider would stay hidden in this picker until the view
            // was rebuilt.
            cloudASRKeysPresent = CloudASRProvider.keyedProviders()
        }
        .task {
            connectedProviders = ModelProvider.routingConnectedSet()
            cloudASRKeysPresent = CloudASRProvider.keyedProviders()
            detectableApps = Self.loadDetectableApps(custom: state.meetingCustomApps)
            availability = await DictationAvailabilityProbe().probe()
            ollamaModels = await OllamaModels.installed()
            // If the configured Ollama notes model isn't actually installed,
            // fall back to the first installed one — so summaries don't fail on a
            // missing model (the old hard-coded llama3.2 default did exactly that).
            if state.meetingNotesProvider == .ollama, !ollamaModels.isEmpty,
                !ollamaModels.contains(state.meetingNotesModel(for: .ollama))
            {
                state.setMeetingNotesModel(ollamaModels[0], for: .ollama)
            }
        }
    }

    /// Beta badge on the Speaker-identification group that doubles as a readiness
    /// indicator while the on-device models download/compile in the background.
    private var speakerIdentificationTag: String {
        guard state.meetingDiarizationEnabled else { return "Beta" }
        switch state.diarizationReadiness.status {
        case .preparing: return "Beta · getting ready…"
        case .failed: return "Beta · couldn’t load"
        case .ready, .unprepared: return "Beta"
        }
    }

    // MARK: Advanced (collapsed by default) — fiddly numeric tuning kept out of
    // the everyday view; the chevron header mirrors the SettingsGroup title style.

    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(palette.fgMuted.color)
                    Text("Advanced")
                        .font(BrutalistTypography.groupTitle)
                        .foregroundStyle(palette.fgMuted.color)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(
                        key: "How often the summary updates",
                        hint:
                            "How frequently the running summary refreshes during a meeting. Only applies when “Summarize as you go” is on."
                    ) {
                        Picker("", selection: $state.meetingLiveSummaryCadenceSeconds) {
                            ForEach(cadenceChoices, id: \.self) { seconds in
                                Text("\(seconds)s").tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        .disabled(!state.meetingLiveSummaryEnabled)
                    }
                    SettingsRow(
                        key: "Ask if the meeting ended",
                        hint:
                            "After this much quiet, the notch asks whether the call is over. It never stops on its own."
                    ) {
                        Picker("", selection: $state.meetingSilenceThresholdSeconds) {
                            ForEach(silenceChoices, id: \.self) { seconds in
                                Text(seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds)s").tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    SettingsRow(
                        key: "Stop after a long silence",
                        hint:
                            "Automatically stop and save a meeting Trace started for you after this much quiet, so a forgotten call doesn’t run forever. Only applies when Trace notices meetings for you."
                    ) {
                        Picker("", selection: $state.meetingAutoStopSilenceSeconds) {
                            ForEach(autoStopChoices, id: \.self) { seconds in
                                Text("\(seconds / 60) min").tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        .disabled(!state.meetingAutoDetectEnabled)
                    }
                    SettingsRow(
                        key: "How long prompts stay up",
                        hint:
                            "How long the “start?” and “ended?” prompts wait for an answer before they fade away. The countdown line follows this.",
                        showDivider: false
                    ) {
                        Picker("", selection: $state.meetingPromptTimeoutSeconds) {
                            ForEach(promptTimeoutChoices, id: \.self) { seconds in
                                Text("\(seconds)s").tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.bgCard.color)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(palette.borderSoft.color, lineWidth: BrutalistMetrics.hairline)
                )
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 10)
    }

    // MARK: Selectable list row (active = leading orange dot + subtle gray fill)

    private func selectRow(
        title: String,
        detail: String,
        selected: Bool,
        showDivider: Bool,
        logo: BrandLogo? = nil,
        action: @escaping () -> Void
    ) -> some View {
        BrutalistSelectRow(
            title: title, detail: detail, selected: selected,
            showDivider: showDivider, logo: logo, action: action
        )
    }

    // MARK: Auto-detect app list (explicit per-app on/off; we never auto-mute)

    /// One app row: icon + name + a toggle.
    ///
    /// ON = auto-detect this app; OFF mutes
    /// it (added to `meetingMutedApps`). This is the only way an app gets muted.
    private func appToggleRow(_ app: DetectableApp, showDivider: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 18, height: 18)
            Text(app.name)
                .font(BrutalistTypography.label)
                .foregroundStyle(palette.fg.color)
            if app.isCustom {
                Button {
                    state.removeMeetingCustomApp(app.id)
                    detectableApps = Self.loadDetectableApps(custom: state.meetingCustomApps)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.fgMuted.color)
                }
                .buttonStyle(.plain)
                .help("Remove this custom app")
            }
            Spacer(minLength: 12)
            Toggle(
                "",
                isOn: Binding(
                    get: { !state.isMeetingAppMuted(app.id) },
                    set: { state.setMeetingAppMuted(app.id, muted: !$0) }
                )
            )
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if showDivider {
                Rectangle()
                    .fill(palette.borderSoft.color)
                    .frame(height: BrutalistMetrics.hairline)
                    .padding(.leading, 14)
            }
        }
    }

    /// Installed meeting + browser apps (from `MeetingAppCatalog`), resolved to a
    /// display name + icon for the per-app auto-detect toggles.
    ///
    /// Uninstalled apps
    /// are skipped. Runs on the main actor (NSWorkspace / NSImage).
    private static func loadDetectableApps(custom: Set<String>) -> [DetectableApp] {
        let ws = NSWorkspace.shared
        let builtIn = MeetingAppCatalog.meetingAppBundleIDs.union(MeetingAppCatalog.browserBundleIDs)
        var apps: [DetectableApp] = []
        for id in builtIn.union(custom) {
            guard let url = ws.urlForApplication(withBundleIdentifier: id) else { continue }
            let raw = FileManager.default.displayName(atPath: url.path)
            let name = raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
            let icon = ws.icon(forFile: url.path)
            icon.size = NSSize(width: 18, height: 18)
            apps.append(DetectableApp(id: id, name: name, icon: icon, isCustom: !builtIn.contains(id)))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Present a file picker so the user can add any installed app to the
    /// auto-detect catalog.
    ///
    /// The chosen app's bundle ID is stored (the model posts
    /// a re-arm) and the list refreshed. No-op on cancel or a bundle with no ID.
    private func addCustomApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose a meeting or calling app for Trace to watch."
        guard panel.runModal() == .OK,
            let url = panel.url,
            let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        state.addMeetingCustomApp(bundleID)
        detectableApps = Self.loadDetectableApps(custom: state.meetingCustomApps)
    }

    /// "Add app…" affordance at the bottom of the auto-detect list.
    private var addAppRow: some View {
        Button(action: addCustomApp) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.primary.color)
                    .frame(width: 18, height: 18)
                Text("Add app…")
                    .font(BrutalistTypography.label)
                    .foregroundStyle(palette.primary.color)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail strings + availability tag

    private func engineDetail(_ engine: DictationASREngine) -> String {
        switch engine {
        case .parakeet: return "On your Mac · fast"
        case .appleSpeech: return "On your Mac · built into macOS"
        case .whisperKit:
            return availability.whisperKitReady
                ? "On your Mac · ready" : "On your Mac · downloads the first time you use it"
        case .qwen3:
            return availability.qwen3Ready
                ? "On your Mac · many languages · ready"
                : "On your Mac · many languages · downloads the first time you use it"
        case .cloud: return "Cloud · uses your own key"
        }
    }

    /// The shared provider-picker helper, seeded with this view's live snapshot.
    private var support: ProviderPickerSupport {
        ProviderPickerSupport(availability: availability, connectedProviders: connectedProviders)
    }

    private func providerDetail(_ provider: DictationCleanupProvider) -> String {
        support.detail(for: provider)
    }

    /// Status chip for a model-picker group — shared by the notes / title /
    /// categorization groups (they differ only in which provider they read).
    private func providerGroupTag(_ provider: DictationCleanupProvider) -> String {
        support.groupTag(for: provider)
    }

    // MARK: Cloud ASR provider gating (BAS — no silent dead-ends)

    /// Cloud-ASR providers offered in the meeting picker: only those with a key in
    /// the Keychain, plus the current selection so it never vanishes mid-flight.
    ///
    /// Keys are entered once in Dictation Models → API and shared.
    private func offeredCloudASRProviders(selected: CloudASRProvider) -> [CloudASRProvider] {
        var list = CloudASRProvider.allCases.filter { cloudASRKeysPresent.contains($0.rawValue) }
        if !list.contains(selected) { list.append(selected) }
        return list
    }

    private func cloudASRDetail(_ provider: CloudASRProvider, hasKey: Bool) -> String {
        let mode = provider.supportsStreaming ? "live" : "after the call"
        return hasKey ? "Cloud · \(mode)" : "Cloud · needs a key"
    }

    // Per-stage model rows are rendered by the shared `StageModelRow` component
    // (BAS-49) — see the Notes / Title / Auto-categorization groups above.
}

/// One installed, auto-detectable app shown in Settings → Meetings → Auto-detect
/// apps, with a per-app on/off toggle.
///
/// We never auto-mute; this list is the only
/// way an app gets muted.
private struct DetectableApp: Identifiable {
    let id: String  // bundle identifier
    let name: String
    let icon: NSImage
    let isCustom: Bool  // user-added (removable) vs built-in catalog
}
