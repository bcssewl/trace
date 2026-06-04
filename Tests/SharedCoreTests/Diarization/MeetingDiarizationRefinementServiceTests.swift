import XCTest

@testable import SharedCore

/// `MeetingDiarizationRefinementService` is the finalize-time orchestrator: it
/// reads the sealed live transcript, runs the (injected) heavyweight diarizer
/// over the recorded system audio, re-attributes remote utterances via
/// `DiarizationRefiner`, and writes the stable `transcript.final.jsonl`.
///
/// The
/// diarizer is a closure seam so this is tested end-to-end on disk without
/// CoreML models or real audio — only the speaker segments are scripted.
final class MeetingDiarizationRefinementServiceTests: XCTestCase {

    private func makeSession() throws -> (dir: URL, live: URL, final: URL, audio: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diar-refine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (
            dir,
            dir.appendingPathComponent("transcript.live.jsonl"),
            dir.appendingPathComponent("transcript.final.jsonl"),
            dir.appendingPathComponent("sys.caf")
        )
    }

    private func writeLive(_ utterances: [Utterance], to url: URL) async throws {
        let writer = JsonlWriter(url: url)
        for utterance in utterances { try await writer.append(utterance) }
        try await writer.close()
    }

    private func touch(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data([0x01, 0x02]))
    }

    private func you(_ t: Double, _ text: String) -> Utterance {
        Utterance(t: t, speaker: .you, text: text, conf: 0.6, asr: "parakeet", diar: "mic-stream")
    }
    private func remote(_ t: Double, _ text: String) -> Utterance {
        Utterance(
            t: t, speaker: .other(id: "system_audio"), text: text, conf: 0.6, asr: "parakeet", diar: "system-stream")
    }
    private func seg(_ start: Double, _ end: Double, _ speaker: String) -> DiarizedSegment {
        DiarizedSegment(startTime: start, endTime: end, speakerLabel: speaker)
    }

    func testRefinesRemoteUtterancesAndWritesFinalTranscript() async throws {
        let s = try makeSession()
        try await writeLive([you(0, "hi"), remote(1, "alpha"), remote(6, "beta")], to: s.live)
        touch(s.audio)

        let segments = [seg(0, 5, "0"), seg(5, 10, "1")]
        let service = MeetingDiarizationRefinementService()
        let refined = try await service.refine(
            liveTranscriptURL: s.live,
            finalTranscriptURL: s.final,
            systemAudioURL: s.audio,
            diarize: { _ in segments }
        )

        let result = try XCTUnwrap(refined)
        XCTAssertEqual(result.map(\.speaker), [.you, .other(id: "remote_1"), .other(id: "remote_2")])
        XCTAssertEqual(result.map(\.text), ["hi", "alpha", "beta"])

        // The final transcript on disk round-trips to the same refined speakers.
        let onDisk = try JsonlReader.readAll(Utterance.self, from: s.final)
        XCTAssertEqual(onDisk.map(\.speaker.rawValue), ["you", "remote_1", "remote_2"])
        XCTAssertEqual(onDisk.first { $0.text == "alpha" }?.diar, "pyannote:0")
    }

    func testNoSystemAudioFileReturnsNilAndWritesNothing() async throws {
        let s = try makeSession()
        try await writeLive([you(0, "hi"), remote(1, "alpha")], to: s.live)
        // No audio file created.

        let segments = [seg(0, 5, "0")]
        let service = MeetingDiarizationRefinementService()
        let refined = try await service.refine(
            liveTranscriptURL: s.live,
            finalTranscriptURL: s.final,
            systemAudioURL: s.audio,
            diarize: { _ in segments }
        )
        XCTAssertNil(refined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.final.path))
    }

    func testNoRemoteUtterancesReturnsNil() async throws {
        let s = try makeSession()
        try await writeLive([you(0, "hi"), you(2, "just me")], to: s.live)
        touch(s.audio)

        let segments = [seg(0, 5, "0")]
        let service = MeetingDiarizationRefinementService()
        let refined = try await service.refine(
            liveTranscriptURL: s.live,
            finalTranscriptURL: s.final,
            systemAudioURL: s.audio,
            diarize: { _ in segments }
        )
        XCTAssertNil(refined, "Nothing remote to re-attribute → skip refinement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.final.path))
    }

    func testEmptyDiarizationReturnsNil() async throws {
        let s = try makeSession()
        try await writeLive([remote(1, "alpha")], to: s.live)
        touch(s.audio)

        let service = MeetingDiarizationRefinementService()
        let refined = try await service.refine(
            liveTranscriptURL: s.live,
            finalTranscriptURL: s.final,
            systemAudioURL: s.audio,
            diarize: { _ in [] }
        )
        XCTAssertNil(refined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.final.path))
    }

    // MARK: - refineDetailed: surface per-speaker embeddings (BAS-11)

    func testRefineDetailedReturnsRefinedTurnsAndSpeakerEmbeddings() async throws {
        let s = try makeSession()
        try await writeLive([remote(1, "alpha"), remote(6, "beta")], to: s.live)
        touch(s.audio)

        let segments = [
            DiarizedSegment(startTime: 0, endTime: 5, speakerLabel: "0", embedding: [1, 0]),
            DiarizedSegment(startTime: 5, endTime: 10, speakerLabel: "1", embedding: [0, 1]),
        ]
        let service = MeetingDiarizationRefinementService()
        let result = try await service.refineDetailed(
            liveTranscriptURL: s.live,
            finalTranscriptURL: s.final,
            systemAudioURL: s.audio,
            diarize: { _ in segments }
        )

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.utterances.map(\.speaker), [.other(id: "remote_1"), .other(id: "remote_2")])
        XCTAssertEqual(unwrapped.speakerEmbeddings["remote_1"], [1, 0])
        XCTAssertEqual(unwrapped.speakerEmbeddings["remote_2"], [0, 1])
        // Still writes the final transcript on disk (same as refine()).
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.final.path))
    }

    func testRefineDetailedBailsOutLikeRefine() async throws {
        let s = try makeSession()
        try await writeLive([remote(1, "alpha")], to: s.live)
        // No audio file created → nil, nothing written.
        let service = MeetingDiarizationRefinementService()
        let result = try await service.refineDetailed(
            liveTranscriptURL: s.live,
            finalTranscriptURL: s.final,
            systemAudioURL: s.audio,
            diarize: { _ in [DiarizedSegment(startTime: 0, endTime: 5, speakerLabel: "0")] }
        )
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.final.path))
    }

    // MARK: - sys.caf retention (BAS-41)

    func testDeletesRecordingAfterSuccessfulRefineWhenRequested() async throws {
        let s = try makeSession()
        try await writeLive([remote(1, "alpha")], to: s.live)
        touch(s.audio)
        let segments = [seg(0, 5, "0")]
        let service = MeetingDiarizationRefinementService()
        _ = try await service.refineDetailed(
            liveTranscriptURL: s.live, finalTranscriptURL: s.final, systemAudioURL: s.audio,
            diarize: { _ in segments }, deleteRecordingAfterRefine: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.audio.path), "recording deleted once consumed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.final.path), "final transcript is the durable artifact")
    }

    func testKeepsRecordingWhenNotRequested() async throws {
        let s = try makeSession()
        try await writeLive([remote(1, "alpha")], to: s.live)
        touch(s.audio)
        let segments = [seg(0, 5, "0")]
        let service = MeetingDiarizationRefinementService()
        _ = try await service.refineDetailed(
            liveTranscriptURL: s.live, finalTranscriptURL: s.final, systemAudioURL: s.audio,
            diarize: { _ in segments }, deleteRecordingAfterRefine: false
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.audio.path), "recording kept for re-refinement")
    }

    func testDeletesUselessRecordingWithNoRemoteSpeechWhenRequested() async throws {
        let s = try makeSession()
        try await writeLive([you(0, "just me")], to: s.live)  // nothing remote to refine
        touch(s.audio)
        let service = MeetingDiarizationRefinementService()
        let result = try await service.refineDetailed(
            liveTranscriptURL: s.live, finalTranscriptURL: s.final, systemAudioURL: s.audio,
            diarize: { _ in [] }, deleteRecordingAfterRefine: true
        )
        XCTAssertNil(result)
        // The recording served no purpose and the user isn't keeping recordings →
        // clean it up rather than leaving an orphan on disk.
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.audio.path))
    }
}
