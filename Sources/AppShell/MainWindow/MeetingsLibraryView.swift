import SharedCore
import SwiftUI

/// The "All meetings" library: a browsable list of past meetings backed by
/// `MeetingLibraryModel` (which the coordinator fills from the session
/// repository), plus a read-only detail view for any one of them.
///
/// The
/// in-progress meeting, if any, appears as a "recording now" banner that opens
/// the live tri-column view.
@MainActor
struct MeetingsLibraryView: View {
    @Environment(\.brutalistPalette) private var palette
    let library: MeetingLibraryModel?
    let live: MeetingLiveModel?
    let isMeetingActive: Bool
    let projectId: String?
    /// When true this is the Inbox triage queue — it lists only uncategorised
    /// meetings and gives each row an inline "file into a project" picker so the
    /// pile can be cleared to zero.
    ///
    /// Defaults off (the normal browsable library).
    var inboxOnly: Bool = false

    private enum Route: Equatable {
        case list, live
        case saved(String)
    }
    @State private var route: Route = .list
    @State private var didAutoOpen = false

    var body: some View {
        Group {
            switch route {
            case .list:
                listView
            case .live:
                detailScaffold(titleModel: live) {
                    MeetingDetailView(model: live)
                }
            case .saved(let id):
                if let model = library?.openedModel, model.sessionId == id {
                    detailScaffold(titleModel: model) {
                        VStack(spacing: 0) {
                            projectBar(sessionId: id)
                            MeetingLiveView(model: model)
                        }
                    }
                } else {
                    detailScaffold { loadingState }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background.color)
        .task(id: taskKey) {
            if inboxOnly {
                await library?.refreshInbox()
            } else {
                await library?.refresh(projectId: projectId)
            }
            await library?.loadProjectsIfNeeded()
        }
        // Starting a meeting jumps straight to the live transcript/notes screen;
        // the user can still go Back to browse other meetings and return.
        .onAppear {
            if isMeetingActive && !didAutoOpen {
                route = .live
                didAutoOpen = true
            } else {
                consumePendingOpen(library?.pendingOpen)
            }
        }
        .onChange(of: isMeetingActive) { _, active in
            if active {
                route = .live
                didAutoOpen = true
            }
        }
        // A Library citation / hit requests an open via `pendingOpen`; consume it
        // (whether set before or after this view mounts) and route to the meeting.
        .onChange(of: library?.pendingOpen) { _, pending in
            consumePendingOpen(pending)
        }
    }

    /// Route to and hydrate a meeting requested from elsewhere (a citation / hit).
    private func consumePendingOpen(_ pending: MeetingLibraryModel.PendingOpen?) {
        guard let pending, let library else { return }
        route = .saved(pending.sessionId)
        Task {
            await library.open(sessionId: pending.sessionId)
            library.openedModel?.scrollTargetTime = pending.timestamp
            library.pendingOpen = nil
        }
    }

    // MARK: List

    /// Re-key the load `.task` so switching between the Inbox and a project view
    /// (which share one model) reliably reloads the correct scope.
    private var taskKey: String { inboxOnly ? "__inbox__" : (projectId ?? "__all__") }

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if inboxOnly { inboxIntro }
                HStack(alignment: .firstTextBaseline) {
                    Text(inboxOnly ? "To file" : "All meetings")
                        .font(BrutalistTypography.title)
                        .foregroundStyle(palette.fg.color)
                    Spacer()
                    Text("\(library?.meetings.count ?? 0)")
                        .font(BrutalistTypography.mono11)
                        .foregroundStyle(palette.fgMuted.color)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                if isMeetingActive { liveBanner }

                if let meetings = library?.meetings, !meetings.isEmpty {
                    ForEach(meetings, id: \.sessionId) { meetingRow($0) }
                } else if library?.isLoading == true {
                    loadingState.padding(.top, 50)
                } else if inboxOnly {
                    inboxZeroState
                } else {
                    emptyState
                }
            }
        }
    }

    /// One line of orientation atop the Inbox so it reads as a triage queue, not a
    /// search box — the thing the page used to be confused with.
    private var inboxIntro: some View {
        Text("Captures that haven’t been filed into a project yet. File each one to clear your inbox.")
            .font(BrutalistTypography.caption)
            .foregroundStyle(palette.fgMuted.color)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
    }

    /// Inline "file into a project" picker shown on each Inbox row — the core
    /// triage action, so it sits right on the row instead of hidden in a menu.
    private func inboxAssignMenu(_ sessionId: String) -> some View {
        Menu {
            ForEach(library?.projects ?? []) { project in
                Button(project.name) { Task { await library?.assign(sessionId, to: project.id) } }
            }
            if library?.projects.isEmpty == true {
                Text("No projects yet")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text("File")
                    .font(BrutalistTypography.caption)
            }
            .foregroundStyle(palette.primary.color)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Keep the row's own tap (open meeting) from firing when using the menu.
        .onTapGesture {}
    }

    private var inboxZeroState: some View {
        BrutalistEmptyState(
            symbol: "tray",
            title: "Inbox zero",
            detail: "Nothing to file. New meetings that aren’t auto-sorted into a project land here."
        )
    }

    private var liveBanner: some View {
        BrutalistBanner(
            kind: .info,
            title: "Recording now",
            detail: "Open the live meeting",
            actionTitle: "Open",
            action: { route = .live }
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func meetingRow(_ meta: SessionMetadata) -> some View {
        Button {
            route = .saved(meta.sessionId)
            Task { await library?.open(meta) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.fgMuted.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.title?.isEmpty == false ? meta.title! : "Untitled meeting")
                        .font(BrutalistTypography.label)
                        .foregroundStyle(palette.fg.color)
                    Text(Self.dateLine(meta))
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                }
                Spacer()
                if inboxOnly {
                    inboxAssignMenu(meta.sessionId)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.fgMuted.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(
                Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Move to project") {
                Button("Inbox") { Task { await library?.assign(meta.sessionId, to: nil) } }
                ForEach(library?.projects ?? []) { project in
                    Button(project.name) { Task { await library?.assign(meta.sessionId, to: project.id) } }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { Task { await library?.delete(meta.sessionId) } }
        }
    }

    // MARK: Detail scaffold (back to list)

    @ViewBuilder
    private func detailScaffold<Content: View>(
        titleModel: MeetingLiveModel? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BrutalistButton(
                    "All meetings",
                    kind: .ghost,
                    size: .compact,
                    systemImage: "chevron.left"
                ) {
                    // Flush any un-debounced edits before tearing the view down, so
                    // editing a saved meeting's notes/title + hitting Back can't lose them.
                    let editedModel = library?.openedModel
                    route = .list
                    library?.closeDetail()
                    Task {
                        await editedModel?.persistNotes()
                        await editedModel?.commitTitle()
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(
                Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline),
                alignment: .bottom
            )
            // Click-to-edit meeting title (BAS-29) — the title isn't shown elsewhere
            // in the detail, so this both surfaces and lets you rename it.
            if let titleModel {
                EditableMeetingTitle(model: titleModel) {
                    Task {
                        await titleModel.commitTitle()
                        await library?.refresh(projectId: projectId)
                    }
                }
            }
            content()
        }
    }

    /// Project picker shown atop a saved meeting — files it into a project (or
    /// Inbox).
    ///
    /// Picking sets a sticky manual override so auto-categorization never
    /// overrides the user's choice.
    @ViewBuilder
    private func projectBar(sessionId: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(palette.fgMuted.color)
            BrutalistChip("Project")
            Menu {
                Button("Inbox") {
                    Task { await library?.assign(sessionId, to: nil) }
                }
                if let projects = library?.projects, !projects.isEmpty {
                    Divider()
                    ForEach(projects) { project in
                        Button(project.name) {
                            Task { await library?.assign(sessionId, to: project.id) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(library?.projectName(for: sessionId) ?? "Inbox")
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fg.color)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(palette.fgMuted.color)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(
            Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline),
            alignment: .bottom
        )
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }.padding(.vertical, 40)
    }

    private var emptyState: some View {
        BrutalistEmptyState(
            symbol: "tray",
            title: "No meetings yet",
            detail: "Start a meeting with ⌥M. When it ends it's saved here with its notes, summary, and transcript."
        )
    }

    static func dateLine(_ meta: SessionMetadata) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · h:mm a"
        var line = formatter.string(from: meta.startedAt)
        if let ended = meta.endedAt {
            let minutes = max(1, Int(ended.timeIntervalSince(meta.startedAt) / 60))
            line += " · \(minutes) min"
        }
        return line
    }
}

/// The meeting title in the detail header, rendered as an editable field — click
/// it and type to rename (BAS-29).
///
/// Commits on Return and on focus loss; the parent
/// persists to `meetings.title` and refreshes the list.
private struct EditableMeetingTitle: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable var model: MeetingLiveModel
    let onCommit: @MainActor () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Untitled meeting", text: $model.title)
            .textFieldStyle(.plain)
            .font(BrutalistTypography.title)
            .foregroundStyle(palette.fg.color)
            .focused($focused)
            .onSubmit { onCommit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onCommit() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .help("Click to rename this meeting")
    }
}
