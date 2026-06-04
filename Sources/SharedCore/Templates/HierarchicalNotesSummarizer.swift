import Foundation

/// Map-reduce summarizer for long meeting transcripts.
///
/// `SmartCap` condenses an over-budget transcript by dropping its middle, which
/// silently loses whatever was discussed in the center of a long meeting. This
/// summarizer instead chunks the transcript on utterance boundaries, summarizes
/// each chunk independently, then synthesizes the chunk-summaries into a single
/// condensed input. The full transcript is never mutated on disk — only the
/// string fed to the notes LLM is condensed, and no region is preferentially
/// discarded.
///
/// The unit is intentionally decoupled from `ModelRouter`: the two LLM steps are
/// injected as `@Sendable` closures so callers can route, cache, or fake them
/// without this type depending on the model layer.
public struct HierarchicalNotesSummarizer: Sendable {
    /// Maximum character budget per chunk before overlap is carried forward.
    public let chunkCharLimit: Int
    /// Trailing characters of each chunk re-prepended to the next, preserving
    /// cross-boundary context for the per-chunk summarizer.
    public let overlapChars: Int

    public init(chunkCharLimit: Int = 12_000, overlapChars: Int = 200) {
        self.chunkCharLimit = max(1, chunkCharLimit)
        self.overlapChars = max(0, overlapChars)
    }

    /// Pure, deterministic.
    ///
    /// Splits on line/utterance boundaries, accumulating lines
    /// up to `chunkCharLimit` (with `overlapChars` of trailing context carried into
    /// the next chunk). Order preserved; no source line is dropped.
    public func chunk(_ transcript: String) -> [String] {
        guard !transcript.isEmpty else { return [] }

        // Preserve every line, including blanks, so nothing is silently dropped.
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var chunks: [String] = []
        var current: [String] = []
        // Length of the joined body so far (lines + interior newlines), excluding
        // the carried overlap prefix. Kept <= chunkCharLimit so a finished chunk is
        // never longer than chunkCharLimit + overlapChars.
        var bodyChars = 0
        var carriedOverlap = ""

        func flush() {
            guard !current.isEmpty else { return }
            let body = current.joined(separator: "\n")
            let combined = carriedOverlap.isEmpty ? body : carriedOverlap + body
            chunks.append(combined)
            carriedOverlap = makeOverlap(from: combined)
            current.removeAll(keepingCapacity: true)
            bodyChars = 0
        }

        for line in lines {
            // Cost of appending this line to the body: the line plus the joining
            // newline when it is not the first line in the chunk.
            let lineCost = current.isEmpty ? line.count : line.count + 1

            // Emit the in-progress chunk when adding this line would push the body
            // past the budget. A single line that alone exceeds the limit cannot be
            // split on a boundary, so it becomes its own chunk (current is empty).
            if !current.isEmpty && bodyChars + lineCost > chunkCharLimit {
                flush()
            }

            current.append(line)
            bodyChars += current.count == 1 ? line.count : line.count + 1
        }

        flush()
        return chunks
    }

    /// Map-reduce condensation.
    ///
    /// If the transcript fits in a single chunk, returns `synthesize([transcript])`
    /// directly and never calls `summarizeChunk`. Otherwise summarizes each chunk
    /// via `summarizeChunk(chunk, index)` (index is the zero-based chunk position),
    /// then folds the resulting summaries through `synthesize`.
    public func condense(
        _ transcript: String,
        summarizeChunk: @Sendable (String, Int) async throws -> String,
        synthesize: @Sendable ([String]) async throws -> String
    ) async throws -> String {
        let chunks = chunk(transcript)

        // Empty or single-chunk transcript: skip the map step entirely. Feed the
        // original transcript through synthesize so no information is lost to
        // chunking artifacts when condensation is unnecessary.
        if chunks.count <= 1 {
            Loggers.templates.debug("HierarchicalNotesSummarizer: single-chunk transcript, skipping map step")
            return try await synthesize([transcript])
        }

        Loggers.templates.info(
            "HierarchicalNotesSummarizer: map-reduce over \(chunks.count, privacy: .public) chunks"
        )
        var summaries: [String] = []
        summaries.reserveCapacity(chunks.count)
        for (index, chunkText) in chunks.enumerated() {
            let summary = try await summarizeChunk(chunkText, index)
            summaries.append(summary)
        }
        return try await synthesize(summaries)
    }

    /// Returns the trailing `overlapChars` characters of `text`, snapped to a line
    /// boundary when one exists inside the window so overlap stays utterance-aligned.
    private func makeOverlap(from text: String) -> String {
        guard overlapChars > 0, text.count > overlapChars else {
            return overlapChars > 0 ? text : ""
        }
        let tail = String(text.suffix(overlapChars))
        // Prefer to start the overlap at a clean line boundary when one falls
        // inside the window; otherwise keep the raw character tail.
        if let newlineIndex = tail.firstIndex(of: "\n") {
            let afterNewline = tail.index(after: newlineIndex)
            return String(tail[afterNewline...])
        }
        return tail
    }
}
