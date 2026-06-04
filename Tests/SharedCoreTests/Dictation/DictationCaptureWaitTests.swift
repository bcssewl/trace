@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import SharedCore

/// Covers the headless / "Voice-for-Agents" capture path: `runOneCycle` must
/// hold the cycle open until the speaker finishes — a VAD speech-end endpoint,
/// the mic stream ending, or a timeout ceiling — instead of finalizing the
/// instant recording begins (BAS-38).
@Suite(.serialized)
struct DictationCaptureWaitTests {

    // MARK: - Test doubles

    /// A mic source the test drives by hand. Unlike `ScriptedAudioSource` (which
    /// yields its script then finishes), this stays open until `stopCapture()`,
    /// so the test can prove the controller *waits* for a VAD speech-end endpoint
    /// rather than finalizing the instant recording begins. One eager
    /// continuation (mirroring `ScriptedAudioSource`) — no per-call stream.
    actor LiveControllableAudio: PipelineAudioSource {
        nonisolated let stream: AsyncStream<AVAudioPCMBuffer>
        nonisolated let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        }

        func startCapture() async throws {}
        func stopCapture() async { continuation.finish() }
        nonisolated func buffers() -> AsyncStream<AVAudioPCMBuffer> { stream }

        /// Push buffers into the live feed.
        ///
        /// Buffered (unbounded) until the
        /// controller's VAD task consumes them, so there's no subscribe race.
        func emit(_ buffers: [AVAudioPCMBuffer]) {
            for buffer in buffers { continuation.yield(buffer) }
        }
    }

    /// One 16 kHz mono Float32 buffer whose every sample equals `amplitude`
    /// (so its RMS == `amplitude`).
    static func buffer(amplitude: Float, frames: Int = 160) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for i in 0..<frames { channel[i] = amplitude }
        return buffer
    }

    static func speech(_ count: Int) -> [AVAudioPCMBuffer] {
        (0..<count).map { _ in buffer(amplitude: 0.5) }
    }
    static func silence(_ count: Int) -> [AVAudioPCMBuffer] {
        (0..<count).map { _ in buffer(amplitude: 0) }
    }

    /// Builds a scripted controller (no audio hardware, no DB) around the given
    /// audio source.
    ///
    /// Mirrors `DictationControllerTests.makeDeps` — ephemeral mode
    /// registry, in-memory personal dictionary, no history store.
    static func makeController(
        audio: PipelineAudioSource,
        transcript: String
    ) async throws -> DictationController {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let resolver = ModeResolver(registry: registry, bundleIDProvider: { nil })
        let dictionary = PersonalDictionary(database: nil, voiceCommands: [])
        try await dictionary.bootstrap()
        let deps = ScriptedPipelineDeps(
            modeRegistry: registry,
            modeResolver: resolver,
            personalDictionary: dictionary,
            historyStore: nil,
            audio: audio,
            asr: ScriptedASR(finalText: transcript),
            cleanup: ScriptedCleanup(template: { $0.uppercased() }),
            paste: ScriptedPaste()
        )
        return DictationController(dependencies: deps)
    }

    // MARK: - Tests

    @Test func waitsForSpeechEndBeforeFinalizing() async throws {
        let audio = LiveControllableAudio()
        let controller = try await Self.makeController(audio: audio, transcript: "next instruction")

        let task = Task { try await controller.runOneCycle(mode: .toggle, timeout: .seconds(10)) }

        // Speech only so far: the VAD sees a start but no end — the cycle must
        // still be recording, not finalized.
        await audio.emit(Self.speech(4))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await controller.currentState() == .recording)

        // Trailing silence drives the VAD speech-end endpoint → finalize.
        await audio.emit(Self.silence(8))
        let result = try await task.value
        #expect(result.cleanedText == "NEXT INSTRUCTION")
    }

    @Test func timesOutWhenSpeechHasNoEndpoint() async throws {
        // Speech with no trailing silence and no stream-end → no endpoint ever,
        // so the cycle must wait and then time out (never finalize on speech).
        let audio = LiveControllableAudio()
        let controller = try await Self.makeController(audio: audio, transcript: "unused")
        let task = Task { try await controller.runOneCycle(mode: .toggle, timeout: .milliseconds(200)) }
        await audio.emit(Self.speech(4))
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func throwsOnTimeoutWhenSpeakerNeverFinishes() async throws {
        let audio = LiveControllableAudio()  // stays open, never emits → no endpoint
        let controller = try await Self.makeController(audio: audio, transcript: "unused")
        await #expect(throws: CancellationError.self) {
            _ = try await controller.runOneCycle(mode: .toggle, timeout: .milliseconds(80))
        }
    }

    @Test func finalizesWhenMicStreamEndsWithoutSpeech() async throws {
        // An empty ScriptedAudioSource ends its stream as soon as startCapture
        // delivers its (zero) buffers, so a stopped mic finalizes what was
        // captured instead of hanging to the timeout.
        let controller = try await Self.makeController(audio: ScriptedAudioSource(), transcript: "stream end")
        let result = try await controller.runOneCycle(mode: .toggle, timeout: .seconds(5))
        #expect(result.cleanedText == "STREAM END")
    }
}
