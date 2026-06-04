@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class AudioConverterTests: XCTestCase {

    func testConvertFloat32MonoIdentity() throws {
        let converter = try AudioConverter(
            inputFormat: AudioFormat.canonicalASR,
            outputFormat: AudioFormat.canonicalASR
        )
        let input = SyntheticBuffers.float32(
            sampleRate: 16_000,
            channelConstants: [0.25],
            frameCount: 1_600
        )
        let output = try converter.convert(input)
        XCTAssertEqual(output.format.sampleRate, 16_000)
        XCTAssertEqual(output.format.channelCount, 1)
        XCTAssertEqual(output.frameLength, 1_600)
        XCTAssertEqual(AudioBufferHelpers.rms(output), 0.25, accuracy: 1e-4)
    }

    func testDownsample48kStereoToCanonicalAsr() throws {
        guard
            let inputFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        else {
            XCTFail("format")
            return
        }
        let converter = try AudioConverter(
            inputFormat: inputFmt,
            outputFormat: AudioFormat.canonicalASR
        )
        let input = SyntheticBuffers.float32(
            sampleRate: 48_000,
            channelConstants: [0.5, 0.5],
            frameCount: 48_000
        )
        let output = try converter.convert(input)
        XCTAssertEqual(output.format.sampleRate, 16_000)
        XCTAssertEqual(output.format.channelCount, 1)
        XCTAssertGreaterThan(
            Int(output.frameLength), 14_000,
            "AVAudioConverter's low-pass filter consumes ~6% of frames as primer; this guard rejects gross under-production"
        )
        XCTAssertLessThanOrEqual(
            Int(output.frameLength), 16_032,
            "Output should not exceed naive 3:1 downsample by more than a small tail")
    }

    func testRebuildOnDriftUpdatesMeasuredRate() throws {
        guard
            let declaredFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        else {
            XCTFail("format")
            return
        }
        let converter = try AudioConverter(
            inputFormat: declaredFmt,
            outputFormat: AudioFormat.canonicalASR
        )
        XCTAssertEqual(converter.currentInputSampleRate, 48_000)
        try converter.rebuildForMeasuredRate(44_100)
        XCTAssertEqual(converter.currentInputSampleRate, 44_100)
    }

    func testConvertThrowsOnIncompatibleBuffer() throws {
        let converter = try AudioConverter(
            inputFormat: AudioFormat.canonicalASR,
            outputFormat: AudioFormat.canonicalASR
        )
        guard
            let badFmt = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            ),
            let badBuf = AVAudioPCMBuffer(pcmFormat: badFmt, frameCapacity: 100)
        else {
            XCTFail("setup")
            return
        }
        badBuf.frameLength = 100
        XCTAssertThrowsError(try converter.convert(badBuf)) { err in
            guard case TraceError.audioCaptureFailed = err else {
                XCTFail("Expected audioCaptureFailed, got \(err)")
                return
            }
        }
    }
}
