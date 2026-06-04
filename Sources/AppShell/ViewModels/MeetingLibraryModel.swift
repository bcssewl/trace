import Foundation
import Observation
import SharedCore

/// Backs the "All meetings" library — the browsable list of past meetings and
/// the currently-open one.
///
/// The view binds to this; the actual disk/DB reads are
/// performed by closures the `AppRuntimeCoordinator` wires in (it owns the
/// database + markdown root), mirroring how `MeetingLiveModel.notesSink` is wired.
@Observable
@MainActor
public final class MeetingLibraryModel {
    /// Past meetings, most-recent first (metadata only — cheap to list).
    public var meetings: [SessionMetadata] = []
    /// The meeting currently opened — a `MeetingLiveModel` hydrated from disk, so
    /// it renders in the SAME tri-column view as a live meeting.
    public var openedModel: MeetingLiveModel?
    /// A one-shot request to open a meeting (optionally at a timestamp), set by a
    /// Library citation / keyword hit.
    ///
    /// The meetings view consumes it on appear so
    /// the open survives the view-mount race; cleared once handled. A one-shot so
    /// normal sidebar navigation to "All meetings" still shows the list.
    public var pendingOpen: PendingOpen?
    public var isLoading = false

    public struct PendingOpen: Equatable, Sendable {
        public let sessionId: String
        public let timestamp: Double?
        public init(sessionId: String, timestamp: Double?) {
            self.sessionId = sessionId
            self.timestamp = timestamp
        }
    }

    /// Wired by the coordinator. `loadList(projectId)` returns the meeting index;
    /// `loadMeeting` hydrates one meeting into a `MeetingLiveModel` from disk.
    public var loadList: (@MainActor (String?) async -> [SessionMetadata])?
    /// Wired by the coordinator: meetings not filed into any project (the Inbox
    /// triage queue).
    ///
    /// Kept separate from `loadList` so the Inbox shows only
    /// uncategorised captures, not the whole library.
    public var loadInbox: (@MainActor () async -> [SessionMetadata])?
    public var loadMeeting: (@MainActor (SessionMetadata) async -> MeetingLiveModel?)?

    /// Projects the user can file a meeting into (id + name), loaded lazily.
    public var projects: [ProjectInfo] = []
    /// Wired by the coordinator: list projects, and assign a meeting to a project
    /// (nil = Inbox).
    ///
    /// Assignment sets the sticky manual-override flag.
    public var loadProjects: (@MainActor () async -> [ProjectInfo])?
    public var assignProjectAction: (@MainActor (_ sessionId: String, _ projectId: String?) async -> Void)?
    /// Wired by the coordinator: permanently delete a meeting.
    public var deleteAction: (@MainActor (_ sessionId: String) async -> Void)?
    /// The scope the list currently shows, so a reassignment / delete reloads the
    /// same view rather than jumping back to "all".
    private enum Scope: Equatable {
        case all(String?)
        case inbox
    }
    private var scope: Scope = .all(nil)

    public init() {}

    public func refresh(projectId: String? = nil) async {
        scope = .all(projectId)
        guard let loadList else { return }
        isLoading = true
        meetings = await loadList(projectId)
        isLoading = false
    }

    /// Load only the uncategorised meetings — the Inbox triage queue.
    public func refreshInbox() async {
        scope = .inbox
        guard let loadInbox else { return }
        isLoading = true
        meetings = await loadInbox()
        isLoading = false
    }

    /// Reload whichever scope is currently shown.
    private func reloadCurrentScope() async {
        switch scope {
        case .all(let projectId): await refresh(projectId: projectId)
        case .inbox: await refreshInbox()
        }
    }

    public func open(_ meta: SessionMetadata) async {
        guard let loadMeeting else { return }
        openedModel = await loadMeeting(meta)
    }

    /// Open a meeting by session id (from a Library citation / hit).
    ///
    /// Resolves the
    /// metadata from the current list, falling back to a full (unscoped) reload
    /// when the target isn't in the currently-filtered view.
    public func open(sessionId: String) async {
        if let meta = meetings.first(where: { $0.sessionId == sessionId }) {
            await open(meta)
            return
        }
        guard let loadList else { return }
        let all = await loadList(nil)
        if let meta = all.first(where: { $0.sessionId == sessionId }) {
            await open(meta)
        }
    }

    public func closeDetail() {
        openedModel = nil
    }

    /// Load the project list (for the per-meeting project picker) if wired.
    public func loadProjectsIfNeeded() async {
        guard let loadProjects else { return }
        projects = await loadProjects()
    }

    /// Assign a meeting to a project (nil = Inbox) and reload the current view.
    public func assign(_ sessionId: String, to projectId: String?) async {
        await assignProjectAction?(sessionId, projectId)
        await reloadCurrentScope()
    }

    public func delete(_ sessionId: String) async {
        await deleteAction?(sessionId)
        if openedModel?.sessionId == sessionId { openedModel = nil }
        await reloadCurrentScope()
    }

    /// Display name of the project a listed meeting is filed under ("Inbox" if none).
    public func projectName(for sessionId: String) -> String {
        guard let pid = meetings.first(where: { $0.sessionId == sessionId })?.projectId,
            let match = projects.first(where: { $0.id == pid })
        else { return "Inbox" }
        return match.name
    }
}

/// Lightweight project descriptor for the meetings library's project picker.
public struct ProjectInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
