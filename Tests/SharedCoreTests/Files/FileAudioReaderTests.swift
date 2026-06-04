@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class FileAudioReaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeTestCAF(
        sampleRate: Double, channels: Int, durationSeconds: Double, frequency: Double = 440
    ) throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
        let url = tempDir.appendingPathComponent("audio-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw TraceError.audioCaptureFailed(reason: "alloc")
        }
        buffer.frameLength = frames
        if let ptr = buffer.floatChannelData {
            for ch in 0..<channels {
                for i in 0..<Int(frames) {
                    let phase = 2.0 * .pi * frequency * Double(i) / sampleRate
                    ptr[ch][i] = 0.5 * Float(sin(phase))
                }
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testReadDecodesAt16kMonoFloat32WithReasonableDuration() async throws {
        let url = try writeTestCAF(sampleRate: 48_000, channels: 2, durationSeconds: 1.0)
        let reader = FileAudioReader()
        let result = try await reader.read(url: url)

        // Duration ~ 1 s ± rounding.
        XCTAssertEqual(result.durationMs, 1_000, accuracy: 5)
        // Output should be close to 16 000 samples (AVAudioConverter primer drops ~6%).
        XCTAssertGreaterThan(result.samples.count, 14_000)
        XCTAssertLessThan(result.samples.count, 16_400)
    }

    func testReadHandlesShortFile() async throws {
        let url = try writeTestCAF(sampleRate: 48_000, channels: 1, durationSeconds: 0.05)
        let reader = FileAudioReader()
        let result = try await reader.read(url: url)
        XCTAssertEqual(result.durationMs, 50, accuracy: 5)
        XCTAssertGreaterThan(result.samples.count, 700)
        XCTAssertLessThan(result.samples.count, 850)
    }

    func testReadThrowsForMissingFile() async {
        let reader = FileAudioReader()
        do {
            _ = try await reader.read(url: tempDir.appendingPathComponent("missing.m4a"))
            XCTFail("Missing file should throw")
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
