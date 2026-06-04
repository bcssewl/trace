import Foundation

/// Finalize-time orchestrator for the offline "source of truth" diarization
/// pass. After a meeting is sealed it:
///   1. reads the sealed live transcript,
///   2. re-diarizes the recorded system audio with the heavyweight engine
///      (injected as a closure so this stays testable + lets callers pick the
///      file-based, memory-mapped path),
///   3. re-attributes remote utterances to stable `remote_N` via
///      `DiarizationRefiner`, and
///   4. writes `transcript.final.jsonl` atomically.
///
/// It returns the refined utterances so the live model can swap its turns in.
/// Bails out early (returning `nil`, writing nothing) when there's no recorded
/// audio, no remote speech to re-attribute, or the diarizer finds no speakers —
/// leaving the live transcript as the source of truth in those cases.
public actor MeetingDiarizationRefinementService {

    private let refiner: DiarizationRefiner

    public init(refiner: DiarizationRefiner = DiarizationRefiner()) {
        self.refiner = refiner
    }

    @discardableResult
    public func refine(
        liveTranscriptURL: URL,
        finalTranscriptURL: URL,
        systemAudioURL: URL,
        diarize: @Sendable (URL) async throws -> [DiarizedSegment],
        deleteRecordingAfterRefine: Bool = false
    ) async throws -> [Utterance]? {
        try await refineDetailed(
            liveTranscriptURL: liveTranscriptURL,
            finalTranscriptURL: finalTranscriptURL,
            systemAudioURL: systemAudioURL,
            diarize: diarize,
            deleteRecordingAfterRefine: deleteRecordingAfterRefine
        )?.utterances
    }

    /// Like ``refine`` but also returns the per-`remote_N` mean voiceprints, so
    /// cross-meeting speaker memory (BAS-11) can match them against the enrolled
    /// DB.
    ///
    /// Same bail-out conditions, same `transcript.final.jsonl` write.
    ///
    /// When `deleteRecordingAfterRefine` is `true` (BAS-41), the recorded system
    /// audio is removed once this pass has consumed it — the recording's only
    /// purpose is this re-diarization, and `transcript.final.jsonl` is the durable
    /// artifact. The delete also covers the useless cases (no remote speech / no
    /// speakers found) so no orphan recording is left behind; callers that want to
    /// keep the recording for re-refinement pass `false` (the default).
    @discardableResult
    public func refineDetailed(
        liveTranscriptURL: URL,
        finalTranscriptURL: URL,
        systemAudioURL: URL,
        diarize: @Sendable (URL) async throws -> [DiarizedSegment],
        deleteRecordingAfterRefine: Bool = false
    ) async throws -> DiarizationRefiner.RefinementResult? {
        guard FileManager.default.fileExists(atPath: systemAudioURL.path) else { return nil }
        // The recording exists and won't be needed after this pass (unless the
        // caller is keeping recordings) — clean it up on every exit path.
        defer {
            if deleteRecordingAfterRefine {
                try? FileManager.default.removeItem(at: systemAudioURL)
            }
        }

        let utterances = Self.readUtterances(from: liveTranscriptURL)
        guard utterances.contains(where: { $0.speaker != .you }) else { return nil }

        let segments = try await diarize(systemAudioURL)
        guard !segments.isEmpty else { return nil }

        let result = refiner.refineDetailed(utterances: utterances, segments: segments)
        try Self.writeUtterances(result.utterances, to: finalTranscriptURL)
        return result
    }

    /// Parse a JSONL transcript into utterances, tolerating unparseable lines
    /// (mirrors `SessionRepository`'s reader) so one bad line never aborts.
    static func readUtterances(from url: URL) -> [Utterance] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var out: [Utterance] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                let utterance = try? decoder.decode(Utterance.self, from: data)
            else { continue }
            out.append(utterance)
        }
        return out
    }

    /// Atomically write utterances as JSONL (temp file → rename via `.atomic`),
    /// matching `JsonlWriter`'s slash-unescaped formatting.
    static func writeUtterances(_ utterances: [Utterance], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var lines: [String] = []
        lines.reserveCapacity(utterances.count)
        for utterance in utterances {
            let data = try encoder.encode(utterance)
            lines.append(String(decoding: data, as: UTF8.self))
        }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: url, options: .atomic)
    }
}
