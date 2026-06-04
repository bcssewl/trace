import Foundation
import Observation
import SharedCore

/// Backs the Files and Voice Memos surfaces.
///
/// Like `MeetingLibraryModel`, the
/// disk/DB/runtime work is performed by closures the `AppRuntimeCoordinator`
/// wires in (it owns the database + `FileBatchController` + `ProcessingState`).
///
/// Two data sources are merged in the view:
/// - `records` — the durable `files` rows for the current scope (all statuses,
///   newest first). The source of truth for *which* rows exist.
/// - `live` — the in-memory `ProcessingState` snapshots for jobs processing
///   *this session*, keyed by id. Overlaid onto a record to show a live status
///   + progress bar while it's in flight. Matching is by id, so snapshots from
///   other projects/surfaces never leak into a scoped list.
@Observable
@MainActor
public final class FileBatchModel {
    /// Durable rows for the current scope, newest first.
    public var records: [FileRecord] = []
    /// Live snapshots keyed by job id (`UUID.uuidString`).
    public var live: [String: ProcessingSnapshot] = [:]
    public var isLoading = false

    /// The surface currently shown — set by the view on appear so a live update
    /// reloads the same scope rather than guessing.
    private var scopeOrigins: Set<FileBatchJob.Origin> = FileRecord.fileOrigins
    private var scopeProjectID: String?

    // Wired by the coordinator.
    public var loadRecords:
        (@MainActor (_ origins: Set<FileBatchJob.Origin>, _ projectID: String?) async -> [FileRecord])?
    public var enqueueURLs: (@MainActor (_ urls: [URL], _ projectID: String?) async -> Void)?
    public var cancelJob: (@MainActor (_ id: UUID) async -> Void)?
    public var deleteRecord: (@MainActor (_ record: FileRecord) async -> Void)?
    public var retryRecord: (@MainActor (_ record: FileRecord) async -> Void)?
    public var revealInFinder: (@MainActor (_ path: String) -> Void)?
    public var openTranscript: (@MainActor (_ record: FileRecord) -> Void)?

    public init() {}

    /// Point the model at a surface (files vs voice memos) optionally scoped to a
    /// project, and load it.
    ///
    /// Called by the view `.task`/`.onAppear`.
    public func show(origins: Set<FileBatchJob.Origin>, projectID: String?) async {
        scopeOrigins = origins
        scopeProjectID = projectID
        await refresh()
    }

    public func refresh() async {
        guard let loadRecords else { return }
        isLoading = true
        records = await loadRecords(scopeOrigins, scopeProjectID)
        isLoading = false
    }

    /// Apply the latest `ProcessingState` broadcast.
    ///
    /// The live overlay supplies
    /// status + progress for in-flight rows, so a durable reload is only needed
    /// when a row was just created (`.queued`) or finished (terminal) — those are
    /// the transitions that change the persisted row (existence / transcript path
    /// / error). Intermediate stages (extracting…writing) re-render from the
    /// overlay alone, avoiding a full `files` query on every stage tick. Wired to
    /// the coordinator's subscription.
    public func applyLive(_ snapshots: [ProcessingSnapshot]) async {
        let next = Dictionary(snapshots.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { _, new in new })
        let needsReload = next.contains { id, snap in
            snap.status != live[id]?.status && (snap.status == .queued || snap.status.isTerminal)
        }
        live = next
        if needsReload { await refresh() }
    }

    public func enqueue(_ urls: [URL]) async {
        await enqueueURLs?(urls, scopeProjectID)
    }

    public func cancel(_ id: UUID) async { await cancelJob?(id) }

    public func delete(_ record: FileRecord) async {
        await deleteRecord?(record)
        records.removeAll { $0.id == record.id }
        live[record.id] = nil
    }

    public func retry(_ record: FileRecord) async { await retryRecord?(record) }

    /// The status to render for a row: the live snapshot's status while a job is
    /// in flight this session, else the persisted status.
    public func effectiveStatus(for record: FileRecord) -> FileBatchStatus {
        if let snap = live[record.id], !snap.status.isTerminal { return snap.status }
        return record.status
    }

    /// The progress fraction to render — the live value while in flight, else the
    /// persisted status's nominal fraction.
    public func progress(for record: FileRecord) -> Double {
        if let snap = live[record.id], !snap.status.isTerminal { return snap.progressFraction }
        return record.status.progressFraction
    }

    /// Whether the row is still being worked on (drives the cancel affordance +
    /// progress bar visibility).
    public func isInFlight(_ record: FileRecord) -> Bool {
        !effectiveStatus(for: record).isTerminal
    }
}
