import SharedCore
import SwiftUI

public enum SettingsTab: String, Sendable, Hashable, CaseIterable, Identifiable {
    case appearance
    case libraryStorage
    case updates
    case modesAndPrompts
    case hotkeys
    case dictationModels  // formerly .asrEngines
    case meetings
    case llmRouter
    case coachTriggers
    case integrations
    case diagnostics
    case about

    public var id: String { rawValue }

    public var section: String {
        switch self {
        case .appearance, .libraryStorage, .updates: return "General"
        case .modesAndPrompts, .hotkeys, .dictationModels, .meetings:
            return "Voice"
        case .llmRouter, .coachTriggers:
            return "Intelligence"
        case .integrations: return "Integrations"
        case .diagnostics, .about: return "About"
        }
    }

    /// Tabs whose view is a master-detail layout that fills the whole pane and
    /// scrolls internally — they must NOT be wrapped in the outer card ScrollView
    /// (that would collapse them to content height and leave dead space).
    public var fillsPane: Bool {
        switch self {
        case .modesAndPrompts: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .libraryStorage: return "Library & storage"
        case .updates: return "Updates"
        case .modesAndPrompts: return "Modes & prompts"
        case .hotkeys: return "Keyboard shortcuts"
        case .dictationModels: return "Dictation models"
        case .meetings: return "Meetings"
        case .llmRouter: return "AI models"
        case .coachTriggers: return "Meeting coach"
        case .integrations: return "Integrations"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }

    /// SF Symbol shown beside the tab in the settings sidebar.
    public var symbol: String {
        switch self {
        case .appearance: return "paintbrush"
        case .libraryStorage: return "externaldrive"
        case .updates: return "arrow.down.circle"
        case .modesAndPrompts: return "text.bubble"
        case .hotkeys: return "command"
        case .dictationModels: return "waveform"
        case .meetings: return "person.2.wave.2"
        case .llmRouter: return "brain"
        case .coachTriggers: return "sparkles"
        case .integrations: return "puzzlepiece.extension"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

@MainActor
public struct SettingsRootView: View {
    @Environment(\.brutalistPalette) private var palette
    @State private var selectedTab: SettingsTab = .llmRouter
    let appState: AppStateModel?
    /// When non-nil (the full-window Settings takeover), a Back control renders at
    /// the top of the sidebar — in its own top strip — so the NavigationSplitView
    /// stays the top-level content and draws exactly one sidebar top (traffic
    /// lights over it), instead of being wrapped under a separate strip that
    /// doubled the sidebar's top edge in full-screen.
    let onBack: (() -> Void)?

    public init(appState: AppStateModel? = nil, onBack: (() -> Void)? = nil) {
        self.appState = appState
        self.onBack = onBack
    }

    public var body: some View {
        NavigationSplitView {
            SettingsSubNav(selected: $selectedTab, onBack: onBack)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 340)
                // Kill the default macOS sidebar collapse/expand toolbar button
                // (the Settings sidebar is fixed + always shown) — same as the
                // main app shell, which removes it and supplies its own control.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailPane(tab: selectedTab, appState: appState)
        }
        .background(palette.background.color)
        .frame(minWidth: 960, minHeight: 600)
        // Deep-link support ("Open Settings → AI models" on a notice banner):
        // consume the one-shot pending tab whether this view mounts after the
        // request (onAppear) or is already on screen (onReceive).
        .onAppear { applyPendingTab() }
        .onReceive(NotificationCenter.default.publisher(for: .traceOpenSettingsTab)) { _ in
            applyPendingTab()
        }
    }

    private func applyPendingTab() {
        guard let appState, let tab = appState.pendingSettingsTab else { return }
        selectedTab = tab
        appState.pendingSettingsTab = nil
    }
}

@MainActor
public struct SettingsSubNav: View {
    @Environment(\.brutalistPalette) private var palette
    @Binding public var selected: SettingsTab
    var onBack: (() -> Void)? = nil

    public init(selected: Binding<SettingsTab>, onBack: (() -> Void)? = nil) {
        self._selected = selected
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let onBack { backStrip(onBack) }
            scrollBody
        }
        .background(palette.bgTertiary.color)
    }

    private func backStrip(_ onBack: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Back").font(BrutalistTypography.label)
                }
                .foregroundStyle(palette.fg.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.secondary.color))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the app")
            Spacer()
        }
        // Leading inset clears the macOS traffic-light buttons that overlay the
        // sidebar's top-left corner (the window is .hiddenTitleBar).
        .padding(.leading, 76)
        .padding(.trailing, 12)
        .frame(height: kColumnTopStripHeight)
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.sections, id: \.self) { section in
                    Text(section)
                        .font(BrutalistTypography.captionEmphasis)
                        .foregroundStyle(palette.fgMuted.color)
                        .padding(.horizontal, 14)
                        .padding(.top, 18)
                        .padding(.bottom, 6)
                    ForEach(SettingsTab.allCases.filter { $0.section == section }) { tab in
                        Button {
                            selected = tab
                        } label: {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 13))
                                    .foregroundStyle(tab == selected ? palette.primary.color : palette.fgMuted.color)
                                    .frame(width: 18, alignment: .center)
                                Text(tab.title)
                                    .font(BrutalistTypography.label)
                                    .foregroundStyle(tab == selected ? palette.fg.color : palette.fgSidebar.color)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(tab == selected ? palette.secondary.color : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private static let sections = ["General", "Voice", "Intelligence", "Integrations", "About"]
}

@MainActor
public struct SettingsDetailPane: View {
    @Environment(\.brutalistPalette) private var palette
    public let tab: SettingsTab
    public let appState: AppStateModel?

    public init(tab: SettingsTab, appState: AppStateModel? = nil) {
        self.tab = tab
        self.appState = appState
    }

    public var body: some View {
        Group {
            if tab.fillsPane {
                // Master-detail tabs (e.g. Modes & prompts) fill the whole pane and
                // scroll internally — wrapping them in the outer card ScrollView would
                // collapse them to their content height and leave dead space below.
                VStack(alignment: .leading, spacing: 0) {
                    header
                    content
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        content
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background.color)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tab.title)
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
            Text(blurb)
                .font(BrutalistTypography.body)
                .foregroundStyle(palette.fgMuted.color)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blurb: String {
        switch tab {
        case .appearance: return "Choose how Trace looks — light or dark, and how spacious things feel."
        case .libraryStorage: return "See where your recordings and notes are kept, and how much space they can use."
        case .updates: return "Decide how Trace keeps itself up to date."
        case .modesAndPrompts: return "Set up rules that change how your dictation is tidied up, app by app."
        case .hotkeys: return "Pick the keyboard shortcuts that start and stop Trace."
        case .dictationModels: return "Choose the model that turns your speech into text, and pick its language."
        case .meetings: return "Set how meetings are detected, transcribed, and written up."
        case .llmRouter: return "Connect the AI services Trace can use, and choose which one handles each task."
        case .coachTriggers:
            return "Live help during meetings — answers, recalled notes, and things to say. Runs on a cloud model."
        case .integrations: return "Connect your calendar, watch folders for recordings, and let Trace type for you."
        case .diagnostics: return "Check your current setup and export a report if something goes wrong."
        case .about: return "Version, credits, and a way to run setup again."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .appearance:
            if let appState {
                AppearanceSettingsView(state: appState)
            } else {
                AppearanceSettingsView()
            }
        case .llmRouter:
            LLMRouterSettingsView(state: appState)
        case .dictationModels:
            ASREnginesSettingsView(state: appState)
        case .libraryStorage: LibraryStorageSettingsView(state: appState)
        case .updates: UpdatesSettingsView(state: appState)
        case .modesAndPrompts: DictationModesSettingsView()
        case .hotkeys: HotkeysSettingsView(state: appState)
        case .meetings:
            if let appState {
                MeetingsSettingsView(state: appState)
            } else {
                MeetingsSettingsView()
            }
        case .coachTriggers: CoachTriggersSettingsView(appState: appState)
        case .integrations: IntegrationsSettingsView(state: appState)
        case .diagnostics: DiagnosticsSettingsView(state: appState)
        case .about: AboutSettingsView(state: appState)
        }
    }
}

@MainActor
struct SettingsGroup<Content: View>: View {
    @Environment(\.brutalistPalette) private var palette
    let title: String
    let tag: String?
    let content: Content

    init(_ title: String, tag: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tag = tag
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Group title sits ABOVE the card as quiet gray text (Superset /
            // macOS System Settings style) — no bar, no box.
            HStack(spacing: 8) {
                Text(title)
                    .font(BrutalistTypography.groupTitle)
                    .foregroundStyle(palette.fgMuted.color)
                if let tag {
                    Text(tag)
                        .font(BrutalistTypography.captionEmphasis)
                        .foregroundStyle(palette.fgMuted.color)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            // Rows live in a single rounded card with a subtle fill. Internal
            // hairlines (drawn by each row) separate items.
            VStack(alignment: .leading, spacing: 0) {
                content
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
        .padding(.horizontal, 32)
        .padding(.vertical, 10)
    }
}

@MainActor
struct SettingsRow<Trailing: View>: View {
    @Environment(\.brutalistPalette) private var palette
    let key: String
    let hint: String?
    let value: String?
    let showDivider: Bool
    let trailing: Trailing

    init(
        key: String, hint: String? = nil, value: String? = nil, showDivider: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.key = key
        self.hint = hint
        self.value = value
        self.showDivider = showDivider
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(key)
                    .font(BrutalistTypography.label)
                    .foregroundStyle(palette.fg.color)
                if let hint {
                    Text(hint)
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            if let value {
                Text(value)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 12)
            }
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if showDivider {
                Rectangle()
                    .fill(palette.borderSoft.color)
                    .frame(height: BrutalistMetrics.hairline)
                    .padding(.leading, 14)
            }
        }
    }
}
