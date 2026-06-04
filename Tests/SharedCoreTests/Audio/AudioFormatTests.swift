@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class AudioFormatTests: XCTestCase {

    func testCanonicalAsrFormatIs16kMonoFloat32() {
        let f = AudioFormat.canonicalASR
        XCTAssertEqual(f.sampleRate, 16_000)
        XCTAssertEqual(f.channelCount, 1)
        XCTAssertEqual(f.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(f.isInterleaved)
    }

    func testCanonicalArchiveFormatIs48kStereoInt16Interleaved() {
        let f = AudioFormat.canonicalArchive
        XCTAssertEqual(f.sampleRate, 48_000)
        XCTAssertEqual(f.channelCount, 2)
        XCTAssertEqual(f.commonFormat, .pcmFormatInt16)
        XCTAssertTrue(f.isInterleaved)
    }

    func testIsBuiltInMicNameMatches() {
        XCTAssertTrue(AudioFormat.isBuiltInMicName("MacBook Pro Microphone"))
        XCTAssertTrue(AudioFormat.isBuiltInMicName("MacBook Air Microphone"))
        XCTAssertTrue(AudioFormat.isBuiltInMicName("Built-in Microphone"))
        XCTAssertFalse(AudioFormat.isBuiltInMicName("AirPods Pro"))
        XCTAssertFalse(AudioFormat.isBuiltInMicName("USB Audio Device"))
    }
}
