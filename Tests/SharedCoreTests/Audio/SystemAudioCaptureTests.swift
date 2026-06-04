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

    func testAllZeroWatchdogTriggersRebuildInTestMode() async throws {
        let rebuildCount = OSAllocatedUnfairLock(initialState: 0)
        let capture = SystemAudioCapture(
            testHooks: SystemAudioCapture.TestHooks(
                watchdogThreshold: 0.5,
                simulatedRunning: { true }
            ))
        capture.setOnRebuild { rebuildCount.withLock { $0 += 1 } }

        for _ in 0..<20 {
            capture.injectForTesting(SyntheticBuffers.silence(channels: 1, frameCount: 480))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertGreaterThanOrEqual(rebuildCount.withLock { $0 }, 0)
    }
}
