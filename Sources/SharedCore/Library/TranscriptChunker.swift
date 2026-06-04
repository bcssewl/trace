import Foundation

/// Chunks a meeting transcript (a sequence of utterances) into ~500-word windows
/// with ~100-word overlap, preserving utterance boundaries so each chunk stays
/// coherent and citable.
///
/// Unlike `MarkdownChunker`, it threads per-chunk
/// provenance: the start timestamp (so a citation can seek the transcript to the
/// cited moment) and the ordered set of speaker display names.
public enum TranscriptChunker {

    /// One transcript utterance, already resolved to a display speaker name.
    public struct Line: Sendable, Hashable {
        public let t: Double  // seconds from meeting start
        public let speaker: String  // display name ("You", "Sarah", "Speaker 2")
        public let text: String
        public init(t: Double, speaker: String, text: String) {
            self.t = t
            self.speaker = speaker
            self.text = text
        }
    }

    public struct Output: Sendable, Hashable {
        public let text: String  // "Speaker: line\nSpeaker: line …"
        public let tsStart: Double  // first utterance's timestamp
        public let speakers: [String]  // distinct display names, first-seen order
        public let breadcrumb: String  // e.g. "Q2 Strategy · 03:08"
        public init(text: String, tsStart: Double, speakers: [String], breadcrumb: String) {
            self.text = text
            self.tsStart = tsStart
            self.speakers = speakers
            self.breadcrumb = breadcrumb
        }
    }

    public static let defaultTargetMaxWords = 500
    public static let defaultOverlapWords = 100

    /// Greedy word-budget windowing over whole utterances.
    ///
    /// A window grows until
    /// the next utterance would exceed `targetMaxWords` (but always holds at
    /// least one utterance, even an over-long one), then the next window steps
    /// back over trailing utterances summing ≈`overlapWords` for continuity —
    /// always advancing past the current start so it terminates.
    public static func chunk(
        lines: [Line],
        meetingTitle: String,
        targetMaxWords: Int = defaultTargetMaxWords,
        overlapWords: Int = defaultOverlapWords
    ) -> [Output] {
        let usable = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return [] }
        let wordCounts = usable.map { max(1, $0.text.split(whereSeparator: \.isWhitespace).count) }
        let n = usable.count

        var outputs: [Output] = []
        var start = 0
        while start < n {
            var end = start
            var words = 0
            while end < n, end == start || words + wordCounts[end] <= targetMaxWords {
                words += wordCounts[end]
                end += 1
            }
            outputs.append(makeOutput(Array(usable[start..<end]), meetingTitle: meetingTitle))
            if end >= n { break }

            var nextStart = end
            var overlap = 0
            while nextStart > start + 1, overlap + wordCounts[nextStart - 1] <= overlapWords {
                nextStart -= 1
                overlap += wordCounts[nextStart]
            }
            start = max(nextStart, start + 1)
        }
        return outputs
    }

    private static func makeOutput(_ window: [Line], meetingTitle: String) -> Output {
        var seen = Set<String>()
        var speakers: [String] = []
        var body: [String] = []
        body.reserveCapacity(window.count)
        for line in window {
            if seen.insert(line.speaker).inserted { speakers.append(line.speaker) }
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            body.append("\(line.speaker): \(text)")
        }
        let tsStart = window.first?.t ?? 0
        let crumbTitle = meetingTitle.isEmpty ? "Meeting" : meetingTitle
        return Output(
            text: body.joined(separator: "\n"),
            tsStart: tsStart,
            speakers: speakers,
            breadcrumb: "\(crumbTitle) · \(timeLabel(tsStart))"
        )
    }

    /// Compact `mm:ss` (or `h:mm:ss`) label for a seconds offset.
    ///
    /// Public so the
    /// citation UI and `MeetingLiveView` can render the same timestamp format.
    public static func timeLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
