import XCTest

@testable import SharedCore

final class ProjectOverridesTests: XCTestCase {

    func testEmptyJSONDecodesToEmpty() {
        XCTAssertTrue(ProjectOverrides.decode(json: "{}").isEmpty)
    }

    func testMalformedJSONFallsBackToEmpty() {
        XCTAssertEqual(ProjectOverrides.decode(json: "not json at all"), .empty)
    }

    func testRoundTripPreservesAllFields() {
        var overrides = ProjectOverrides()
        overrides.modelRouteOverrides = [
            .meetingAugmentedMerge: LLMRoute(
                provider: .openAICompat, model: "anthropic/claude-sonnet-4.6",
                baseURL: URL(string: "https://openrouter.ai/api/v1"), keychainAccount: "openrouter"
            )
        ]
        overrides.asrRouteOverrides = [
            .fileBatchEnglish: ASRRoute(engineIdentifier: "whisperkit", modelIdentifier: "large-v3", allowsCloud: false)
        ]
        overrides.vocabulary = ["Optivise", "Parakeet"]
        overrides.calendarMatchers = [.titleRegex("Standup"), .attendeeDomain("optivise.app")]

        let decoded = ProjectOverrides.decode(json: overrides.encodedJSON())
        XCTAssertEqual(decoded, overrides)
    }

    func testPartialJSONDecodesWithDefaults() {
        let decoded = ProjectOverrides.decode(json: #"{"vocabulary":["foo"]}"#)
        XCTAssertEqual(decoded.vocabulary, ["foo"])
        XCTAssertTrue(decoded.modelRouteOverrides.isEmpty)
        XCTAssertTrue(decoded.asrRouteOverrides.isEmpty)
        XCTAssertTrue(decoded.calendarMatchers.isEmpty)
    }

    func testIsEmptyReflectsContents() {
        XCTAssertTrue(ProjectOverrides().isEmpty)
        var o = ProjectOverrides()
        o.vocabulary = ["x"]
        XCTAssertFalse(o.isEmpty)
    }
}
