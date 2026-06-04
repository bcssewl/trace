@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class StreamRouterTests: XCTestCase {

    func testTwoConsumersReceiveSameBuffer() async throws {
        let router = StreamRouter()
        let stream1 = router.subscribe(label: "asr")
        let stream2 = router.subscribe(label: "diarizer")

        try await Task.sleep(for: .milliseconds(20))

        for i in 0..<5 {
            let buf = SyntheticBuffers.float32(
                channelConstants: [Float(i)],
                frameCount: 64
            )
            await router.publish(buf)
        }
        await router.finish()

        var n1 = 0
        for await _ in stream1 { n1 += 1 }
        var n2 = 0
        for await _ in stream2 { n2 += 1 }

        XCTAssertEqual(n1, 5)
        XCTAssertEqual(n2, 5)
    }

    func testLateSubscriberOnlySeesFutureBuffers() async throws {
        let router = StreamRouter()
        await router.publish(SyntheticBuffers.float32(channelConstants: [0.1], frameCount: 8))
        let stream = router.subscribe(label: "late")
        try await Task.sleep(for: .milliseconds(20))

        Task {
            await router.publish(SyntheticBuffers.float32(channelConstants: [0.2], frameCount: 8))
            await router.finish()
        }
        var iter = stream.makeAsyncIterator()
        let buf = await iter.next()
        XCTAssertEqual(
            buf?.floatChannelData?[0][0], 0.2,
            "Late subscriber should only see buffers published after subscribe()")
    }

    func testFinishDrainsAllConsumers() async throws {
        let router = StreamRouter()
        let stream = router.subscribe(label: "drain")
        try await Task.sleep(for: .milliseconds(20))

        Task {
            await router.publish(SyntheticBuffers.float32(channelConstants: [1.0], frameCount: 8))
            await router.finish()
        }
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 1)
    }

    func testSubscribeAfterFinishReturnsTerminatedStream() async throws {
        let router = StreamRouter()
        await router.finish()
        let stream = router.subscribe(label: "late-postfinish")
        var iter = stream.makeAsyncIterator()
        let buf = await iter.next()
        XCTAssertNil(buf)
    }
}
