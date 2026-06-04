@preconcurrency import AVFoundation
import SharedCore
import XCTest

@testable import AppShell

/// Covers the two BAS-10 hooks added to the system audio pipeline: it archives
/// every captured buffer to disk (so the offline pass has audio to re-diarize),
/// and it routes each committed segment through an optional live speaker
/// resolver (so remote turns get `remote_N` labels live, falling back to the
/// coarse `system_audio` when no resolver is wired).
final class MeetingStreamPipelineDiarizationTests: XCTestCase {

    private struct FixedTranscriber: SampleTranscribing {
        let engineLabel = "fake"
        let text: String
        func transcribeSamples(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
            text
        }
    }

    private actor Collector {
        private(set) var utterances: [Utterance] = []
        func add(_ u: Utterance) { utterances.append(u) }
    }

    /// A canonical 16 kHz mono float buffer of constant amplitude.
    private func buffer(amplitude: Float, frames: Int) -> AVAudioPCMBuffer {
        let format = AudioFormat.canonicalASR
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for i in 0..<frames { channel[i] = amplitude }
        return buffer
    }

    private func tempAudioURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-archive-\(UUID().uuidString)")
            .appendingPathComponent("sys.caf")
    }

    /// Drive a full speech segment: ≥3 loud buffers (→ speechStart) then ≥8
    /// silent buffers (→ speechEnd), forcing exactly one committed utterance.
    private func feedOneSegment(into pipeline: MeetingStreamPipeline) async {
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        await pipeline.run(stream)
        for _ in 0..<5 { continuation.yield(buffer(amplitude: 0.3, frames: 2_000)) }
        for _ in 0..<9 { continuation.yield(buffer(amplitude: 0.0, frames: 2_000)) }
        continuation.finish()
        await pipeline.finish()
    }

    func testArchivesEveryBufferToDisk() async throws {
        let url = tempAudioURL()
        let collector = Collector()
        let pipeline = MeetingStreamPipeline(
            speaker: .other(id: "system_audio"),
            diarLabel: "system-stream",
            transcriber: FixedTranscriber(text: ""),
            archiveURL: url,
            onSpeaking: { _ in },
            onCommitted: { await collector.add($0) }
        )
        await feedOneSegment(into: pipeline)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, Int64(14 * 2_000), "all 14 fed buffers should be archived")
    }

    func testCommittedSystemUtteranceUsesResolvedRemoteSpeaker() async {
        let collector = Collector()
        let pipeline = MeetingStreamPipeline(
            speaker: .other(id: "system_audio"),
            diarLabel: "system-stream",
            transcriber: FixedTranscriber(text: "hello there"),
            speakerResolver: { _, _ in .other(id: "remote_7") },
            onSpeaking: { _ in },
            onCommitted: { await collector.add($0) }
        )
        await feedOneSegment(into: pipeline)

        let committed = await collector.utterances
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.speaker, .other(id: "remote_7"))
        XCTAssertEqual(committed.first?.text, "hello there")
    }

    func testCommittedSystemUtteranceFallsBackToDefaultWhenResolverNil() async {
        let collector = Collector()
        let pipeline = MeetingStreamPipeline(
            speaker: .other(id: "system_audio"),
            diarLabel: "system-stream",
            transcriber: FixedTranscriber(text: "hello there"),
            speakerResolver: nil,
            onSpeaking: { _ in },
            onCommitted: { await collector.add($0) }
        )
        await feedOneSegment(into: pipeline)

        let committed = await collector.utterances
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.speaker, .other(id: "system_audio"))
    }

    func testResolverReturningNilKeepsDefaultSpeaker() async {
        let collector = Collector()
        let pipeline = MeetingStreamPipeline(
            speaker: .other(id: "system_audio"),
            diarLabel: "system-stream",
            transcriber: FixedTranscriber(text: "hello there"),
            speakerResolver: { _, _ in nil },
            onSpeaking: { _ in },
            onCommitted: { await collector.add($0) }
        )
        await feedOneSegment(into: pipeline)

        let committed = await collector.utterances
        XCTAssertEqual(committed.first?.speaker, .other(id: "system_audio"))
    }
}
