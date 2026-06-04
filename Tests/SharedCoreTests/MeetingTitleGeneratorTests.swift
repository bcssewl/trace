import XCTest

@testable import SharedCore

/// `MeetingTitleGenerator` turns a meeting transcript into a short descriptive
/// title via the `.titleGeneration` task class, replacing the date-based fallback
/// (BAS-29).
///
/// The model call goes through the `ModelRoutingFacade` seam so it's
/// tested with a scripted router (no real LLM); `sanitize` / `isPlaceholderTitle`
/// are pure.
final class MeetingTitleGeneratorTests: XCTestCase {

    private let transcript = """
        You: let's lock the Q3 budget today
        Speaker 1: marketing needs another forty thousand
        """

    // MARK: sanitize (pure)

    func testSanitizeStripsSurroundingQuotesAndTrailingPeriod() {
        XCTAssertEqual(MeetingTitleGenerator.sanitize("\"Q3 Budget Planning\"."), "Q3 Budget Planning")
        XCTAssertEqual(MeetingTitleGenerator.sanitize("“Roadmap Review”"), "Roadmap Review")
        XCTAssertEqual(MeetingTitleGenerator.sanitize("**Hiring sync**"), "Hiring sync")
    }

    func testSanitizeStripsLeadingTitleLabelAndCollapsesToSingleLine() {
        XCTAssertEqual(MeetingTitleGenerator.sanitize("Title: Budget   Planning\nextra"), "Budget Planning")
        XCTAssertEqual(MeetingTitleGenerator.sanitize("Meeting title: Sprint Kickoff"), "Sprint Kickoff")
    }

    func testSanitizeReturnsNilForEmptyOrPunctuationOnly() {
        XCTAssertNil(MeetingTitleGenerator.sanitize("   "))
        XCTAssertNil(MeetingTitleGenerator.sanitize("\"\""))
    }

    func testSanitizeCapsLengthAtAWordBoundary() throws {
        let long = String(repeating: "word ", count: 40)  // 200 chars
        let title = try XCTUnwrap(MeetingTitleGenerator.sanitize(long))
        XCTAssertLessThanOrEqual(title.count, 72)
        XCTAssertFalse(title.hasSuffix(" "), "no trailing space")
        XCTAssertTrue(title.split(separator: " ").allSatisfy { $0 == "word" }, "no partial word at the cut")
    }

    // MARK: isPlaceholderTitle (pure)

    func testIsPlaceholderTitleMatchesDateFallbackAndEmpty() {
        XCTAssertTrue(MeetingTitleGenerator.isPlaceholderTitle("Meeting 2026-05-29 16:12"))
        XCTAssertTrue(MeetingTitleGenerator.isPlaceholderTitle(""))
        XCTAssertTrue(MeetingTitleGenerator.isPlaceholderTitle(nil))
    }

    func testIsPlaceholderTitleFalseForRealTitle() {
        XCTAssertFalse(MeetingTitleGenerator.isPlaceholderTitle("Q3 Budget Planning"))
        XCTAssertFalse(MeetingTitleGenerator.isPlaceholderTitle("Meeting with Sarah about pricing"))
    }

    // MARK: generate (scripted router)

    func testGenerateReturnsSanitizedModelTitle() async {
        let router = ScriptedModelRouter(scripted: [LLMDelta(textIncrement: "  \"Q3 Budget Planning\".  ")])
        let title = await MeetingTitleGenerator(router: router).generate(transcript: transcript)
        XCTAssertEqual(title, "Q3 Budget Planning")
    }

    func testGenerateReturnsNilForThinTranscriptWithoutCallingModel() async {
        let router = ScriptedModelRouter(scripted: [LLMDelta(textIncrement: "Should not be used")])
        let title = await MeetingTitleGenerator(router: router).generate(transcript: "hi there")
        XCTAssertNil(title)
        let captured = await router.lastRequest
        XCTAssertNil(captured, "too-thin transcript must not hit the model")
    }

    func testGenerateReturnsNilOnModelFailure() async {
        let router = ScriptedModelRouter(scripted: [], failure: .modelRouteUnresolved(taskClass: "titleGeneration"))
        let title = await MeetingTitleGenerator(router: router).generate(transcript: transcript)
        XCTAssertNil(title)
    }

    func testGenerateUsesTitleTaskClassAndAntiInjectionWrapsTranscript() async {
        let router = ScriptedModelRouter(scripted: [LLMDelta(textIncrement: "Budget Talk")])
        _ = await MeetingTitleGenerator(router: router).generate(transcript: transcript)
        let request = await router.lastRequest
        XCTAssertEqual(request?.taskClass, .titleGeneration)
        let userContent = request?.messages.first { $0.role == .user }?.content ?? ""
        XCTAssertTrue(
            userContent.contains("<UNTRUSTED-DATA source=\"transcript\">"), "transcript must be anti-injection wrapped")
        XCTAssertTrue(userContent.contains("Q3 budget"), "wrapped transcript content present")
    }
}
