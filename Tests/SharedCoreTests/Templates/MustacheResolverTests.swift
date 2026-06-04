import XCTest

@testable import SharedCore

final class MustacheResolverTests: XCTestCase {
    func testResolvesTrustedPlaceholdersRaw() {
        let ctx = RenderContext(
            transcript: "TRANSCRIPT",
            scratchpad: "SCRATCH",
            calendarUntrusted: "",
            priorNotesUntrusted: "",
            projectVocab: "VOCAB",
            conversationState: "STATE"
        )
        let out = MustacheResolver.resolve(
            template: "t={{transcript}} s={{scratchpad}} v={{project_vocab}} st={{conversation_state}}",
            context: ctx
        )
        XCTAssertEqual(out, "t=TRANSCRIPT s=SCRATCH v=VOCAB st=STATE")
    }

    func testUntrustedFieldsAreWrapped() {
        let ctx = RenderContext(
            transcript: "", scratchpad: "",
            calendarUntrusted: "Title: ACME",
            priorNotesUntrusted: "PriorBody",
            projectVocab: "", conversationState: ""
        )
        let out = MustacheResolver.resolve(
            template: "{{calendar}}|{{prior_notes}}",
            context: ctx
        )
        XCTAssertTrue(out.contains("<UNTRUSTED-DATA source=\"calendar\">"))
        XCTAssertTrue(out.contains("<UNTRUSTED-DATA source=\"prior-notes\">"))
        XCTAssertTrue(out.contains("Title: ACME"))
        XCTAssertTrue(out.contains("PriorBody"))
        XCTAssertTrue(out.contains("</UNTRUSTED-DATA>"))
    }

    func testEmptyUntrustedShortCircuitsToEmpty() {
        let ctx = RenderContext.empty
        let out = MustacheResolver.resolve(template: "[{{calendar}}][{{prior_notes}}]", context: ctx)
        XCTAssertEqual(out, "[][]")
    }

    func testUnknownTokenIsLeftInPlace() {
        let ctx = RenderContext.empty
        let out = MustacheResolver.resolve(template: "{{not_a_real_token}}", context: ctx)
        XCTAssertEqual(out, "{{not_a_real_token}}")
    }

    func testDoesNotMutateRenderContext() {
        let ctx = RenderContext(
            transcript: "A", scratchpad: "B",
            calendarUntrusted: "C", priorNotesUntrusted: "D",
            projectVocab: "E", conversationState: "F"
        )
        _ = MustacheResolver.resolve(template: "{{transcript}}", context: ctx)
        XCTAssertEqual(ctx.transcript, "A")
        XCTAssertEqual(ctx.scratchpad, "B")
        XCTAssertEqual(ctx.calendarUntrusted, "C")
    }
}

final class SmartCapTests: XCTestCase {
    func testBelowCapPassesThrough() {
        let small = String(repeating: "a", count: 100)
        XCTAssertEqual(SmartCap.trim(transcript: small), small)
    }

    func testAtBoundaryDoesNotTrim() {
        let exact = String(repeating: "b", count: SmartCap.defaultCapChars)
        XCTAssertEqual(SmartCap.trim(transcript: exact), exact)
    }

    func testExceedingCapInsertsMiddleMarker() {
        let oversized = String(repeating: "c", count: SmartCap.defaultCapChars + 1_000)
        let trimmed = SmartCap.trim(transcript: oversized)
        XCTAssertTrue(trimmed.contains("transcript trimmed"))
        XCTAssertLessThan(trimmed.count, oversized.count)
    }

    func testLinewiseTrimMentionsUtterancesOmitted() {
        let lines = (0..<2_000).map { "[\($0)] some utterance content here that exists to take up character budget" }
        let big = lines.joined(separator: "\n")
        XCTAssertGreaterThan(big.count, SmartCap.defaultCapChars)
        let trimmed = SmartCap.trim(transcript: big)
        XCTAssertTrue(trimmed.contains("utterances omitted"))
    }

    func testKeepsHeadAndTailRegions() {
        let lines = (0..<3_000).map {
            "[\($0)] utterance number \($0) carrying meaningful payload xxxxxxxxxxxxxxxxxxxxxxxxxx"
        }
        let big = lines.joined(separator: "\n")
        let trimmed = SmartCap.trim(transcript: big)
        XCTAssertTrue(trimmed.contains("[0] utterance"))
        XCTAssertTrue(trimmed.contains("[2999] utterance"))
    }
}

// Calendar-template matching (MatcherResolver) was removed with the unused
// per-type template library — meetings now use one in-code dynamic-headings
// template. CalendarMatcher itself stays (used by project overrides) and is
// covered by CalendarMatcherTests.
