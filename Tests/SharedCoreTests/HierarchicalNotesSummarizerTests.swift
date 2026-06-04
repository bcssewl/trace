import XCTest

@testable import SharedCore

final class HierarchicalNotesSummarizerTests: XCTestCase {

    // MARK: chunk()

    func testShortTranscriptYieldsExactlyOneChunk() {
        let summarizer = HierarchicalNotesSummarizer(chunkCharLimit: 12_000, overlapChars: 200)
        let transcript = "Sarah: hi everyone.\nMark: let's begin.\nSarah: agenda is short."
        let chunks = summarizer.chunk(transcript)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, transcript)
    }

    func testEmptyTranscriptYieldsNoChunks() {
        let summarizer = HierarchicalNotesSummarizer()
        XCTAssertTrue(summarizer.chunk("").isEmpty)
    }

    func testLongTranscriptYieldsMultipleChunksWithinBudget() {
        let limit = 500
        let overlap = 40
        let summarizer = HierarchicalNotesSummarizer(chunkCharLimit: limit, overlapChars: overlap)
        // Each line is well under the per-chunk limit so no single line forms an
        // oversized chunk; the body of every chunk must stay <= limit + overlap.
        let lines = (0..<400).map { "Speaker \($0 % 4): utterance number \($0) discussing the roadmap." }
        let transcript = lines.joined(separator: "\n")
        XCTAssertGreaterThan(transcript.count, limit)

        let chunks = summarizer.chunk(transcript)
        XCTAssertGreaterThan(chunks.count, 1, "a transcript far larger than the limit must split")
        for c in chunks {
            XCTAssertLessThanOrEqual(
                c.count, limit + overlap,
                "each chunk must fit within chunkCharLimit + overlapChars")
        }
    }

    func testOrderPreservedAndNoLineDropped() {
        let summarizer = HierarchicalNotesSummarizer(chunkCharLimit: 300, overlapChars: 0)
        // overlap=0 makes reconstruction exact: concatenating chunk bodies with a
        // newline must reproduce the original transcript verbatim, in order.
        let lines = (0..<250).map { "L\($0): the quick brown fox jumps over the lazy dog." }
        let transcript = lines.joined(separator: "\n")

        let chunks = summarizer.chunk(transcript)
        XCTAssertGreaterThan(chunks.count, 1)

        let reconstructed = chunks.joined(separator: "\n")
        XCTAssertEqual(
            reconstructed, transcript,
            "with zero overlap, chunk bodies must reconstruct the transcript losslessly and in order")

        // Every original line must appear in exactly one chunk, in order.
        let flattened = chunks.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(flattened, lines)
    }

    func testOverlapCarriesTrailingContextIntoNextChunk() {
        let summarizer = HierarchicalNotesSummarizer(chunkCharLimit: 120, overlapChars: 60)
        let lines = (0..<30).map { "Line \($0) carrying some meaningful conversational content." }
        let transcript = lines.joined(separator: "\n")

        let chunks = summarizer.chunk(transcript)
        XCTAssertGreaterThan(chunks.count, 1)
        // Later chunks should be prefixed with overlap (so they are non-empty
        // beyond their own first line); assert overlap budget is respected.
        for c in chunks {
            XCTAssertLessThanOrEqual(c.count, 120 + 60)
            XCTAssertFalse(c.isEmpty)
        }
    }

    // MARK: condense()

    func testCondenseShortTranscriptCallsSynthesizeOnceAndSkipsSummarize() async throws {
        let summarizer = HierarchicalNotesSummarizer(chunkCharLimit: 12_000, overlapChars: 200)
        let transcript = "Sarah: short meeting.\nMark: agreed."

        let counters = CallCounters()
        let result = try await summarizer.condense(
            transcript,
            summarizeChunk: { chunkText, index in
                await counters.recordSummarize(chunkText: chunkText, index: index)
                return "SUMMARY"
            },
            synthesize: { summaries in
                await counters.recordSynthesize(summaries: summaries)
                return "FINAL"
            }
        )

        XCTAssertEqual(result, "FINAL")
        let summarizeCount = await counters.summarizeCount
        let synthesizeCount = await counters.synthesizeCount
        let synthesizeInput = await counters.lastSynthesizeInput
        XCTAssertEqual(summarizeCount, 0, "single-chunk transcript must NOT call summarizeChunk")
        XCTAssertEqual(synthesizeCount, 1, "synthesize must be called exactly once")
        XCTAssertEqual(synthesizeInput, [transcript], "synthesize must receive the original transcript")
    }

    func testCondenseLongTranscriptMapsThenReduces() async throws {
        let limit = 400
        let summarizer = HierarchicalNotesSummarizer(chunkCharLimit: limit, overlapChars: 30)
        let lines = (0..<300).map { "Speaker \($0 % 3): point number \($0) about the quarterly plan." }
        let transcript = lines.joined(separator: "\n")

        let expectedChunks = summarizer.chunk(transcript)
        XCTAssertGreaterThan(expectedChunks.count, 1)

        let counters = CallCounters()
        let result = try await summarizer.condense(
            transcript,
            summarizeChunk: { chunkText, index in
                await counters.recordSummarize(chunkText: chunkText, index: index)
                return "S\(index)"
            },
            synthesize: { summaries in
                await counters.recordSynthesize(summaries: summaries)
                return summaries.joined(separator: "|")
            }
        )

        let summarizeCount = await counters.summarizeCount
        let synthesizeCount = await counters.synthesizeCount
        let indices = await counters.summarizeIndices
        let synthesizeInput = await counters.lastSynthesizeInput

        XCTAssertEqual(
            summarizeCount, expectedChunks.count,
            "summarizeChunk must be called exactly once per chunk")
        XCTAssertEqual(synthesizeCount, 1, "synthesize must be called exactly once")
        XCTAssertEqual(
            indices, Array(0..<expectedChunks.count),
            "chunk indices must be passed in order, zero-based")
        let expectedSummaries = (0..<expectedChunks.count).map { "S\($0)" }
        XCTAssertEqual(
            synthesizeInput, expectedSummaries,
            "synthesize must receive the per-chunk summaries in order")
        XCTAssertEqual(result, expectedSummaries.joined(separator: "|"))
    }

    func testCondensePropagatesSummarizeError() async {
        let summarizer = HierarchicalNotesSummarizer(chunkCharLimit: 100, overlapChars: 0)
        let transcript = (0..<200).map { "Line \($0) of a very long meeting transcript." }.joined(separator: "\n")
        do {
            _ = try await summarizer.condense(
                transcript,
                summarizeChunk: { _, _ in throw TraceError.configInvalid(field: "x", reason: "boom") },
                synthesize: { _ in "FINAL" }
            )
            XCTFail("condense should rethrow errors from summarizeChunk")
        } catch let error as TraceError {
            if case .configInvalid = error {
                // expected
            } else {
                XCTFail("unexpected TraceError: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

/// Actor-isolated counters so the fake `@Sendable` closures can record calls
/// without data races under Swift 6 strict concurrency.
private actor CallCounters {
    private(set) var summarizeCount = 0
    private(set) var synthesizeCount = 0
    private(set) var summarizeIndices: [Int] = []
    private(set) var lastSynthesizeInput: [String] = []

    func recordSummarize(chunkText: String, index: Int) {
        summarizeCount += 1
        summarizeIndices.append(index)
    }

    func recordSynthesize(summaries: [String]) {
        synthesizeCount += 1
        lastSynthesizeInput = summaries
    }
}
