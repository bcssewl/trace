import SharedCore
import SwiftUI

// Pin bare `LibraryItem` to SharedCore's type — `SwiftUI.LibraryItem` (the Xcode
// library-content API) otherwise makes the name ambiguous in this SwiftUI file.
import struct SharedCore.LibraryItem

public enum SidebarSelection: Sendable, Hashable {
    case projectRoot(UUID)
    case projectCategory(UUID, ProjectCategory)
    case meeting(String)
    case dictation(String)
    case voiceMemo(String)
    case file(String)
    case inbox
    case search
    case allMeetings
    case allDictation
    case allFiles
    case allVoiceMemos
    case playbooks
    case settings

    /// The project this selection belongs to, if any — drives "start a meeting
    /// while viewing a project files into it".
    ///
    /// Nil for Inbox / All / global pages.
    public var projectContext: String? {
        switch self {
        case .projectRoot(let id), .projectCategory(let id, _):
            return id.uuidString
        default:
            return nil
        }
    }

    /// The section a non-meeting keyword hit's "Open →" navigates to (BAS-26).
    ///
    /// Dictations / files / voice memos each have a global section; an item filed
    /// into a project deep-links to that project's category instead. Meetings
    /// deep-link via `.traceOpenMeeting`, so they return nil here.
    static func forLibraryItem(source: LibraryItem.Source, projectId: String?) -> SidebarSelection? {
        switch source {
        case .dictation:
            return .allDictation
        case .file:
            return projectId.flatMap(UUID.init(uuidString:)).map { .projectCategory($0, .files) } ?? .allFiles
        case .voiceMemo:
            return projectId.flatMap(UUID.init(uuidString:)).map { .projectCategory($0, .voiceMemos) } ?? .allVoiceMemos
        case .meeting, .transcript, .notes, .playbook:
            return nil
        }
    }

    public enum ProjectCategory: String, Sendable, Hashable, CaseIterable {
        case meetings
        case voiceMemos
        case dictation
        case files

        public var displayName: String {
            switch self {
            case .meetings: return "Meetings"
            case .voiceMemos: return "Voice Memos"
            case .dictation: return "Dictation"
            case .files: return "Files"
            }
        }
    }
}

/// Typed payload for `.traceOpenLibraryItem` (BAS-26) — a non-meeting keyword
/// hit's "Open →".
///
/// Travels as the notification `object`; the handler maps it to a
/// `SidebarSelection` via `SidebarSelection.forLibraryItem`.
public struct OpenLibraryItemRequest: Sendable, Hashable {
    public let source: LibraryItem.Source
    public let itemId: String
    public let projectId: String?

    public init(source: LibraryItem.Source, itemId: String, projectId: String?) {
        self.source = source
        self.itemId = itemId
        self.projectId = projectId
    }

    public static func from(_ notification: Notification) -> OpenLibraryItemRequest? {
        notification.object as? OpenLibraryItemRequest
    }
}

/// Shared height for the three column top strips.
///
/// Keeping a single source of
/// truth guarantees the dividers between sidebar/content/inspector line up
/// pixel-perfectly across columns. Tall enough to host the traffic-light
/// overlay (~22pt buttons + macOS padding).
public let kColumnTopStripHeight: CGFloat = 38

@MainActor
public struct MainWindowRootView: View {
    @Environment(\.brutalistPalette) private var palette
    @State private var selection: SidebarSelection = .inbox
    /// The last non-settings selection, so the full-window Settings page's Back
    /// button returns you exactly where you were.
    @State private var preSettingsSelection: SidebarSelection = .inbox
    @State private var projectsModel: ProjectsViewModel
    @State private var isInspectorVisible: Bool = false
    /// Drives the LEFT sidebar collapse via NavigationSplitView's binding.
    ///
    /// For a 2-column split: `.all` shows both columns; `.detailOnly` hides
    /// the sidebar so only the content (detail) remains.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Live width of the inspector pane.
    ///
    /// Persisted across sessions in
    /// UserDefaults so the user's preferred width sticks. Bounded by
    /// `inspectorMinWidth` / `inspectorMaxWidth`.
    @State private var inspectorWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "app.trace.inspectorWidth")
        return stored > 0 ? CGFloat(stored) : BrutalistMetrics.inspectorWidth
    }()
    @Bindable var captureState: ActiveCaptureModel
    @Bindable var appState: AppStateModel
    /// Failure/notice queue rendered as banners over the window content.
    let notices: AppNoticeCenter

    private let inspectorMinWidth: CGFloat = 240
    private let inspectorMaxWidth: CGFloat = 640

    public init(
        projectStore: ProjectStore? = nil,
        captureState: ActiveCaptureModel = ActiveCaptureModel(),
        appState: AppStateModel = AppStateModel(),
        notices: AppNoticeCenter = AppNoticeCenter()
    ) {
        _projectsModel = State(initialValue: ProjectsViewModel(store: projectStore))
        self.captureState = captureState
        self.appState = appState
        self.notices = notices
    }

    private var isMeeting: Bool { captureState.mode == .meeting }

    public var body: some View {
        Group {
            if selection == .settings {
                // Settings takes over the whole window — no app sidebar competing
                // with the settings sidebar (which left two stacked sidebars and a
                // squished pane) — with a Back button to return where you were.
                SettingsFullScreenView(appState: appState) {
                    withAnimation(.easeOut(duration: 0.18)) { selection = preSettingsSelection }
                }
            } else {
                mainSplit
            }
        }
        .frame(minWidth: BrutalistMetrics.mainWindowMinSize.width, minHeight: BrutalistMetrics.mainWindowMinSize.height)
        .background(palette.background.color)
        // Failure/notice banners float over whatever is showing — including the
        // Settings takeover — so a recovery button is never hidden by context.
        .overlay(alignment: .topTrailing) {
            NoticeBannerStack(center: notices, appState: appState)
        }
        // A notice's "Open Settings → …" button: flip to the in-window Settings
        // takeover; the target tab waits in `appState.pendingSettingsTab`.
        .onReceive(NotificationCenter.default.publisher(for: .traceOpenSettingsTab)) { _ in
            if selection != .settings {
                withAnimation(.easeOut(duration: 0.18)) { selection = .settings }
            }
        }
        .task { await projectsModel.refresh() }
        // Remember the last non-settings location (so Back returns there) and keep
        // the active project context in sync with the current selection.
        .onChange(of: selection) { old, new in
            if old != .settings { preSettingsSelection = old }
            appState.currentProjectContext = new.projectContext
        }
        .onAppear { appState.currentProjectContext = selection.projectContext }
        // Sidebar counts go stale otherwise — recompute whenever the meeting set
        // changes (start / stop / move-to-project / delete all refresh the library).
        .onChange(of: appState.meetingLibrary.meetings) { _, _ in
            Task { await projectsModel.refresh() }
        }
        // ⌘K (and the global "open library" hotkey) surface the search pane.
        .onReceive(NotificationCenter.default.publisher(for: .traceOpenSearch)) { _ in
            selection = .search
        }
        // A Library citation / keyword hit opens its meeting at the cited moment.
        .onReceive(NotificationCenter.default.publisher(for: .traceOpenMeeting)) { note in
            handleOpenMeeting(note)
        }
        // A non-meeting keyword hit navigates to the section that shows it.
        .onReceive(NotificationCenter.default.publisher(for: .traceOpenLibraryItem)) { note in
            handleOpenLibraryItem(note)
        }
    }

    /// The normal 2-column app shell (sidebar + content [+ inspector]).
    ///
    /// Shown for
    /// every selection except `.settings`, which takes over the full window.
    private var mainSplit: some View {
        // 2-column NavigationSplitView (sidebar + content). The inspector lives
        // INSIDE the content column as a sibling pane so toggling it doesn't
        // disturb NavigationSplitView's column structure (the earlier 3-column
        // + Color.clear filler caused the whole window to go black).
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection, projects: projectsModel)
                .navigationSplitViewColumnWidth(
                    min: BrutalistMetrics.sidebarMinWidth,
                    ideal: BrutalistMetrics.sidebarDefaultWidth,
                    max: BrutalistMetrics.sidebarMaxWidth
                )
                .toolbar(removing: .sidebarToggle)
        } detail: {
            HStack(spacing: 0) {
                ContentPaneView(selection: selection, appState: appState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        BrutalistToolbarRow(
                            captureMode: captureState.mode,
                            isMeeting: isMeeting,
                            captureModeLabel: captureModeLabel,
                            showSidebarToggle: columnVisibility == .detailOnly,
                            isInspectorVisible: $isInspectorVisible,
                            onExpandSidebar: toggleSidebar
                        )
                    }
                if isInspectorVisible {
                    HStack(spacing: 0) {
                        InspectorResizeHandle(
                            width: $inspectorWidth,
                            minWidth: inspectorMinWidth,
                            maxWidth: inspectorMaxWidth
                        )
                        .onChange(of: inspectorWidth) { _, newValue in
                            UserDefaults.standard.set(Double(newValue), forKey: "app.trace.inspectorWidth")
                        }
                        VStack(spacing: 0) {
                            InspectorTopStrip()
                            InspectorView(selection: selection)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .background(palette.bgTertiary.color)
                    }
                    .frame(width: inspectorWidth + BrutalistMetrics.hairline)
                    .transition(.move(edge: .trailing))
                }
            }
        }
    }

    private func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.18)) {
            columnVisibility = (columnVisibility == .all) ? .detailOnly : .all
        }
    }

    /// Open a meeting in the content pane (from a Library citation / hit), seeking
    /// the transcript to the cited timestamp if one was provided.
    private func handleOpenMeeting(_ note: Notification) {
        guard let request = OpenMeetingRequest.from(note) else { return }
        // Hand the open to the meetings view via a one-shot, THEN switch to it, so
        // the request is waiting when the freshly-mounted view appears.
        appState.meetingLibrary.pendingOpen = .init(sessionId: request.meetingId, timestamp: request.timestamp)
        selection = .allMeetings
    }

    /// Navigate to the section that shows a non-meeting keyword hit's item.
    private func handleOpenLibraryItem(_ note: Notification) {
        guard let request = OpenLibraryItemRequest.from(note),
            let target = SidebarSelection.forLibraryItem(source: request.source, projectId: request.projectId)
        else { return }
        selection = target
    }

    private var captureModeLabel: String {
        switch captureState.mode {
        case .dictation: return "● Dictating"
        case .voiceMemo: return "● Voice memo"
        case .meeting: return "● Meeting"
        case .idle: return ""
        }
    }
}

/// Full-window Settings.
///
/// Replaces the whole app shell (so the app sidebar no
/// longer competes with the settings sidebar) and adds a Back button to return
/// to wherever you were — the Superset-style settings takeover.
@MainActor
struct SettingsFullScreenView: View {
    let appState: AppStateModel?
    let onBack: () -> Void

    // The Settings split view is now the top-level content (no wrapping strip),
    // so its NavigationSplitView draws exactly one sidebar top — with the traffic
    // lights over it — exactly like the main shell. "Back" lives inside the
    // sidebar's top strip (passed down via onBack). This removes the doubled
    // "fake sidebar top" that appeared in full-screen.
    var body: some View {
        SettingsRootView(appState: appState, onBack: onBack)
    }
}

@MainActor
struct BrutalistToolbarRow: View {
    @Environment(\.brutalistPalette) private var palette
    let captureMode: ActiveCaptureModel.CaptureMode
    let isMeeting: Bool
    let captureModeLabel: String
    /// True when the sidebar is currently collapsed.
    ///
    /// Drives the icon: show
    /// `sidebar.left` (i.e. "open the sidebar") when collapsed, or the
    /// `sidebar.leading` variant when expanded so the user can collapse it.
    let showSidebarToggle: Bool
    @Binding var isInspectorVisible: Bool
    let onExpandSidebar: () -> Void

    private var dictationButtonLabel: String {
        switch captureMode {
        case .dictation: return "Stop dictation"
        case .voiceMemo: return "Stop voice memo"
        default: return "Start dictation"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            BrutalistIconButton(
                systemImage: "sidebar.left",
                accessibilityLabel: showSidebarToggle ? "Show sidebar" : "Hide sidebar"
            ) {
                onExpandSidebar()
            }
            .help(showSidebarToggle ? "Show sidebar" : "Hide sidebar")
            // Mode-aware capture button. A voice memo is a distinct capture mode,
            // so while one is recording this must say "Stop voice memo" and post
            // the voice-memo stop — posting the dictation stop runs the wrong
            // pipeline and the memo is never finalised into a transcript.
            BrutalistButton(
                dictationButtonLabel,
                kind: captureMode == .dictation || captureMode == .voiceMemo ? .primary : .ghost,
                size: .compact,
                systemImage: captureMode == .dictation || captureMode == .voiceMemo
                    ? "stop.circle.fill" : "mic.circle"
            ) {
                let name: Notification.Name
                switch captureMode {
                case .dictation: name = .traceStopDictation
                case .voiceMemo: name = .traceStopVoiceMemo
                default: name = .traceStartDictation
                }
                NotificationCenter.default.post(name: name, object: nil)
            }
            BrutalistButton(
                isMeeting ? "Stop meeting" : "Start meeting",
                kind: isMeeting ? .primary : .ghost,
                size: .compact,
                systemImage: isMeeting ? "stop.circle.fill" : "person.2.wave.2"
            ) {
                let name: Notification.Name = isMeeting ? .traceStopMeeting : .traceStartMeeting
                NotificationCenter.default.post(name: name, object: nil)
            }
            BrutalistButton(
                "Transcribe file",
                kind: .ghost,
                size: .compact,
                systemImage: "doc.badge.arrow.up"
            ) {
                NotificationCenter.default.post(name: .traceRequestTranscribeFile, object: nil)
            }
            Spacer()
            if !captureModeLabel.isEmpty {
                Text(captureModeLabel)
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.primary.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(palette.primary.color.opacity(BrutalistMetrics.accentTintOpacity))
                    )
            }
            BrutalistIconButton(
                systemImage: "sidebar.right",
                accessibilityLabel: isInspectorVisible ? "Hide inspector (⌘⌥I)" : "Show inspector (⌘⌥I)"
            ) {
                withAnimation(.easeOut(duration: 0.22)) {
                    isInspectorVisible.toggle()
                }
            }
            .help(isInspectorVisible ? "Hide inspector (⌘⌥I)" : "Show inspector (⌘⌥I)")
        }
        .padding(.horizontal, 12)
        .frame(height: kColumnTopStripHeight)
        .background(palette.bgTertiary.color)
        .overlay(
            Rectangle().fill(palette.border.color).frame(height: BrutalistMetrics.hairline),
            alignment: .bottom
        )
    }
}

/// Top strip rendered above the inspector pane.
///
/// The toolbar's inspector icon
/// is the canonical toggle — we don't repeat a close button here (that was
/// causing a "duplicate button" issue with the toolbar icon).
@MainActor
struct InspectorTopStrip: View {
    @Environment(\.brutalistPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Text("Details")
                .font(BrutalistTypography.captionEmphasis)
                .foregroundStyle(palette.fgMuted.color)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: kColumnTopStripHeight)
        .background(palette.bgTertiary.color)
        .overlay(
            Rectangle().fill(palette.border.color).frame(height: BrutalistMetrics.hairline),
            alignment: .bottom
        )
    }
}

/// Vertical 1pt-wide divider that drags to resize the inspector pane.
///
/// The hit area is wider (8pt) than the visible line so it's easy to grab,
/// and the cursor flips to the resize variant on hover.
@MainActor
struct InspectorResizeHandle: View {
    @Environment(\.brutalistPalette) private var palette
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(palette.border.color)
            .frame(width: BrutalistMetrics.hairline)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = width
                        }
                        let proposed = (dragStartWidth ?? width) - value.translation.width
                        width = max(minWidth, min(maxWidth, proposed))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
    }
}

@MainActor
public struct SidebarView: View {
    @Environment(\.brutalistPalette) private var palette
    @Binding public var selection: SidebarSelection
    @Bindable public var projects: ProjectsViewModel

    // Project CRUD presentation state (BAS-23).
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newColor = "#ff3300"
    @State private var renameChip: ProjectChip?
    @State private var renameText = ""
    @State private var settingsChip: ProjectChip?
    @State private var deleteChip: ProjectChip?

    public init(
        selection: Binding<SidebarSelection>,
        projects: ProjectsViewModel
    ) {
        self._selection = selection
        self.projects = projects
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topStrip
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Projects", showAdd: true) {
                        newName = ""
                        newColor = "#ff3300"
                        showCreate = true
                    }
                    ForEach(projects.chips) { chip in
                        projectRow(chip)
                        if chip.isExpanded {
                            projectSubRows(chip)
                        }
                    }
                    sectionHeader("Library", showAdd: false).padding(.top, 8)
                    libraryItem(
                        name: "Inbox", symbol: "tray", count: projects.inboxCount, alertCount: true,
                        isSelected: selection == .inbox,
                        onTap: { selection = .inbox })
                    libraryItem(
                        name: "Search", symbol: "magnifyingglass", count: nil, alertCount: false,
                        isSelected: selection == .search,
                        onTap: { selection = .search })
                    libraryItem(
                        name: "All meetings", symbol: "person.2.wave.2", count: nil, alertCount: false,
                        isSelected: selection == .allMeetings,
                        onTap: { selection = .allMeetings })
                    libraryItem(
                        name: "All dictation", symbol: "mic", count: nil, alertCount: false,
                        isSelected: selection == .allDictation,
                        onTap: { selection = .allDictation })
                    libraryItem(
                        name: "All files", symbol: "doc", count: nil, alertCount: false,
                        isSelected: selection == .allFiles,
                        onTap: { selection = .allFiles })
                    libraryItem(
                        name: "All voice memos", symbol: "waveform", count: nil, alertCount: false,
                        isSelected: selection == .allVoiceMemos,
                        onTap: { selection = .allVoiceMemos })
                    libraryItem(
                        name: "Playbooks", symbol: "book", count: projects.playbookCount, alertCount: false,
                        isSelected: selection == .playbooks,
                        onTap: { selection = .playbooks })
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
            }
            // Strip SwiftUI's default translucent sidebar material; we draw our
            // own solid dark background via the parent VStack so the sidebar
            // bleeds to the window edges without the "nested rectangle" look.
            .scrollContentBackground(.hidden)
            pinnedSettings
        }
        .background(palette.bgTertiary.color)
        .sheet(isPresented: $showCreate) {
            NewProjectSheet(name: $newName, color: $newColor, error: projects.lastError) { name, color in
                let ok = await projects.create(name: name, color: color)
                if ok { showCreate = false }
                return ok
            } onCancel: {
                projects.lastError = nil
                showCreate = false
            }
        }
        .sheet(item: $settingsChip) { chip in
            ProjectSettingsView(projectID: chip.id, store: projects.projectStore) {
                Task { await projects.refresh() }
            }
        }
        .alert("Rename project", isPresented: renameIsPresented) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let chip = renameChip {
                    Task { await projects.rename(id: chip.id, to: renameText) }
                }
                renameChip = nil
            }
            Button("Cancel", role: .cancel) { renameChip = nil }
        }
        .alert("Delete “\(deleteChip?.name ?? "")”?", isPresented: deleteIsPresented) {
            Button("Delete", role: .destructive) {
                if let chip = deleteChip {
                    Task { await projects.delete(id: chip.id) }
                }
                deleteChip = nil
            }
            Button("Cancel", role: .cancel) { deleteChip = nil }
        } message: {
            Text("Its meetings, files, and voice memos become uncategorized (moved to Inbox). This can’t be undone.")
        }
    }

    private var renameIsPresented: Binding<Bool> {
        Binding(get: { renameChip != nil }, set: { if !$0 { renameChip = nil } })
    }
    private var deleteIsPresented: Binding<Bool> {
        Binding(get: { deleteChip != nil }, set: { if !$0 { deleteChip = nil } })
    }

    /// Top strip of the sidebar — empty bar that just reserves space for the
    /// macOS traffic-light overlay and visually matches the height of the
    /// content column's toolbar row so the dividers across columns align.
    ///
    /// The sidebar collapse button lives in the content toolbar (in
    /// `BrutalistToolbarRow`) and the system-injected NavigationSplitView
    /// disclosure button handles re-show when sidebar is visible.
    private var topStrip: some View {
        Rectangle()
            .fill(palette.bgTertiary.color)
            .frame(height: kColumnTopStripHeight)
    }

    private func sectionHeader(_ title: String, showAdd: Bool, onAdd: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(BrutalistTypography.captionEmphasis)
                .foregroundStyle(palette.fgMuted.color)
            Spacer()
            if showAdd {
                Button {
                    onAdd?()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.fgMuted.color)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New project")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func projectRow(_ chip: ProjectChip) -> some View {
        let isActive = (selection == .projectRoot(chip.id))
        return HStack(spacing: 8) {
            // A real button with a comfortable hit area (24×22) rather than a
            // 12 pt icon with a bare tap gesture — otherwise expanding a project
            // means hunting for a sliver of a target. The button captures its own
            // clicks, so the row's select gesture only fires off the name/body.
            Button {
                projects.toggleExpansion(of: chip.id)
            } label: {
                Image(systemName: chip.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.fgMuted.color)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(chip.isExpanded ? "Collapse" : "Expand")
            Circle()
                .fill(Color(hex: chip.indicatorColor))
                .frame(width: 8, height: 8)
                .frame(width: 16)
            Text(chip.name)
                .font(BrutalistTypography.label)
                .foregroundStyle(isActive ? palette.fg.color : palette.fgSidebar.color)
            Spacer()
            Text("\(chip.counts.total)")
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? palette.secondary.color : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = .projectRoot(chip.id) }
        .contextMenu {
            Button("Rename…") {
                renameText = chip.name
                renameChip = chip
            }
            Button("Project settings…") { settingsChip = chip }
            Divider()
            Button("Delete…", role: .destructive) { deleteChip = chip }
        }
    }

    private func projectSubRows(_ chip: ProjectChip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            subItem(
                category: .meetings, projectId: chip.id, name: "Meetings", count: chip.counts.meetings,
                symbol: "person.2.wave.2")
            subItem(
                category: .voiceMemos, projectId: chip.id, name: "Voice memos", count: chip.counts.voiceMemos,
                symbol: "waveform")
            subItem(
                category: .dictation, projectId: chip.id, name: "Dictation", count: chip.counts.dictations,
                symbol: "mic")
            subItem(category: .files, projectId: chip.id, name: "Files", count: chip.counts.files, symbol: "doc")
        }
    }

    private func subItem(
        category: SidebarSelection.ProjectCategory, projectId: UUID, name: String, count: Int, symbol: String
    ) -> some View {
        let isActive = selection == .projectCategory(projectId, category)
        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(isActive ? palette.primary.color : palette.fgMuted.color)
                .frame(width: 16)
            Text(name)
                .font(BrutalistTypography.label)
                .foregroundStyle(isActive ? palette.fg.color : palette.fgSidebar.color)
            Spacer()
            Text("\(count)")
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
        }
        .padding(.leading, 30)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? palette.secondary.color : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = .projectCategory(projectId, category) }
    }

    private func libraryItem(
        name: String, symbol: String, count: Int?, alertCount: Bool, isSelected: Bool, onTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? palette.primary.color : palette.fgMuted.color)
                .frame(width: 16)
            Text(name)
                .font(BrutalistTypography.label)
                .foregroundStyle(isSelected ? palette.fg.color : palette.fgSidebar.color)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(alertCount ? palette.primary.color : palette.fgMuted.color)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? palette.secondary.color : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private var pinnedSettings: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(palette.fgMuted.color)
                .frame(width: 16)
            Text("Settings")
                .font(BrutalistTypography.label)
                .foregroundStyle(palette.fgSidebar.color)
            Spacer()
            Text("⌘,")
                .font(BrutalistTypography.mono10)
                .foregroundStyle(palette.fgMuted.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.bgTertiary.color)
        .contentShape(Rectangle())
        .onTapGesture { selection = .settings }
    }
}

@MainActor
public struct ContentPaneView: View {
    @Environment(\.brutalistPalette) private var palette
    public let selection: SidebarSelection
    /// Optional global app state — passed in so the in-window Settings tab can
    /// bind to the SAME AppStateModel that drives `.preferredColorScheme` at
    /// the root, rather than spinning up a throwaway instance.
    public let appState: AppStateModel?

    public init(selection: SidebarSelection, appState: AppStateModel? = nil) {
        self.selection = selection
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            contentHeader
            mainContent
        }
        .background(palette.background.color)
    }

    @ViewBuilder
    private var contentHeader: some View {
        let (title, sub, isLive) = headerInfo
        HStack(spacing: 10) {
            Text(title)
                .font(BrutalistTypography.labelEmphasis)
                .foregroundStyle(palette.fg.color)
            if !sub.isEmpty {
                Text(sub)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
            }
            Spacer()
            if isLive {
                HStack(spacing: 5) {
                    Circle().fill(palette.primary.color).frame(width: 6, height: 6)
                    Text("Live")
                        .font(BrutalistTypography.captionEmphasis)
                        .foregroundStyle(palette.primary.color)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.primary.color.opacity(0.12))
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.bgTertiary.color)
        .overlay(
            Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline),
            alignment: .bottom
        )
    }

    private var headerInfo: (String, String, Bool) {
        switch selection {
        case .inbox:
            return ("Inbox", "Captures to file into a project", false)
        case .search:
            return ("Search", "Find anything, or ask a question", false)
        case .allMeetings:
            return ("All meetings", "Across every project", false)
        case .allDictation:
            return ("All dictation", "Across every project", false)
        case .allFiles:
            return ("All files", "Transcribed files across every project", false)
        case .allVoiceMemos:
            return ("All voice memos", "Captured & synced across every project", false)
        case .playbooks:
            return ("Playbooks", "Reference folders for the coach", false)
        case .settings:
            return ("Settings", "", false)
        case .meeting:
            return ("Meeting", "Live transcript, notes, and summary", true)
        case .projectRoot:
            return ("Project", "Everything in this project", false)
        case .projectCategory(_, let cat):
            return (cat.displayName, "In this project", false)
        case .dictation:
            return ("Dictation", "Transcript", false)
        case .voiceMemo:
            return ("Voice memo", "Transcript", false)
        case .file:
            return ("File", "Transcription result", false)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch selection {
        case .playbooks: PlaybooksView(model: appState?.playbooks)
        case .inbox:
            MeetingsLibraryView(
                library: appState?.meetingLibrary,
                live: appState?.meetingLive,
                isMeetingActive: appState?.activeCapture.mode == .meeting,
                projectId: nil,
                inboxOnly: true
            )
        case .search:
            if let appState { LibrarySearchView(model: appState.librarySearch) }
        case .allMeetings:
            MeetingsLibraryView(
                library: appState?.meetingLibrary,
                live: appState?.meetingLive,
                isMeetingActive: appState?.activeCapture.mode == .meeting,
                projectId: nil
            )
        case .projectRoot(let pid):
            // Clicking a project shows its meetings (its main content) rather than
            // the live-meeting-only detail, which read as "Nothing here yet" unless
            // a meeting was in progress. Same scoped library as the Meetings sub-item.
            MeetingsLibraryView(
                library: appState?.meetingLibrary,
                live: appState?.meetingLive,
                isMeetingActive: appState?.activeCapture.mode == .meeting,
                projectId: pid.uuidString
            )
        case .allDictation:
            DictationHistoryView()
        case .meeting: MeetingDetailView(model: appState?.meetingLive)
        case .projectCategory(let pid, .meetings):
            MeetingsLibraryView(
                library: appState?.meetingLibrary,
                live: appState?.meetingLive,
                isMeetingActive: appState?.activeCapture.mode == .meeting,
                projectId: pid.uuidString
            )
        case .projectCategory(let pid, .files):
            FilesView(model: appState?.fileBatch, projectID: pid.uuidString)
        case .projectCategory(let pid, .dictation):
            DictationHistoryView(projectID: pid)
        case .projectCategory(let pid, .voiceMemos):
            VoiceMemosView(model: appState?.fileBatch, projectID: pid.uuidString)
        case .allFiles: FilesView(model: appState?.fileBatch, projectID: nil)
        case .allVoiceMemos: VoiceMemosView(model: appState?.fileBatch, projectID: nil)
        case .dictation: DictationHistoryView()
        case .voiceMemo: VoiceMemosView(model: appState?.fileBatch, projectID: nil)
        case .file: FilesView(model: appState?.fileBatch, projectID: nil)
        case .settings:
            // Settings renders full-window in MainWindowRootView.body; this branch
            // is unreachable (selection == .settings never reaches the content pane).
            EmptyView()
        }
    }
}

@MainActor
public struct MeetingDetailView: View {
    @Environment(\.brutalistPalette) private var palette
    private let model: MeetingLiveModel?

    public init(model: MeetingLiveModel?) {
        self.model = model
    }

    public var body: some View {
        if let model, model.sessionId != nil || !model.turns.isEmpty {
            MeetingLiveView(model: model)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(palette.fgMuted.color)
            Text("Nothing here yet")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
            Text("Start a meeting (⌥M) or transcribe a file (⌥F). Your captures show up here once they finish.")
                .font(BrutalistTypography.body)
                .foregroundStyle(palette.fgMuted.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                BrutalistButton("Start meeting", kind: .primary) {
                    NotificationCenter.default.post(name: .traceStartMeeting, object: nil)
                }
                BrutalistButton("Transcribe file", kind: .ghost) {
                    NotificationCenter.default.post(name: .traceRequestTranscribeFile, object: nil)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.color)
    }

}

@MainActor
public struct InspectorView: View {
    @Environment(\.brutalistPalette) private var palette
    public let selection: SidebarSelection

    public init(selection: SidebarSelection) {
        self.selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Nothing selected yet. Once you pick a capture, this shows which project it's in, the calendar event, who spoke, and how it was transcribed."
            )
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.fgMuted.color)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.bgTertiary.color)
    }
}
