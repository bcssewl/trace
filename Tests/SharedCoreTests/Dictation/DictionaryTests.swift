import Foundation
import XCTest

@testable import SharedCore

final class VoicePunctuationTests: XCTestCase {
    func testGlyphsAreExactlyTheExpectedStrings() {
        XCTAssertEqual(VoicePunctuation.period.glyph, ".")
        XCTAssertEqual(VoicePunctuation.comma.glyph, ",")
        XCTAssertEqual(VoicePunctuation.emDash.glyph, "—")
        XCTAssertEqual(VoicePunctuation.newLine.glyph, "\n")
        XCTAssertEqual(VoicePunctuation.newParagraph.glyph, "\n\n")
        XCTAssertEqual(VoicePunctuation.bulletPoint.glyph, "\n- ")
    }

    func testAllCasesHaveAtLeastOneTrigger() {
        for case_ in VoicePunctuation.allCases {
            XCTAssertFalse(case_.triggers.isEmpty, "\(case_) has no triggers")
        }
    }
}

final class DictionaryEntryTests: XCTestCase {
    func testPrioritiesAreOrdered() {
        let voice = DictionaryEntry.voicePunctuation(.period)
        let rule = DictionaryEntry.replacement(
            ReplacementRule(pattern: "foo", replacement: "bar", createdAt: 0)
        )
        let vocab = DictionaryEntry.vocab(VocabEntry(heard: "x", corrected: "y", learnedAt: 0))
        XCTAssertLessThan(voice.priority, rule.priority)
        XCTAssertLessThan(rule.priority, vocab.priority)
    }

    func testReplacementRuleCompiles() throws {
        let rule = ReplacementRule(pattern: "\\bhello\\b", replacement: "Hi", createdAt: 0)
        let regex = try rule.compiled()
        XCTAssertNotNil(regex)
    }

    func testReplacementRuleInvalidPatternThrows() {
        let rule = ReplacementRule(pattern: "[a-z", replacement: "x", createdAt: 0)
        XCTAssertThrowsError(try rule.compiled()) { err in
            guard case TraceError.configInvalid = err else {
                XCTFail("wrong error: \(err)")
                return
            }
        }
    }
}

final class PersonalDictionaryTests: XCTestCase {
    func testEmptyDictionaryReturnsTextUnchanged() async throws {
        let dict = PersonalDictionary(database: nil, voiceCommands: [])
        try await dict.bootstrap()
        let (out, count) = try await dict.apply("Hello world.")
        XCTAssertEqual(out, "Hello world.")
        XCTAssertEqual(count, 0)
    }

    func testPeriodTriggerIsReplaced() async throws {
        let dict = PersonalDictionary(database: nil)
        try await dict.bootstrap()
        let (out, count) = try await dict.apply("hello period")
        XCTAssertEqual(out, "hello .")
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testEmDashTriggerIsReplaced() async throws {
        let dict = PersonalDictionary(database: nil)
        try await dict.bootstrap()
        let (out, _) = try await dict.apply("this em dash that")
        XCTAssertTrue(out.contains("—"))
    }

    func testNewLineTriggerInsertsNewline() async throws {
        let dict = PersonalDictionary(database: nil)
        try await dict.bootstrap()
        let (out, _) = try await dict.apply("first new line second")
        XCTAssertTrue(out.contains("\n"))
    }

    func testVocabCorrectionAppliesCaseInsensitively() async throws {
        let dict = PersonalDictionary(database: nil, voiceCommands: [])
        try await dict.bootstrap()
        try await dict.recordCorrection(heard: "optivise", corrected: "Optivise", at: 0)
        let (out, count) = try await dict.apply("the optivise team shipped")
        XCTAssertEqual(out, "the Optivise team shipped")
        XCTAssertEqual(count, 1)
    }

    func testReplacementRuleAppliesBeforeVocab() async throws {
        let dict = PersonalDictionary(database: nil, voiceCommands: [])
        try await dict.bootstrap()
        await dict.setReplacementRules(
            [ReplacementRule(pattern: "\\bgonna\\b", replacement: "going to", createdAt: 0)]
        )
        let (out, _) = try await dict.apply("we are gonna ship")
        XCTAssertEqual(out, "we are going to ship")
    }

    func testCorrectionIsPersistedAndReloaded() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dict-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("idx.sqlite")
        let db = try await SqliteDatabase.open(at: dbURL)
        try await SchemaV1.bootstrap(database: db)

        let first = PersonalDictionary(database: db, voiceCommands: [])
        try await first.bootstrap()
        try await first.recordCorrection(heard: "claude", corrected: "Claude", at: 100)
        try await first.recordCorrection(heard: "claude", corrected: "Claude", at: 200)

        let second = PersonalDictionary(database: db, voiceCommands: [])
        try await second.bootstrap()
        let entries = await second.vocabEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.hitCount, 2)

        try await db.close()
    }
}

final class LearnedCorrectionsTests: XCTestCase {
    func testCasingFlipIsSuggested() {
        let suggestions = LearnedCorrections.suggestions(
            raw: "the optivise team",
            edited: "the Optivise team"
        )
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.heard, "optivise")
        XCTAssertEqual(suggestions.first?.corrected, "Optivise")
    }

    func testTokenCountMismatchYieldsNoSuggestions() {
        let suggestions = LearnedCorrections.suggestions(
            raw: "we shipped",
            edited: "we have shipped"
        )
        XCTAssertEqual(suggestions, [])
    }

    func testEmptyInputsReturnEmpty() {
        XCTAssertTrue(LearnedCorrections.suggestions(raw: "", edited: "").isEmpty)
        XCTAssertTrue(LearnedCorrections.suggestions(raw: "abc", edited: "").isEmpty)
    }

    func testWordSwapIsSuggested() {
        let suggestions = LearnedCorrections.suggestions(
            raw: "send to roger",
            edited: "send to Rajiv"
        )
        XCTAssertTrue(
            suggestions.contains(where: { $0.heard == "roger" && $0.corrected == "Rajiv" })
        )
    }

    func testDeduplicatesIdenticalSuggestions() {
        let suggestions = LearnedCorrections.suggestions(
            raw: "optivise needs optivise",
            edited: "Optivise needs Optivise"
        )
        XCTAssertEqual(suggestions.count, 1)
    }
}
