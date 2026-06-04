import XCTest

@testable import SharedCore

final class ProcessingStateTests: XCTestCase {

    private func sampleJob(_ name: String = "clip") -> FileBatchJob {
        FileBatchJob.makeIfSupported(
            url: URL(fileURLWithPath: "/tmp/\(name).m4a"),
            origin: .dragDrop
        )!
    }

    func testRecordingProducesSnapshotByID() async {
        let state = ProcessingState()
        let job = sampleJob()
        await state.record(job: job, status: .queued)
        let snapshots = await state.currentSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.id, job.id)
        XCTAssertEqual(snapshots.first?.status, .queued)
    }

    func testForgetRemovesSnapshot() async {
        let state = ProcessingState()
        let job = sampleJob()
        await state.record(job: job, status: .completed)
        await state.forget(id: job.id)
        let snapshots = await state.currentSnapshots()
        XCTAssertEqual(snapshots, [])
    }

    func testInFlightCountIgnoresTerminalStatuses() async {
        let state = ProcessingState()
        let a = sampleJob("a")
        let b = sampleJob("b")
        let c = sampleJob("c")
        await state.record(job: a, status: .transcribing)
        await state.record(job: b, status: .completed)
        await state.record(job: c, status: .failed, errorReason: "boom")
        let count = await state.inFlightCount()
        XCTAssertEqual(count, 1)
    }

    func testSubscribeReceivesInitialAndSubsequentSnapshots() async throws {
        let state = ProcessingState()
        let initialJob = sampleJob("initial")
        await state.record(job: initialJob, status: .queued)

        let stream = await state.subscribe()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(first?.first?.id, initialJob.id)

        let secondJob = sampleJob("second")
        await state.record(job: secondJob, status: .transcribing)
        let second = await iterator.next()
        XCTAssertEqual(second?.count, 2)
    }

    func testSnapshotOrderingByUpdatedAt() async {
        let state = ProcessingState()
        let a = sampleJob("a")
        let b = sampleJob("b")
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        await state.record(job: a, status: .queued, now: baseDate)
        await state.record(job: b, status: .queued, now: baseDate.addingTimeInterval(5))
        let snapshots = await state.currentSnapshots()
        XCTAssertEqual(snapshots.map(\.id), [a.id, b.id])
    }
}
