@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

/// `SystemAudioArchiver` writes the meeting's remote (system) audio to a CAF
/// file during capture — the prerequisite BAS-10 calls out, since the live
/// pipeline otherwise discards the audio and the offline diarization pass would
/// have nothing to re-diarize.
///
/// These tests confirm the samples land on disk and
/// read back faithfully (it's a lossless 16 kHz mono float archive).
final class SystemAudioArchiverTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sys-archive-\(UUID().uuidString)")
            .appendingPathComponent("sys.caf")
    }

    func testWrittenSamplesReadBackAtSameLengthAndValues() throws {
        let url = tempURL()
        let archiver = try SystemAudioArchiver(url: url)
        let chunkA: [Float] = [0.0, 0.25, -0.25, 0.5, -0.5]
        let chunkB: [Float] = [0.1, -0.1, 0.2, -0.2]
        try archiver.append(chunkA)
        try archiver.append(chunkB)
        archiver.finish()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, Int64(chunkA.count + chunkB.count))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)

        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buffer)
        let readBack = Array(
            UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        )
        let expected = chunkA + chunkB
        XCTAssertEqual(readBack.count, expected.count)
        for (got, want) in zip(readBack, expected) {
            XCTAssertEqual(got, want, accuracy: 1e-4)
        }
    }

    func testFramesWrittenTracksAppendedSamples() throws {
        let url = tempURL()
        let archiver = try SystemAudioArchiver(url: url)
        XCTAssertEqual(archiver.framesWritten, 0)
        try archiver.append([Float](repeating: 0, count: 800))
        try archiver.append([Float](repeating: 0, count: 1_200))
        XCTAssertEqual(archiver.framesWritten, 2_000)
        archiver.finish()
    }

    func testEmptyAppendIsANoOp() throws {
        let url = tempURL()
        let archiver = try SystemAudioArchiver(url: url)
        try archiver.append([])
        XCTAssertEqual(archiver.framesWritten, 0)
        archiver.finish()
    }

    func testInitCreatesParentDirectory() throws {
        let url = tempURL()  // parent dir does not exist yet
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let archiver = try SystemAudioArchiver(url: url)
        try archiver.append([0.1, 0.2])
        archiver.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
