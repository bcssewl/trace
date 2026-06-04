import Foundation

/// Snapshot of one in-flight job for UI rendering.
///
/// Carries enough information
/// to draw a row in the batch list without round-tripping the database. A new
/// snapshot is published on every stage transition.
public struct ProcessingSnapshot: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let sourcePath: String
    public let kind: FileBatchJob.Kind
    public let origin: FileBatchJob.Origin
    public let status: FileBatchStatus
    public let progressFraction: Double
    public let updatedAt: Date
    public let errorReason: String?

    public init(
        id: UUID,
        title: String,
        sourcePath: String,
        kind: FileBatchJob.Kind,
        origin: FileBatchJob.Origin,
        status: FileBatchStatus,
        progressFraction: Double,
        updatedAt: Date,
        errorReason: String?
    ) {
        self.id = id
        self.title = title
        self.sourcePath = sourcePath
        self.kind = kind
        self.origin = origin
        self.status = status
        self.progressFraction = progressFraction
        self.updatedAt = updatedAt
        self.errorReason = errorReason
    }
}

/// Actor that tracks every job's current snapshot and broadcasts changes to
/// any number of subscribers. The first subscriber receives the current state
/// of every known job before any further updates.
public actor ProcessingState {

    private var snapshots: [UUID: ProcessingSnapshot] = [:]
    private var subscribers: [UUID: AsyncStream<[ProcessingSnapshot]>.Continuation] = [:]

    public init() {}

    /// Snapshots currently known.
    ///
    /// Snapshots already in terminal state are still
    /// included until `forget(id:)` is called.
    public func currentSnapshots() -> [ProcessingSnapshot] {
        Array(snapshots.values).sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Subscribe to all updates.
    ///
    /// The returned stream yields the full snapshot
    /// list immediately (the current state of every known job) and again on every
    /// change. Registration is synchronous on the actor, so a subscriber obtained
    /// via `await subscribe()` is guaranteed to see every broadcast that happens
    /// after the await returns — there's no attach race where an early `.queued`
    /// transition is missed. Cancelling the consumer Task auto-detaches.
    public func subscribe() -> AsyncStream<[ProcessingSnapshot]> {
        let (stream, continuation) = AsyncStream<[ProcessingSnapshot]>.makeStream()
        let subscriberID = UUID()
        subscribers[subscriberID] = continuation
        continuation.yield(currentSnapshots())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.detach(subscriberID: subscriberID) }
        }
        return stream
    }

    /// Emit a fresh snapshot for the given job.
    ///
    /// The full list is republished
    /// to every subscriber.
    public func record(_ snapshot: ProcessingSnapshot) {
        snapshots[snapshot.id] = snapshot
        broadcast()
    }

    /// Construct a snapshot for the given job in a new stage and record it.
    public func record(
        job: FileBatchJob,
        status: FileBatchStatus,
        title: String? = nil,
        now: Date = Date(),
        errorReason: String? = nil
    ) {
        let resolvedTitle = title ?? Self.defaultTitle(for: job)
        let snapshot = ProcessingSnapshot(
            id: job.id,
            title: resolvedTitle,
            sourcePath: job.sourceURL.path,
            kind: job.kind,
            origin: job.origin,
            status: status,
            progressFraction: status.progressFraction,
            updatedAt: now,
            errorReason: errorReason
        )
        record(snapshot)
    }

    /// Forget a snapshot.
    ///
    /// The UI typically calls this once the user dismisses
    /// a completed or failed row.
    public func forget(id: UUID) {
        guard snapshots.removeValue(forKey: id) != nil else { return }
        broadcast()
    }

    /// Number of jobs still in non-terminal status.
    public func inFlightCount() -> Int {
        snapshots.values.filter { !$0.status.isTerminal }.count
    }

    private func detach(subscriberID: UUID) {
        subscribers.removeValue(forKey: subscriberID)
    }

    private func broadcast() {
        let payload = currentSnapshots()
        for cont in subscribers.values {
            cont.yield(payload)
        }
    }

    private static func defaultTitle(for job: FileBatchJob) -> String {
        let stem = job.sourceURL.deletingPathExtension().lastPathComponent
        if stem.isEmpty { return "Untitled" }
        return stem
    }
}
