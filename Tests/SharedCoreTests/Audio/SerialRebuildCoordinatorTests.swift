import XCTest
import os

@testable import SharedCore

final class SerialRebuildCoordinatorTests: XCTestCase {

    /// N rebuild requests fired while one is executing collapse into exactly
    /// ONE trailing rebuild — never N.
    func testOverlappingRequestsCoalesceToOneTrailingRebuild() {
        let coordinator = SerialRebuildCoordinator(label: "test.coalesce")
        let executions = OSAllocatedUnfairLock(initialState: 0)
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)

        // First rebuild: blocks until released, so further requests arrive
        // while it is IN FLIGHT.
        let scheduledFirst = coordinator.requestRebuild {
            executions.withLock { $0 += 1 }
            firstStarted.signal()
            releaseFirst.wait()
        }
        XCTAssertTrue(scheduledFirst)
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)

        // Ten requests during the in-flight rebuild: the first schedules the
        // trailing pass, the rest coalesce into it.
        var scheduledCount = 0
        for _ in 0..<10 {
            if coordinator.requestRebuild({ executions.withLock { $0 += 1 } }) {
                scheduledCount += 1
            }
        }
        XCTAssertEqual(scheduledCount, 1, "only one trailing rebuild may be scheduled")

        releaseFirst.signal()
        // Barrier: an exclusive body runs only after every queued rebuild
        // block has finished, so the queue has settled when it returns.
        coordinator.withExclusiveControl {}
        // 1 (held) + exactly 1 trailing — never one per request.
        XCTAssertEqual(executions.withLock { $0 }, 2)
    }

    /// Rebuild bodies and exclusive-control bodies never overlap: max observed
    /// concurrency is 1 under concurrent hammering from many threads.
    func testRebuildAndExclusiveControlNeverOverlap() {
        let coordinator = SerialRebuildCoordinator(label: "test.exclusion")
        let active = OSAllocatedUnfairLock(initialState: 0)
        let maxActive = OSAllocatedUnfairLock(initialState: 0)

        @Sendable func enter() {
            let now = active.withLock { value -> Int in
                value += 1
                return value
            }
            maxActive.withLock { $0 = max($0, now) }
            usleep(2_000)
            active.withLock { $0 -= 1 }
        }

        let group = DispatchGroup()
        for i in 0..<40 {
            group.enter()
            DispatchQueue.global().async {
                if i % 2 == 0 {
                    coordinator.requestRebuild { enter() }
                } else {
                    coordinator.withExclusiveControl { enter() }
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        // Flush any still-queued rebuild bodies.
        coordinator.withExclusiveControl {}
        XCTAssertEqual(maxActive.withLock { $0 }, 1, "bodies must be strictly serialised")
    }

    func testIsRebuildPendingOrActiveReflectsLifecycle() {
        let coordinator = SerialRebuildCoordinator(label: "test.pending")
        XCTAssertFalse(coordinator.isRebuildPendingOrActive)

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        coordinator.requestRebuild {
            started.signal()
            release.wait()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(coordinator.isRebuildPendingOrActive, "active rebuild must report busy")
        release.signal()
        coordinator.withExclusiveControl {}
        XCTAssertFalse(coordinator.isRebuildPendingOrActive)
    }

    func testWithExclusiveControlReturnsValueAndRethrows() {
        let coordinator = SerialRebuildCoordinator(label: "test.rethrow")
        XCTAssertEqual(coordinator.withExclusiveControl { 42 }, 42)

        struct Boom: Error {}
        XCTAssertThrowsError(
            try coordinator.withExclusiveControl { throw Boom() }
        ) { error in
            XCTAssertTrue(error is Boom)
        }
    }
}
