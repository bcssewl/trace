import Foundation
import Observation
import SharedCore

public struct ProjectChip: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let indicatorColor: String
    public let counts: ProjectChildCounts
    public var isExpanded: Bool

    public init(
        id: UUID, name: String, indicatorColor: String,
        counts: ProjectChildCounts, isExpanded: Bool
    ) {
        self.id = id
        self.name = name
        self.indicatorColor = indicatorColor
        self.counts = counts
        self.isExpanded = isExpanded
    }
}

@Observable
@MainActor
public final class ProjectsViewModel {
    public var chips: [ProjectChip] = []
    public var inboxCount: Int = 0
    public var playbookCount: Int = 0
    public var loading: Bool = false
    /// Surfaced to the create/rename UI when an operation fails (e.g. a
    /// duplicate name); nil on success.
    public var lastError: String?

    private let store: ProjectStore?

    public init(store: ProjectStore? = nil) {
        self.store = store
        self.chips = []
        self.inboxCount = 0
        self.playbookCount = 0
    }

    /// Expose the store so the per-project settings editor can read/write a
    /// project's full record (overrides, coach config, template).
    public var projectStore: ProjectStore? { store }

    public func refresh() async {
        guard let store else { return }
        loading = true
        defer { loading = false }
        // Preserve which projects are expanded across a refresh. Otherwise any
        // refresh (e.g. the meeting library reloading when you open a project's
        // Meetings) rebuilds every chip collapsed, snapping open projects shut.
        let expandedIDs = Set(chips.filter(\.isExpanded).map(\.id))
        do {
            let records = try await store.list()
            // One bulk query for every project's counts instead of N×4.
            let countsByProject = (try? await store.allChildCounts()) ?? [:]
            let loaded: [ProjectChip] = records.map { record in
                ProjectChip(
                    id: record.id, name: record.name, indicatorColor: record.indicatorColor,
                    counts: countsByProject[record.id]
                        ?? ProjectChildCounts(meetings: 0, dictations: 0, voiceMemos: 0, files: 0),
                    isExpanded: expandedIDs.contains(record.id)
                )
            }
            chips = loaded
            inboxCount = (try? await store.inboxMeetingCount()) ?? 0
            playbookCount = (try? await store.playbookCount()) ?? 0
        } catch {
            Loggers.bootstrap.error("ProjectsViewModel.refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func toggleExpansion(of id: UUID) {
        guard let idx = chips.firstIndex(where: { $0.id == id }) else { return }
        chips[idx].isExpanded.toggle()
    }

    // MARK: - CRUD (BAS-23)

    /// Create a project.
    ///
    /// Returns true on success; sets `lastError` and returns
    /// false on failure (e.g. empty or duplicate name).
    @discardableResult
    public func create(name: String, color: String) async -> Bool {
        guard let store else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Give the project a name."
            return false
        }
        do {
            _ = try await store.create(name: trimmed, indicatorColor: color)
            lastError = nil
            await refresh()
            return true
        } catch {
            lastError = Self.friendlyError(error, name: trimmed)
            return false
        }
    }

    @discardableResult
    public func rename(id: UUID, to name: String) async -> Bool {
        guard let store else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Give the project a name."
            return false
        }
        do {
            try await store.rename(id: id, name: trimmed)
            lastError = nil
            await refresh()
            return true
        } catch {
            lastError = Self.friendlyError(error, name: trimmed)
            return false
        }
    }

    /// Delete a project (children are detached via `ON DELETE SET NULL` /
    /// `CASCADE` in the schema).
    ///
    /// Posts `.traceProjectOverridesChanged` so the
    /// coordinator drops the deleted project's router overrides.
    public func delete(id: UUID) async {
        guard let store else { return }
        do {
            try await store.delete(id: id)
            lastError = nil
            NotificationCenter.default.post(name: .traceProjectOverridesChanged, object: nil)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func name(for id: UUID) -> String? {
        chips.first { $0.id == id }?.name
    }

    /// Turns a raw store error into something a person can act on — the common
    /// case is the UNIQUE name constraint.
    ///
    /// Shared with the project settings editor.
    static func friendlyError(_ error: Error, name: String) -> String {
        let text = "\(error)".lowercased()
        if text.contains("unique") || text.contains("constraint") {
            return "A project named “\(name)” already exists."
        }
        return error.localizedDescription
    }
}
