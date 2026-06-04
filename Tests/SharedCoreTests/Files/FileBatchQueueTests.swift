import XCTest

@testable import SharedCore

final class FileBatchQueueTests: XCTestCase {

    private func makeJob(_ name: String, priority: Int = 0) -> FileBatchJob {
        FileBatchJob.makeIfSupported(
            url: URL(fileURLWithPath: "/tmp/\(name).m4a"),
            origin: .dragDrop, priority: priority
        )!
    }

    func testFIFOOrderingAtEqualPriority() async throws {
        let queue = FileBatchQueue(capacity: 8)
        let a = makeJob("a")
        let b = makeJob("b")
        let c = makeJob("c")
        try await queue.enqueue(a)
        try await queue.enqueue(b)
        try await queue.enqueue(c)

        let first = await queue.dequeue()
        let second = await queue.dequeue()
        let third = await queue.dequeue()
        XCTAssertEqual(first?.id, a.id)
        XCTAssertEqual(second?.id, b.id)
        XCTAssertEqual(third?.id, c.id)
    }

    func testHigherPriorityJumpsAheadButTiesBreakFIFO() async throws {
        let queue = FileBatchQueue(capacity: 8)
        let low1 = makeJob("low1", priority: 0)
        let low2 = makeJob("low2", priority: 0)
        let highA = makeJob("highA", priority: 10)
        let highB = makeJob("highB", priority: 10)

        try await queue.enqueue(low1)
        try await queue.enqueue(highA)
        try await queue.enqueue(low2)
        try await queue.enqueue(highB)

        let order = await [
            queue.dequeue()?.id,
            queue.dequeue()?.id,
            queue.dequeue()?.id,
            queue.dequeue()?.id,
        ]
        XCTAssertEqual(order, [highA.id, highB.id, low1.id, low2.id])
    }

    func testCapacityEnforcedAndDuplicateRejected() async throws {
        let queue = FileBatchQueue(capacity: 2)
        let a = makeJob("a")
        let b = makeJob("b")
        let c = makeJob("c")
        try await queue.enqueue(a)
        try await queue.enqueue(b)

        do {
            try await queue.enqueue(c)
            XCTFail("Expected FileBatchQueue.Error.full when capacity is exhausted")
        } catch let err as FileBatchQueue.Error {
            XCTAssertEqual(err, .full)
        }

        _ = await queue.dequeue()
        do {
            try await queue.enqueue(a)  // same id again — duplicate after removal is allowed since a is gone
            // Should succeed
        } catch {
            XCTFail("Re-enqueue after dequeue must succeed: \(error)")
        }
    }

    func testEnqueueDetectsDuplicateIds() async throws {
        let queue = FileBatchQueue(capacity: 4)
        let a = makeJob("a")
        try await queue.enqueue(a)
        do {
            try await queue.enqueue(a)
            XCTFail("Expected duplicate id rejection")
        } catch let err as FileBatchQueue.Error {
            if case .duplicate(let id) = err {
                XCTAssertEqual(id, a.id)
            } else {
                XCTFail("Wrong queue error: \(err)")
            }
        }
    }

    func testCancellationRemovesQueuedJobImmediately() async throws {
        let queue = FileBatchQueue(capacity: 4)
        let a = makeJob("a")
        let b = makeJob("b")
        try await queue.enqueue(a)
        try await queue.enqueue(b)
        await queue.cancel(id: a.id)

        let next = await queue.dequeue()
        XCTAssertEqual(next?.id, b.id)
        let cancelled = await queue.consumeCancellation(id: a.id)
        XCTAssertTrue(cancelled)
    }

    func testInFlightCancellationIsObservable() async throws {
        let queue = FileBatchQueue(capacity: 4)
        let a = makeJob("a")
        try await queue.enqueue(a)
        let dequeued = await queue.dequeue()
        XCTAssertEqual(dequeued?.id, a.id)

        // Job is now in-flight from the controller's perspective. Cancellation
        // arrives later; the controller polls between stages.
        await queue.cancel(id: a.id)
        let before = await queue.isCancelled(id: a.id)
        XCTAssertTrue(before)

        let consumed = await queue.consumeCancellation(id: a.id)
        XCTAssertTrue(consumed)
        let after = await queue.isCancelled(id: a.id)
        XCTAssertFalse(after)
    }

    func testSnapshotMatchesDequeueOrder() async throws {
        let queue = FileBatchQueue(capacity: 4)
        let low = makeJob("low", priority: 0)
        let high = makeJob("high", priority: 5)
        try await queue.enqueue(low)
        try await queue.enqueue(high)

        let snapshot = await queue.snapshotIds()
        XCTAssertEqual(snapshot, [high.id, low.id])
    }

    func testTryEnqueueSilentlyFailsOnCapacityBound() async throws {
        let queue = FileBatchQueue(capacity: 1)
        let added = await queue.tryEnqueue(makeJob("a"))
        XCTAssertTrue(added)
        let again = await queue.tryEnqueue(makeJob("b"))
        XCTAssertFalse(again)
    }
}
