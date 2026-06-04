import Foundation
import Observation
import SharedCore

/// Backs Library → Playbooks: the per-project reference folders the Coach grounds
/// its cards on.
///
/// Disk/DB work (the `PlaybookStore` + the knowledge-base indexer)
/// is performed by closures the `AppRuntimeCoordinator` wires in, mirroring how
/// `MeetingLibraryModel` is wired (the coordinator owns the database + router).
@Observable
@MainActor
public final class PlaybooksModel {
    /// Projects the user can attach playbook folders to (playbooks are per-project).
    public var projects: [ProjectInfo] = []
    public var selectedProjectId: String?
    /// Folders attached to the selected project.
    public var folders: [PlaybookFolder] = []
    public var isLoading = false
    public var isIndexing = false
    /// Transient status line (e.g. "Indexed 42 chunks").
    public var statusLine: String?

    // Wired by the coordinator.
    public var loadProjects: (@MainActor () async -> [ProjectInfo])?
    public var loadFolders: (@MainActor (_ projectId: String) async -> [PlaybookFolder])?
    public var addFolder: (@MainActor (_ projectId: String, _ url: URL) async -> Void)?
    public var removeFolder: (@MainActor (_ folderId: UUID) async -> Void)?
    /// Re-index the whole playbook corpus (all projects).
    ///
    /// It's global, not
    /// per-project — the playbook prune spans every playbook row, so a per-project
    /// pass would drop the other projects' chunks. Returns the chunk count.
    public var indexCorpus: (@MainActor () async -> Int)?

    public init() {}

    /// Load projects and the selected project's folders (selecting the first
    /// project on first load).
    public func load() async {
        guard let loadProjects else { return }
        projects = await loadProjects()
        if selectedProjectId == nil || !projects.contains(where: { $0.id == selectedProjectId }) {
            selectedProjectId = projects.first?.id
        }
        await refreshFolders()
    }

    public func select(_ projectId: String?) async {
        selectedProjectId = projectId
        statusLine = nil
        await refreshFolders()
    }

    public func refreshFolders() async {
        guard let selectedProjectId, let loadFolders else {
            folders = []
            return
        }
        isLoading = true
        folders = await loadFolders(selectedProjectId)
        isLoading = false
    }

    public func add(_ url: URL) async {
        guard let selectedProjectId, let addFolder else { return }
        await addFolder(selectedProjectId, url)
        await refreshFolders()
        // Index on add (BAS-18) so the new folder is immediately groundable — the
        // status line then reflects whether the embedding model was reachable.
        await index()
    }

    public func remove(_ folderId: UUID) async {
        guard let removeFolder else { return }
        await removeFolder(folderId)
        await refreshFolders()
    }

    /// Index the playbook corpus into the RAG store so the Coach can ground on it.
    ///
    /// Embeddings route to the configured provider (Ollama `nomic-embed-text` by
    /// default), so this needs that provider reachable.
    public func index() async {
        guard let indexCorpus else { return }
        isIndexing = true
        statusLine = "Indexing…"
        let count = await indexCorpus()
        isIndexing = false
        statusLine =
            count > 0
            ? "Indexed \(count) chunk\(count == 1 ? "" : "s") — the coach can now ground on these."
            : "Nothing indexed. Check the folder has .md/.txt files and the embedding model is reachable."
        await refreshFolders()
    }

    public func selectedProjectName() -> String {
        projects.first(where: { $0.id == selectedProjectId })?.name ?? "—"
    }
}
