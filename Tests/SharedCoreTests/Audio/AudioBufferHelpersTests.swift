@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class AudioBufferHelpersTests: XCTestCase {

    func testExtractChannelZeroPreservesAmplitude() throws {
        let (input, expectedRMS) = SyntheticBuffers.sineMonoOnChannel(
            zeroOfChannels: 3,
            amplitude: 0.5
        )
        let mono = try AudioBufferHelpers.extractChannelZero(input)
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.frameLength, input.frameLength)

        let rms = AudioBufferHelpers.rms(mono)
        XCTAssertEqual(
            rms, expectedRMS, accuracy: 0.01,
            "Channel-0 extraction must preserve sine RMS within 1%")
    }

    func testAveragingThreeChannelsAttenuatesRoughly3x() throws {
        let (input, channel0RMS) = SyntheticBuffers.sineMonoOnChannel(
            zeroOfChannels: 3,
            amplitude: 0.5
        )
        let averaged = AudioBufferHelpers.averageAllChannelsForTesting(input)
        let avgRMS = AudioBufferHelpers.rms(averaged)
        XCTAssertLessThan(
            avgRMS, channel0RMS / 2,
            "Averaging must attenuate well below half — confirming why channel-0-only matters")
    }

    func testRmsOfSilenceIsZero() {
        let silence = SyntheticBuffers.silence(channels: 1, frameCount: 480)
        XCTAssertEqual(AudioBufferHelpers.rms(silence), 0, accuracy: 1e-7)
    }

    func testRmsOfConstantOneIsOne() {
        let buf = SyntheticBuffers.float32(channelConstants: [1.0], frameCount: 480)
        XCTAssertEqual(AudioBufferHelpers.rms(buf), 1.0, accuracy: 1e-5)
    }

    func testExtractChannelZeroOnMonoIsIdentity() throws {
        let mono = SyntheticBuffers.float32(channelConstants: [0.42], frameCount: 100)
        let out = try AudioBufferHelpers.extractChannelZero(mono)
        XCTAssertEqual(out.format.channelCount, 1)
        XCTAssertEqual(out.floatChannelData?[0][0], 0.42)
    }
}
