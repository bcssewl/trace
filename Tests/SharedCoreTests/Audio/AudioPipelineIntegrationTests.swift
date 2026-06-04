@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class AudioPipelineIntegrationTests: XCTestCase {

    func testTwoConsumersOnSystemStreamReceiveInjectedBuffers() async throws {
        let hooks = SystemAudioCapture.TestHooks(
            watchdogThreshold: 10.0,
            simulatedRunning: { false }
        )
        let pipeline = AudioPipeline(systemAudioTestHooks: hooks)
        let asr = pipeline.subscribeSystem(label: "asr")
        let diar = pipeline.subscribeSystem(label: "diarizer")

        try await Task.sleep(for: .milliseconds(20))

        let router = await pipeline.sysRouter
        for i in 0..<3 {
            let buf = SyntheticBuffers.float32(
                channelConstants: [Float(i + 1) * 0.1], frameCount: 16)
            await router.publish(buf)
        }
        await router.finish()

        var asrCount = 0
        for await _ in asr { asrCount += 1 }
        var diarCount = 0
        for await _ in diar { diarCount += 1 }

        XCTAssertEqual(asrCount, 3)
        XCTAssertEqual(diarCount, 3)
    }
}
