@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class VoiceMemoCaptureTests: XCTestCase {

    /// Mic stub that emits a configurable sequence of synthetic buffers.
    final class StubMic: MicrophoneBufferProducing, @unchecked Sendable {
        let buffers: AsyncStream<AVAudioPCMBuffer>
        let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
        let sampleRate: Double
        let format: AVAudioFormat
        private let started = SyncBool(initial: false)
        private let stopped = SyncBool(initial: false)

        init(sampleRate: Double = 48_000, format: AVAudioFormat) {
            self.sampleRate = sampleRate
            self.format = format
            let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            self.buffers = stream
            self.continuation = continuation
        }

        func subscribe() -> AsyncStream<AVAudioPCMBuffer> { buffers }

        func start() throws {
            started.value = true
        }

        func stop() {
            guard !stopped.value else { return }
            stopped.value = true
            continuation.finish()
        }

        var wasStarted: Bool { started.value }
        var wasStopped: Bool { stopped.value }

        func emit(frameCount: AVAudioFrameCount, value: Float = 0.25) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return
            }
            buffer.frameLength = frameCount
            if let ptr = buffer.floatChannelData {
                for ch in 0..<Int(format.channelCount) {
                    for i in 0..<Int(frameCount) {
                        ptr[ch][i] = value
                    }
                }
            }
            continuation.yield(buffer)
        }
    }

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-memo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func float32Format(sampleRate: Double = 48_000, channels: Int = 1) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
    }

    func testStartStopProducesVoiceMemoJob() async throws {
        let format = float32Format()
        let mic = StubMic(format: format)
        let capture = VoiceMemoCapture(mic: mic, outputDirectory: tempDir)

        try await capture.start()
        // Emit roughly 0.1 s of audio at 48 kHz mono — converter will downsample
        // to canonicalArchive (48k stereo Int16) leaving frame counts roughly equal.
        mic.emit(frameCount: 4_800)
        mic.emit(frameCount: 4_800)
        let job = try await capture.stop()

        XCTAssertEqual(job.kind, .voiceMemo)
        XCTAssertEqual(job.origin, .voiceMemoCapture)
        XCTAssertEqual(job.asrTaskOverride, .voiceMemo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.sourceURL.path))
        XCTAssertTrue(mic.wasStarted)
        XCTAssertTrue(mic.wasStopped)
    }

    func testCancelDeletesPartialOutput() async throws {
        let format = float32Format()
        let mic = StubMic(format: format)
        let capture = VoiceMemoCapture(mic: mic, outputDirectory: tempDir)

        try await capture.start()
        mic.emit(frameCount: 4_800)
        await capture.cancel()

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(contents.filter { $0.hasPrefix("voice-memo-") }, [])
        XCTAssertTrue(mic.wasStopped)
    }

    func testStartTwiceWithoutStopThrows() async throws {
        let format = float32Format()
        let mic = StubMic(format: format)
        let capture = VoiceMemoCapture(mic: mic, outputDirectory: tempDir)

        try await capture.start()
        do {
            try await capture.start()
            XCTFail("Concurrent start should throw")
        } catch let err as TraceError {
            if case .audioCaptureFailed = err {
                // expected
            } else {
                XCTFail("Wrong error: \(err)")
            }
        }
        await capture.cancel()
    }

    func testStopBeforeStartThrows() async {
        let format = float32Format()
        let mic = StubMic(format: format)
        let capture = VoiceMemoCapture(mic: mic, outputDirectory: tempDir)

        do {
            _ = try await capture.stop()
            XCTFail("stop without start should throw")
        } catch let err as TraceError {
            if case .audioCaptureFailed = err {
                // expected
            } else {
                XCTFail("Wrong error: \(err)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }
}
