@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class AudioBufferPoolTests: XCTestCase {

    private func makeFormat(rate: Double = 48_000, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    func testAcquireReturnsPreallocatedBufferAndRecycleReusesSameInstance() {
        let pool = AudioBufferPool(maxPooledBuffers: 4)
        let format = makeFormat()
        pool.rebuild(format: format, capacityFrames: 1_024, preallocate: 2)
        XCTAssertEqual(pool.availableCount, 2)

        guard let first = pool.acquire(frameCount: 512, format: format) else {
            return XCTFail("expected a pooled buffer")
        }
        XCTAssertEqual(pool.availableCount, 1)

        pool.recycle(first)
        XCTAssertEqual(pool.availableCount, 2)

        let second = pool.acquire(frameCount: 512, format: format)
        XCTAssertTrue(second === first, "LIFO pool must hand back the recycled instance")

        let stats = pool.stats
        XCTAssertEqual(stats.hits, 2)
        XCTAssertEqual(stats.recycled, 1)
        XCTAssertEqual(stats.misses, 0)
    }

    func testAcquireMissesWhenEmptyOrTooSmallOrWrongFormat() {
        let pool = AudioBufferPool(maxPooledBuffers: 4)
        let format = makeFormat()

        // Unconfigured pool: miss.
        XCTAssertNil(pool.acquire(frameCount: 64, format: format))

        pool.rebuild(format: format, capacityFrames: 256, preallocate: 1)
        // Requested frames exceed pooled capacity: miss.
        XCTAssertNil(pool.acquire(frameCount: 512, format: format))
        // Format mismatch: miss.
        XCTAssertNil(pool.acquire(frameCount: 64, format: makeFormat(rate: 44_100)))
        // Matching request: hit.
        XCTAssertNotNil(pool.acquire(frameCount: 64, format: format))
        // Now empty: miss.
        XCTAssertNil(pool.acquire(frameCount: 64, format: format))
        XCTAssertEqual(pool.stats.misses, 4)
        XCTAssertEqual(pool.stats.hits, 1)
    }

    func testRecycleRejectsWrongFormatFullPoolAndDoubleRecycle() {
        let pool = AudioBufferPool(maxPooledBuffers: 2)
        let format = makeFormat()
        pool.rebuild(format: format, capacityFrames: 256, preallocate: 0)

        // Wrong format rejected.
        let stereo = AVAudioPCMBuffer(pcmFormat: makeFormat(channels: 2), frameCapacity: 256)!
        pool.recycle(stereo)
        XCTAssertEqual(pool.availableCount, 0)

        // Undersized buffer rejected (would break the capacity invariant).
        let small = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        pool.recycle(small)
        XCTAssertEqual(pool.availableCount, 0)

        // Matching buffers admitted up to the cap.
        let a = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        pool.recycle(a)
        pool.recycle(a)  // double recycle of the same instance ignored
        XCTAssertEqual(pool.availableCount, 1)
        pool.recycle(b)
        pool.recycle(c)  // over cap → dropped
        XCTAssertEqual(pool.availableCount, 2)
        XCTAssertEqual(pool.stats.rejected, 4)
    }

    func testRebuildOnFormatChangeDropsOldBuffers() {
        let pool = AudioBufferPool(maxPooledBuffers: 4)
        let oldFormat = makeFormat(rate: 48_000)
        pool.rebuild(format: oldFormat, capacityFrames: 512, preallocate: 3)
        let oldBuffer = pool.acquire(frameCount: 128, format: oldFormat)
        XCTAssertNotNil(oldBuffer)

        let newFormat = makeFormat(rate: 44_100)
        pool.rebuild(format: newFormat, capacityFrames: 512, preallocate: 2)
        XCTAssertEqual(pool.availableCount, 2)
        // Old-format acquire now misses; old buffer can't be recycled back in.
        XCTAssertNil(pool.acquire(frameCount: 128, format: oldFormat))
        pool.recycle(oldBuffer!)
        XCTAssertEqual(pool.availableCount, 2, "old-format buffer must be rejected after rebuild")
    }

    func testDrainEmptiesThePool() {
        let pool = AudioBufferPool(maxPooledBuffers: 4)
        let format = makeFormat()
        pool.rebuild(format: format, capacityFrames: 256, preallocate: 4)
        XCTAssertEqual(pool.availableCount, 4)
        pool.drain()
        XCTAssertEqual(pool.availableCount, 0)
        XCTAssertNil(pool.acquire(frameCount: 64, format: format))
    }

    /// Steady state: with a cooperating consumer (recycle after each acquire),
    /// a long run never misses after warm-up — i.e. no per-callback allocation.
    func testSteadyStateLoopNeverMissesWhenConsumerRecycles() {
        let pool = AudioBufferPool(maxPooledBuffers: 4)
        let format = makeFormat()
        pool.rebuild(format: format, capacityFrames: 1_024, preallocate: 4)

        for _ in 0..<1_000 {
            guard let buffer = pool.acquire(frameCount: 480, format: format) else {
                return XCTFail("steady-state acquire must never miss")
            }
            buffer.frameLength = 480
            pool.recycle(buffer)
        }
        XCTAssertEqual(pool.stats.misses, 0)
        XCTAssertEqual(pool.stats.hits, 1_000)
    }
}
