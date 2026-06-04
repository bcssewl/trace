import Foundation

/// The pure, offline "source of truth" diarization pass.
///
/// Live capture tags the whole remote stream coarsely (`system_audio`) or with
/// best-effort live labels. After the meeting ends we re-diarize the recorded
/// system audio with the heavyweight (Pyannote) engine and hand the resulting
/// speaker segments here, together with the utterances captured live. This
/// re-attributes every *remote* utterance to a stable `remote_N` speaker; the
/// mic stream (`.you`) is never touched.
///
/// Plain-language model: diarization tells us *who* held the floor across the
/// meeting's timeline (a set of per-speaker "runs", with brief same-speaker gaps
/// stitched together). For each remote line we already transcribed, we look at
/// the slice of meeting time it covers and credit it to whichever speaker held
/// the floor for most of that slice. We keep the words and timings exactly as
/// transcribed — only the speaker label changes — so refinement can never
/// degrade the transcript text, only its attribution.
public struct DiarizationRefiner {

    public struct Config: Sendable {
        /// Same-speaker segments separated by a gap shorter than this are merged
        /// into one run, so a natural breath mid-sentence doesn't fragment a turn.
        public var mergeGapSeconds: TimeInterval
        /// The last remote utterance has no following utterance to bound its
        /// span; we extend it by this many seconds when measuring overlap.
        public var trailingSeconds: TimeInterval
        /// Stamped into each refined utterance's `diar` field as
        /// `"<prefix>:<engineSpeakerId>"` so the provenance of a label is legible.
        public var provenancePrefix: String

        public init(
            mergeGapSeconds: TimeInterval = 0.8,
            trailingSeconds: TimeInterval = 3,
            provenancePrefix: String = "pyannote"
        ) {
            self.mergeGapSeconds = mergeGapSeconds
            self.trailingSeconds = trailingSeconds
            self.provenancePrefix = provenancePrefix
        }
    }

    /// A contiguous stretch of one speaker's activity, after merging tiny gaps.
    private struct Run {
        let engineSpeaker: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private let config: Config

    public init(config: Config = .init()) { self.config = config }

    /// The result of a detailed refinement pass: the re-attributed utterances plus
    /// a mean voiceprint per allocated `remote_N` label.
    public struct RefinementResult: Sendable, Hashable {
        public let utterances: [Utterance]
        /// Mean speaker embedding per allocated `remote_N`, averaged element-wise
        /// over that cluster's segment embeddings.
        ///
        /// Only clusters whose segments
        /// carried embeddings appear here (an empty map means the diarizer
        /// produced no embeddings, so cross-meeting matching is simply skipped).
        public let speakerEmbeddings: [String: [Float]]

        public init(utterances: [Utterance], speakerEmbeddings: [String: [Float]]) {
            self.utterances = utterances
            self.speakerEmbeddings = speakerEmbeddings
        }
    }

    /// Re-attribute remote utterances to stable per-speaker labels using the
    /// diarized segments. `.you` utterances pass through untouched.
    ///
    /// With no
    /// segments (or no usable runs) the input is returned verbatim. The result is
    /// ordered by time (stable for equal timestamps).
    public func refine(utterances: [Utterance], segments: [DiarizedSegment]) -> [Utterance] {
        refineDetailed(utterances: utterances, segments: segments).utterances
    }

    /// Like ``refine(utterances:segments:)`` but also returns a mean voiceprint
    /// per allocated `remote_N` label — the raw material the cross-meeting speaker
    /// memory (BAS-11) matches against the enrolled-voiceprint DB. The utterances
    /// are identical to ``refine``'s output.
    public func refineDetailed(utterances: [Utterance], segments: [DiarizedSegment]) -> RefinementResult {
        let runs = buildRuns(from: segments)
        guard !runs.isEmpty else { return RefinementResult(utterances: utterances, speakerEmbeddings: [:]) }

        // Allocate remote_N per engine speaker, ordered by when each speaker
        // first holds the floor (earliest run start; ties broken by engine id).
        let speakerFirstStart = Dictionary(
            runs.map { ($0.engineSpeaker, $0.start) },
            uniquingKeysWith: min
        )
        let orderedSpeakers =
            speakerFirstStart
            .sorted { ($0.value, $0.key) < ($1.value, $1.key) }
            .map(\.key)
        // Allocate remote_N in first-appearance order; the allocator then answers
        // the per-speaker label lookups below (no separate mapping dict needed).
        var allocator = SpeakerLabelAllocator()
        for speaker in orderedSpeakers {
            _ = allocator.label(forEngineCluster: speaker)
        }

        // Index utterances so we can rebuild spans for the remote subsequence
        // while preserving original order for the final stable sort.
        let indexed = Array(utterances.enumerated())
        let remoteIndices = indexed.filter { $0.element.speaker != .you }.map(\.offset)
        let remoteByTime = remoteIndices.sorted {
            (utterances[$0].t, $0) < (utterances[$1].t, $1)
        }

        var refinedByIndex: [Int: Utterance] = [:]
        for (position, index) in remoteByTime.enumerated() {
            let utterance = utterances[index]
            let spanStart = utterance.t
            let spanEnd: TimeInterval
            if position + 1 < remoteByTime.count {
                spanEnd = max(spanStart, utterances[remoteByTime[position + 1]].t)
            } else {
                spanEnd = spanStart + config.trailingSeconds
            }
            let engineSpeaker = attribute(spanStart: spanStart, spanEnd: spanEnd, runs: runs)
            let label = engineSpeaker.flatMap { allocator.existingLabel(forEngineCluster: $0) }
            if let engineSpeaker, let label {
                refinedByIndex[index] = utterance.reattributed(
                    to: .other(id: label),
                    diar: "\(config.provenancePrefix):\(engineSpeaker)"
                )
            }
        }

        let merged = indexed.map { refinedByIndex[$0.offset] ?? $0.element }
        let ordered = indexed.indices
            .sorted { (merged[$0].t, $0) < (merged[$1].t, $1) }
            .map { merged[$0] }
        let embeddings = Self.meanEmbeddings(segments: segments, allocator: allocator)
        return RefinementResult(utterances: ordered, speakerEmbeddings: embeddings)
    }

    /// Average each engine cluster's segment embeddings element-wise and key the
    /// result by the cluster's allocated `remote_N` label.
    ///
    /// Segments with no (or
    /// empty, or dimension-mismatched) embedding are ignored; clusters left with
    /// no usable embedding — or no allocated label — produce no entry.
    private static func meanEmbeddings(
        segments: [DiarizedSegment], allocator: SpeakerLabelAllocator
    ) -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for segment in segments {
            guard let embedding = segment.embedding, !embedding.isEmpty else { continue }
            if let running = sums[segment.speakerLabel] {
                guard running.count == embedding.count else { continue }
                sums[segment.speakerLabel] = zip(running, embedding).map(+)
            } else {
                sums[segment.speakerLabel] = embedding
            }
            counts[segment.speakerLabel, default: 0] += 1
        }
        var out: [String: [Float]] = [:]
        for (cluster, sum) in sums {
            guard let label = allocator.existingLabel(forEngineCluster: cluster),
                let count = counts[cluster], count > 0
            else { continue }
            out[label] = sum.map { $0 / Float(count) }
        }
        return out
    }

    /// Merge each speaker's segments into runs, stitching gaps below the
    /// configured threshold.
    ///
    /// Segments with non-positive duration are ignored.
    private func buildRuns(from segments: [DiarizedSegment]) -> [Run] {
        guard !segments.isEmpty else { return [] }
        var bySpeaker: [String: [DiarizedSegment]] = [:]
        for segment in segments where segment.endTime > segment.startTime {
            bySpeaker[segment.speakerLabel, default: []].append(segment)
        }

        var runs: [Run] = []
        for (speaker, speakerSegments) in bySpeaker {
            let sorted = speakerSegments.sorted { $0.startTime < $1.startTime }
            var runStart = sorted[0].startTime
            var runEnd = sorted[0].endTime
            for segment in sorted.dropFirst() {
                if segment.startTime - runEnd < config.mergeGapSeconds {
                    runEnd = max(runEnd, segment.endTime)
                } else {
                    runs.append(Run(engineSpeaker: speaker, start: runStart, end: runEnd))
                    runStart = segment.startTime
                    runEnd = segment.endTime
                }
            }
            runs.append(Run(engineSpeaker: speaker, start: runStart, end: runEnd))
        }
        return runs.sorted { $0.start < $1.start }
    }

    /// The engine speaker that held the floor for most of `[spanStart, spanEnd)`.
    ///
    /// Falls back to the nearest run when nothing overlaps (e.g. a trailing
    /// utterance past the diarized audio). `nil` only when there are no runs.
    private func attribute(spanStart: TimeInterval, spanEnd: TimeInterval, runs: [Run]) -> String? {
        var overlapBySpeaker: [String: TimeInterval] = [:]
        for run in runs {
            let overlap = max(0, min(spanEnd, run.end) - max(spanStart, run.start))
            if overlap > 0 { overlapBySpeaker[run.engineSpeaker, default: 0] += overlap }
        }
        if let best = overlapBySpeaker.max(by: { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }) {
            return best.key
        }
        // No overlap: attribute to the temporally nearest run (distance measured
        // once per run rather than re-evaluated inside a comparator).
        var nearest: Run?
        var bestDistance = TimeInterval.infinity
        for run in runs {
            let d = distance(spanStart: spanStart, spanEnd: spanEnd, run: run)
            if d < bestDistance {
                bestDistance = d
                nearest = run
            }
        }
        return nearest?.engineSpeaker
    }

    private func distance(spanStart: TimeInterval, spanEnd: TimeInterval, run: Run) -> TimeInterval {
        if spanEnd <= run.start { return run.start - spanEnd }
        if spanStart >= run.end { return spanStart - run.end }
        return 0
    }
}

extension Utterance {
    /// A copy with a new speaker + diarization tag, preserving timing, text,
    /// confidence, ASR engine and any cleaned text.
    fileprivate func reattributed(to speaker: Speaker, diar: String) -> Utterance {
        Utterance(
            t: t,
            speaker: speaker,
            text: text,
            conf: conf,
            asr: asr,
            diar: diar,
            cleaned: cleaned
        )
    }
}
