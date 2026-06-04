import Foundation

/// In-memory queue actor backing the file batch pipeline.
///
/// Ordering rules:
/// 1. Higher `priority` wins over lower priority.
/// 2. Ties broken by FIFO sequence (insertion order).
///
/// The queue enforces a soft capacity. `enqueue` throws `Error.full` once the
/// capacity is hit so callers can surface a recovery action instead of silently
/// dropping work.
///
/// Cancellation lives on the queue: an item still queued is removed and never
/// dequeued. Items already dequeued (in-flight in the controller) are signaled
/// via the cancellation set, which the controller polls between stages.
public actor FileBatchQueue {

    public enum Error: Swift.Error, Sendable, Equatable {
        case full
        case duplicate(UUID)
    }

    private struct Entry: Sendable {
        let sequence: UInt64
        let job: FileBatchJob
    }

    private let capacity: Int
    private var entries: [Entry] = []
    private var nextSequence: UInt64 = 0
    private var cancellations: Set<UUID> = []

    public init(capacity: Int = 256) {
        precondition(capacity > 0, "FileBatchQueue capacity must be > 0")
        self.capacity = capacity
    }

    /// Enqueues a job.
    ///
    /// Throws `.full` if at capacity, `.duplicate` if a job
    /// with the same id is already queued.
    public func enqueue(_ job: FileBatchJob) throws {
        guard entries.count < capacity else { throw Error.full }
        guard !entries.contains(where: { $0.job.id == job.id }) else {
            throw Error.duplicate(job.id)
        }
        cancellations.remove(job.id)
        entries.append(Entry(sequence: nextSequence, job: job))
        nextSequence &+= 1
        sortByPriorityThenSequence()
    }

    /// Convenience that swallows the duplicate / full errors.
    ///
    /// Returns whether
    /// the job was actually added.
    @discardableResult
    public func tryEnqueue(_ job: FileBatchJob) -> Bool {
        do {
            try enqueue(job)
            return true
        } catch {
            return false
        }
    }

    /// Removes and returns the next-due job.
    ///
    /// Returns `nil` when empty.
    public func dequeue() -> FileBatchJob? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst().job
    }

    /// Marks a job for cancellation.
    ///
    /// If still queued, it is removed in place.
    /// If already in-flight, the controller picks up the flag between stages
    /// via `isCancelled(_:)`.
    public func cancel(id: UUID) {
        cancellations.insert(id)
        entries.removeAll(where: { $0.job.id == id })
    }

    /// Whether the given id has been cancelled.
    ///
    /// Used by `FileBatchController`
    /// to fast-fail between pipeline stages without holding the queue actor.
    public func isCancelled(id: UUID) -> Bool {
        cancellations.contains(id)
    }

    /// Returns the cancellation flag and clears it.
    ///
    /// Called once a job reaches
    /// a terminal state so the cancellation memory does not grow unbounded.
    public func consumeCancellation(id: UUID) -> Bool {
        let wasCancelled = cancellations.contains(id)
        cancellations.remove(id)
        return wasCancelled
    }

    /// Returns ids in the order they would be dequeued.
    ///
    /// Mostly used by tests
    /// and the UI snapshot path.
    public func snapshotIds() -> [UUID] {
        entries.map(\.job.id)
    }

    /// Snapshot of currently-queued jobs.
    ///
    /// Order matches dequeue order.
    public func snapshot() -> [FileBatchJob] {
        entries.map(\.job)
    }

    public var count: Int { entries.count }
    public var capacityRemaining: Int { capacity - entries.count }

    private func sortByPriorityThenSequence() {
        entries.sort { lhs, rhs in
            if lhs.job.priority != rhs.job.priority {
                return lhs.job.priority > rhs.job.priority
            }
            return lhs.sequence < rhs.sequence
        }
    }
}
