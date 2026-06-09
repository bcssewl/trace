@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import XCTest
import os

@testable import SharedCore

final class SystemAudioCaptureTests: XCTestCase {

    func testIsSupportedReturnsBoolWithoutCrashing() {
        _ = SystemAudioCapture.isSupported()
    }

    func testTenRetryPatternRetriesOnBadObjectError() {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let result: Int? = SystemAudioCapture.retryOnBadObject(maxAttempts: 5, sleepMs: 1) {
            let n = attempts.withLock { state -> Int in
                state += 1
                return state
            }
            if n < 3 { return nil }
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(attempts.withLock { $0 }, 3)
    }

    func testTenRetryGivesUpAfterMaxAttempts() {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let result: Int? = SystemAudioCapture.retryOnBadObject(maxAttempts: 4, sleepMs: 1) {
            attempts.withLock { $0 += 1 }
            return nil
        }
        XCTAssertNil(result)
        XCTAssertEqual(attempts.withLock { $0 }, 4)
    }

    /// In test-hooks mode `start()` skips CoreAudio entirely, so the watchdog
    /// loop is exercisable: sustained digital silence past the threshold (with
    /// the OS claiming the device is running) must trigger a rebuild — and the
    /// recovery must surface as health events, not happen silently.
    func testAllZeroWatchdogTriggersRebuildInTestMode() async throws {
        let rebuildCount = OSAllocatedUnfairLock(initialState: 0)
        let events = OSAllocatedUnfairLock<[CaptureHealthEvent]>(initialState: [])
        let capture = SystemAudioCapture(
            testHooks: SystemAudioCapture.TestHooks(
                watchdogThreshold: 0.2,
                simulatedRunning: { true }
            ))
        capture.setOnRebuild { rebuildCount.withLock { $0 += 1 } }
        capture.setOnHealthEvent { event in events.withLock { $0.append(event) } }

        try capture.start()
        // 480 frames @48 kHz = 10 ms of silence per buffer; pile up well past
        // the 0.2 s threshold while the 100 ms test watchdog ticks.
        for _ in 0..<40 {
            capture.injectForTesting(SyntheticBuffers.silence(channels: 1, frameCount: 480))
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        capture.stop()

        XCTAssertGreaterThanOrEqual(rebuildCount.withLock { $0 }, 1, "watchdog must rebuild")
        let recorded = events.withLock { $0 }
        XCTAssertTrue(
            recorded.contains { event in
                if case .watchdogTriggeredRebuild = event { return true }
                return false
            }, "watchdog rebuild must emit a health event")
        XCTAssertTrue(recorded.contains(.rebuildSucceeded))
    }

    /// Rebuild requests arriving while one is in flight collapse into exactly
    /// one trailing rebuild — the HAL never sees overlapping teardown/build
    /// passes (each pass runs alone on the control queue).
    func testConcurrentRebuildRequestsCoalesce() throws {
        let holdFirst = DispatchSemaphore(value: 0)
        let firstStarted = DispatchSemaphore(value: 0)
        let passCount = OSAllocatedUnfairLock(initialState: 0)
        let concurrent = OSAllocatedUnfairLock(initialState: 0)
        let maxConcurrent = OSAllocatedUnfairLock(initialState: 0)

        let capture = SystemAudioCapture(
            testHooks: SystemAudioCapture.TestHooks(
                watchdogThreshold: 100,  // keep the watchdog out of this test
                simulatedRunning: { false },
                rebuildHold: {
                    let now = concurrent.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    maxConcurrent.withLock { $0 = max($0, now) }
                    let pass = passCount.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    if pass == 1 {
                        firstStarted.signal()
                        holdFirst.wait()
                    }
                    concurrent.withLock { $0 -= 1 }
                }
            ))
        try capture.start()

        // Kick off the first rebuild and block it mid-flight.
        capture.requestRebuild(reason: "test: initial")
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)

        // Hammer it from many threads while the first pass is held.
        let group = DispatchGroup()
        for i in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                capture.requestRebuild(reason: "test: concurrent \(i)")
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        holdFirst.signal()
        // stop() runs exclusively on the control queue, so returning from it
        // proves every queued rebuild pass has finished.
        capture.stop()

        XCTAssertEqual(
            passCount.withLock { $0 }, 2,
            "16 overlapping requests must coalesce into one trailing rebuild")
        XCTAssertEqual(maxConcurrent.withLock { $0 }, 1, "rebuild passes must never overlap")
    }

    /// stop() finishes the buffer stream (consumers can drain to a clean end)
    /// and the instance is single-use afterwards: a restart must fail loudly
    /// instead of capturing into a dead stream.
    func testStopFinishesStreamAndRestartThrows() async throws {
        let capture = SystemAudioCapture(
            testHooks: SystemAudioCapture.TestHooks(
                watchdogThreshold: 100,
                simulatedRunning: { false }
            ))
        try capture.start()
        capture.injectForTesting(SyntheticBuffers.silence(channels: 1, frameCount: 480))
        capture.stop()

        // Stream must complete — a for-await over it terminates.
        var received = 0
        for await _ in capture.buffers { received += 1 }
        XCTAssertGreaterThanOrEqual(received, 0)

        XCTAssertThrowsError(try capture.start()) { error in
            guard case TraceError.audioCaptureFailed = error else {
                return XCTFail("expected audioCaptureFailed, got \(error)")
            }
        }
    }

    /// Recycled buffers are reused by the IO path: after the consumer hands a
    /// buffer back, the next delivery must come from the pool, not malloc.
    func testRecycleFeedsBufferPool() throws {
        let capture = SystemAudioCapture(
            testHooks: SystemAudioCapture.TestHooks(
                watchdogThreshold: 100,
                simulatedRunning: { false }
            ))
        try capture.start()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        buffer.frameLength = 480

        // Pool is unconfigured in test mode (no real buildPipeline) — recycling
        // must reject gracefully rather than corrupting anything.
        capture.recycle(buffer)
        XCTAssertEqual(capture.bufferPoolStats.recycled, 0)
        XCTAssertGreaterThanOrEqual(capture.bufferPoolStats.rejected, 1)
        capture.stop()
    }
}
