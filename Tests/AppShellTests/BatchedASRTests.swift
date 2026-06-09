@preconcurrency import AVFoundation
import Foundation
import XCTest
import os.lock

@testable import AppShell
@testable import SharedCore

/// BatchedASR cycle isolation + crash-spool lifecycle.
///
/// The pre-actor implementation had an admitted data race: the consume task,
/// `beginCycle()`, and `finishCycle()` all mutated `collectedSamples` /
/// `consumeTask` / `streamingActive` without synchronisation. These tests pin
/// the contract of the fix: each `finishCycle` sees exactly its own cycle's
/// samples, stale tasks can't pollute the next cycle, and the on-disk spool is
/// created/deleted/kept at the right lifecycle points.
final class BatchedASRTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "batched-asr-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    // MARK: cycle isolation

    func testFinishCycleSeesExactlyItsOwnSamples() async throws {
        let backend = CapturingBackend(text: "take one")
        let feeder = AudioFeeder()
        let asr = BatchedASR(backend: backend, subscribeAudio: { feeder.makeStream() })

        try await asr.beginCycle()
        feeder.yield(makeBuffer([Float](repeating: 0.1, count: 1_000)))
        feeder.yield(makeBuffer([Float](repeating: 0.2, count: 500)))
        let text = try await asr.finishCycle()

        XCTAssertEqual(text, "take one")
        let calls = await backend.transcribeCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.count, 1_500)
    }

    func testSecondCycleNeverContainsFirstCyclesAudio() async throws {
        let backend = CapturingBackend(text: "t")
        let feeder = AudioFeeder()
        let asr = BatchedASR(backend: backend, subscribeAudio: { feeder.makeStream() })

        try await asr.beginCycle()
        feeder.yield(makeBuffer([Float](repeating: 0.1, count: 2_000)))
        _ = try await asr.finishCycle()

        try await asr.beginCycle()
        feeder.yield(makeBuffer([Float](repeating: 0.9, count: 300)))
        _ = try await asr.finishCycle()

        let calls = await backend.transcribeCalls()
        XCTAssertEqual(calls.map(\.count), [2_000, 300])
        // Cycle 2's audio is cycle 2's audio — not a mix.
        XCTAssertEqual(calls.last?.allSatisfy { $0 == 0.9 }, true)
    }

    /// An aborted cycle (begin → begin, no finish — the runOneCycle-timeout
    /// shape) must not leak its consume task or its samples into the next one.
    func testAbandonedCycleCannotPolluteTheNext() async throws {
        let backend = CapturingBackend(text: "t")
        let feeder = AudioFeeder()
        let asr = BatchedASR(backend: backend, subscribeAudio: { feeder.makeStream() })

        try await asr.beginCycle()
        feeder.yield(makeBuffer([Float](repeating: 0.5, count: 4_000)))
        // Give the first consume task time to ingest, then abandon the cycle.
        try await Task.sleep(nanoseconds: 100_000_000)

        try await asr.beginCycle()
        // The first cycle's stream keeps yielding after the new cycle began —
        // a stale task / stale stream must be ignored.
        feeder.yieldToAll(makeBuffer([Float](repeating: 0.5, count: 4_000)))
        feeder.yield(makeBuffer([Float](repeating: 0.7, count: 100)))
        _ = try await asr.finishCycle()

        let calls = await backend.transcribeCalls()
        XCTAssertEqual(calls.count, 1)
        let samples = try XCTUnwrap(calls.first)
        // Exactly cycle 2's own audio: the 100-sample 0.7 chunk plus the
        // 4 000-sample 0.5 chunk delivered to ITS stream after it began —
        // and none of the 4 000 samples the abandoned first cycle ingested.
        XCTAssertEqual(samples.count, 4_100)
        XCTAssertEqual(samples.filter { $0 == 0.7 }.count, 100)
        XCTAssertEqual(samples.filter { $0 == 0.5 }.count, 4_000)
    }

    func testCancelCycleDropsAudioAndNeverTranscribes() async throws {
        let backend = CapturingBackend(text: "t")
        let feeder = AudioFeeder()
        let asr = BatchedASR(
            backend: backend, subscribeAudio: { feeder.makeStream() }, spoolDirectory: tempDir)

        try await asr.beginCycle()
        feeder.yield(makeBuffer([Float](repeating: 0.4, count: 8_000)))
        try await Task.sleep(nanoseconds: 100_000_000)
        await asr.cancelCycle()

        let calls = await backend.transcribeCalls()
        XCTAssertTrue(calls.isEmpty)
        // Deliberate cancel discards the crash spool — nothing to recover.
        XCTAssertTrue(DictationSpoolStore.orphanedSpools(in: tempDir).isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(leftovers.isEmpty, "cancel must remove spool files: \(leftovers)")
    }

    // MARK: crash-spool lifecycle

    func testSpoolWrittenDuringCaptureAndDeletedOnCleanFinish() async throws {
        let backend = CapturingBackend(text: "done")
        let feeder = AudioFeeder()
        let asr = BatchedASR(
            backend: backend, subscribeAudio: { feeder.makeStream() }, spoolDirectory: tempDir)

        try await asr.beginCycle()
        feeder.yield(makeBuffer([Float](repeating: 0.3, count: 16_000)))
        try await Task.sleep(nanoseconds: 150_000_000)

        // Mid-capture: the audio is already on disk (crash insurance)…
        let midFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(midFiles.contains { $0.hasSuffix(".pcm") }, "spool must exist during capture")
        // …but is NOT an orphan (it's registered active).
        XCTAssertTrue(DictationSpoolStore.orphanedSpools(in: tempDir).isEmpty)

        _ = try await asr.finishCycle()
        let afterFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(afterFiles.isEmpty, "clean finish must delete the spool: \(afterFiles)")
    }

    func testSpoolKeptWhenTranscriptionFails() async throws {
        let backend = CapturingBackend(text: "x", failure: TraceError.asrInferenceFailed(
            engine: "stub", reason: "model exploded"))
        let feeder = AudioFeeder()
        let asr = BatchedASR(
            backend: backend, subscribeAudio: { feeder.makeStream() }, spoolDirectory: tempDir)

        try await asr.beginCycle()
        feeder.yield(makeBuffer([Float](repeating: 0.6, count: 16_000)))
        try await Task.sleep(nanoseconds: 150_000_000)
        do {
            _ = try await asr.finishCycle()
            XCTFail("expected transcription failure")
        } catch {
            // expected
        }

        // The audio survives as a recoverable orphan.
        let orphans = DictationSpoolStore.orphanedSpools(in: tempDir)
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first!.duration, 1.0, accuracy: 0.05)
    }

    func testTranscribeBatchRunsBackendDirectly() async throws {
        let backend = CapturingBackend(text: "recovered text")
        let asr = BatchedASR(backend: backend, subscribeAudio: { AudioFeeder().makeStream() })
        let text = try await asr.transcribeBatch([0.1, 0.2, 0.3])
        XCTAssertEqual(text, "recovered text")
        let calls = await backend.transcribeCalls()
        XCTAssertEqual(calls.first?.count, 3)
    }
}

// MARK: - doubles

/// Hand-driven replacement for `MicCapture.subscribe`: each `makeStream()`
/// returns a fresh stream; `yield` feeds the most recent subscriber (the
/// current cycle), `yieldToAll` feeds every stream ever vended (to simulate a
/// stale cycle's stream still being live).
private final class AudioFeeder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[AsyncStream<AVAudioPCMBuffer>.Continuation]>(initialState: [])

    func makeStream() -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        lock.withLock { $0.append(continuation) }
        return stream
    }

    func yield(_ buffer: AVAudioPCMBuffer) {
        let latest = lock.withLock { $0.last }
        latest?.yield(buffer)
    }

    func yieldToAll(_ buffer: AVAudioPCMBuffer) {
        let all = lock.withLock { Array($0) }
        for continuation in all { continuation.yield(buffer) }
    }
}

private actor CapturingBackend: TranscriptionBackend {
    nonisolated let displayName = "Capturing"
    private let text: String
    private let failure: Error?
    private var calls: [[Float]] = []

    init(text: String, failure: Error? = nil) {
        self.text = text
        self.failure = failure
    }

    func checkStatus() async -> BackendStatus { .ready }

    func prepare(
        onStatus: @escaping @Sendable (BackendStatus) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        onStatus(.loaded)
        onProgress(1)
    }

    func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
        calls.append(samples)
        if let failure { throw failure }
        return text
    }

    nonisolated func transcribeStream(_ buffer: AVAudioPCMBuffer) async throws -> ASRDelta? { nil }

    func clearModelCache() async {}

    func transcribeCalls() -> [[Float]] { calls }
}
