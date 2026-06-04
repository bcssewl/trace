import Foundation
import XCTest

@testable import MeetingModule

final class MeetingCategorizationSignalProviderTests: XCTestCase {

    private let provider = MeetingCategorizationSignalProvider()

    private func project(_ name: String) -> ProjectCandidate {
        ProjectCandidate(id: UUID(), name: name)
    }

    private func input(
        transcript: String = "",
        emails: [String] = [],
        manualOverride: Bool = false
    ) -> MeetingCategorizationInput {
        MeetingCategorizationInput(
            manualOverride: manualOverride,
            transcriptPrefix: transcript,
            attendeeEmails: emails
        )
    }

    // MARK: - regex signal

    func testRegexFullNameSubstringScoresOne() async throws {
        let signals = try await provider.signals(
            for: input(transcript: "Welcome to the Apollo Migration weekly sync."),
            project: project("Apollo Migration")
        )
        XCTAssertEqual(signals.regex, 1.0, accuracy: 1e-9)
    }

    func testRegexIsCaseInsensitive() async throws {
        let signals = try await provider.signals(
            for: input(transcript: "discussing the APOLLO migration today"),
            project: project("Apollo Migration")
        )
        XCTAssertEqual(signals.regex, 1.0, accuracy: 1e-9)
    }

    func testRegexPartialTokenMatchIsScaledBetweenZeroAndOne() async throws {
        // Only "apollo" appears; "migration" does not -> 1 of 2 tokens.
        let signals = try await provider.signals(
            for: input(transcript: "the apollo team met to plan things"),
            project: project("Apollo Migration")
        )
        XCTAssertGreaterThan(signals.regex, 0.0)
        XCTAssertLessThan(signals.regex, 1.0)
        XCTAssertEqual(signals.regex, 0.5, accuracy: 1e-9)
    }

    func testRegexUnrelatedTranscriptScoresZero() async throws {
        let signals = try await provider.signals(
            for: input(transcript: "general standup about lunch plans and parking"),
            project: project("Apollo Migration")
        )
        XCTAssertEqual(signals.regex, 0.0, accuracy: 1e-9)
    }

    func testRegexEmptyTranscriptScoresZero() async throws {
        let signals = try await provider.signals(
            for: input(transcript: ""),
            project: project("Apollo")
        )
        XCTAssertEqual(signals.regex, 0.0, accuracy: 1e-9)
    }

    // MARK: - attendee signal

    func testAttendeeDomainOverlapScoresAboveZero() async throws {
        // Domain label "apollo" overlaps the project-name token "apollo".
        let signals = try await provider.signals(
            for: input(emails: ["jane@apollo.com", "joe@apollo.com"]),
            project: project("Apollo")
        )
        XCTAssertGreaterThan(signals.attendee, 0.0)
    }

    func testAttendeeLocalPartOverlapScoresAboveZero() async throws {
        let signals = try await provider.signals(
            for: input(emails: ["apollo.lead@example.org"]),
            project: project("Apollo")
        )
        XCTAssertGreaterThan(signals.attendee, 0.0)
    }

    func testAttendeeNoOverlapScoresZero() async throws {
        let signals = try await provider.signals(
            for: input(emails: ["sam@unrelated.io", "kim@elsewhere.net"]),
            project: project("Apollo Migration")
        )
        XCTAssertEqual(signals.attendee, 0.0, accuracy: 1e-9)
    }

    func testAttendeeEmptyEmailsScoresZero() async throws {
        let signals = try await provider.signals(
            for: input(emails: []),
            project: project("Apollo")
        )
        XCTAssertEqual(signals.attendee, 0.0, accuracy: 1e-9)
    }

    func testAttendeeTldLabelDoesNotCountAsOverlap() async throws {
        // Project name "Com" must not match the dropped ".com" TLD label.
        let signals = try await provider.signals(
            for: input(emails: ["someone@business.com"]),
            project: project("Com")
        )
        XCTAssertEqual(signals.attendee, 0.0, accuracy: 1e-9)
    }

    // MARK: - placeholder signals (no backing fields exist on the types)

    func testContentRecurringManualHistoryAreAlwaysZero() async throws {
        let signals = try await provider.signals(
            for: input(transcript: "Apollo Migration", emails: ["a@apollo.com"]),
            project: project("Apollo Migration")
        )
        XCTAssertEqual(signals.content, 0.0, accuracy: 1e-9)
        XCTAssertEqual(signals.recurring, 0.0, accuracy: 1e-9)
        XCTAssertEqual(signals.manualHistory, 0.0, accuracy: 1e-9)
    }

    // MARK: - bounds & determinism

    func testAllSignalsWithinUnitInterval() async throws {
        let signals = try await provider.signals(
            for: input(
                transcript: "apollo migration apollo migration kickoff",
                emails: ["apollo.migration.team@apollo-migration.com"]
            ),
            project: project("Apollo Migration")
        )
        for value in [signals.regex, signals.attendee, signals.content, signals.recurring, signals.manualHistory] {
            XCTAssertGreaterThanOrEqual(value, 0.0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
    }

    func testDeterministicForSameInput() async throws {
        let meeting = input(transcript: "apollo team sync", emails: ["x@apollo.com"])
        let candidate = project("Apollo Migration")
        let first = try await provider.signals(for: meeting, project: candidate)
        let second = try await provider.signals(for: meeting, project: candidate)
        XCTAssertEqual(first, second)
    }

    // MARK: - integration with ProjectCategorizer scoring

    func testFeedsProjectCategorizerHigherConfidenceForMatch() async throws {
        let categorizer = ProjectCategorizer(signalProvider: provider)
        let matching = project("Apollo Migration")
        let unrelated = project("Zephyr Rollout")
        let meeting = input(
            transcript: "Apollo Migration kickoff with the apollo team",
            emails: ["lead@apollo.com"]
        )
        let result = try await categorizer.categorize(meeting, projects: [matching, unrelated])

        let top = try XCTUnwrap(result.scores.first)
        XCTAssertEqual(top.project.id, matching.id)
        XCTAssertGreaterThan(top.confidence, 0.0)
    }

    // MARK: - pure helper unit coverage

    func testEmailTokensDropsTld() {
        let tokens = Set(MeetingCategorizationSignalProvider.emailTokens(from: "jane.doe@acme-corp.com"))
        XCTAssertTrue(tokens.contains("jane"))
        XCTAssertTrue(tokens.contains("doe"))
        XCTAssertTrue(tokens.contains("acme"))
        XCTAssertTrue(tokens.contains("corp"))
        XCTAssertFalse(tokens.contains("com"))
    }

    func testJaccardKnownValue() {
        let a: Set<String> = ["apollo", "migration"]
        let b: Set<String> = ["apollo", "team"]
        // intersection = 1 (apollo), union = 3 -> 1/3
        XCTAssertEqual(MeetingCategorizationSignalProvider.jaccard(a, b), 1.0 / 3.0, accuracy: 1e-9)
    }

    func testJaccardEmptySetsIsZero() {
        XCTAssertEqual(MeetingCategorizationSignalProvider.jaccard([], []), 0.0, accuracy: 1e-9)
    }

    func testTokensDropSingleCharNoise() {
        let tokens = MeetingCategorizationSignalProvider.tokens(from: "a big X migration")
        XCTAssertFalse(tokens.contains("a"))
        XCTAssertFalse(tokens.contains("x"))
        XCTAssertTrue(tokens.contains("big"))
        XCTAssertTrue(tokens.contains("migration"))
    }
}
