@preconcurrency import AVFoundation
import Foundation
import os

public actor AudioPipeline {

    public let micRouter: StreamRouter
    public let sysRouter: StreamRouter

    private let mic: MicCapture
    private let sys: SystemAudioCapture
    private var micPumpTask: Task<Void, Never>?
    private var sysPumpTask: Task<Void, Never>?

    public init(
        micVoiceProcessing: Bool = false,
        systemAudioTestHooks: SystemAudioCapture.TestHooks? = nil
    ) {
        self.micRouter = StreamRouter()
        self.sysRouter = StreamRouter()
        self.mic = MicCapture(voiceProcessingEnabled: micVoiceProcessing)
        self.sys = SystemAudioCapture(testHooks: systemAudioTestHooks)
    }

    public func startMic() throws {
        try mic.start()
        let router = micRouter
        let stream = mic.buffers
        if micPumpTask == nil {
            micPumpTask = Task {
                for await buf in stream {
                    await router.publish(buf)
                }
                await router.finish()
            }
        }
    }

    public func stopMic() {
        mic.stop()
        micPumpTask?.cancel()
        micPumpTask = nil
    }

    public func startSystem() throws {
        try sys.start()
        let router = sysRouter
        let stream = sys.buffers
        if sysPumpTask == nil {
            sysPumpTask = Task {
                for await buf in stream {
                    await router.publish(buf)
                }
                await router.finish()
            }
        }
    }

    public func stopSystem() {
        sys.stop()
        sysPumpTask?.cancel()
        sysPumpTask = nil
    }

    public nonisolated func subscribeMic(label: String) -> AsyncStream<AVAudioPCMBuffer> {
        micRouter.subscribe(label: label)
    }

    public nonisolated func subscribeSystem(label: String) -> AsyncStream<AVAudioPCMBuffer> {
        sysRouter.subscribe(label: label)
    }

    public func stopAll() {
        stopMic()
        stopSystem()
    }

    public func diagnostics() -> (mic: MicCapture.Diagnostics, sys: SystemAudioCapture.Diagnostics) {
        (mic.diagnostics(), sys.diagnostics())
    }
}
