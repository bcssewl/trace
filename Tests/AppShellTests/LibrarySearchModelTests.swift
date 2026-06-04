import XCTest

@testable import AppShell
@testable import SharedCore

@MainActor
final class LibrarySearchModelTests: XCTestCase {

    func testAutodetectQAFromQuestionMark() {
        XCTAssertEqual(LibrarySearchModel.autodetectMode("brex partnership?"), .qa)
    }

    func testAutodetectQAFromInterrogativePrefix() {
        XCTAssertEqual(LibrarySearchModel.autodetectMode("what did sarah commit to"), .qa)
        XCTAssertEqual(LibrarySearchModel.autodetectMode("How does pricing work"), .qa)
        XCTAssertEqual(LibrarySearchModel.autodetectMode("Summarize the Brex thread"), .qa)
    }

    func testAutodetectKeywordFromFragment() {
        XCTAssertEqual(LibrarySearchModel.autodetectMode("brex partnership"), .keyword)
        XCTAssertEqual(LibrarySearchModel.autodetectMode("cohort retention chart"), .keyword)
    }

    func testSlashPrefixForcesKeyword() {
        XCTAssertEqual(LibrarySearchModel.autodetectMode("/what is this"), .keyword)
    }

    func testEmptyDefaultsToKeyword() {
        XCTAssertEqual(LibrarySearchModel.autodetectMode("   "), .keyword)
    }

    func testManualOverrideWinsOverAutodetect() {
        let model = LibrarySearchModel()
        model.query = "brex partnership"  // would auto-detect keyword
        model.manualMode = .qa
        XCTAssertEqual(model.effectiveMode, .qa)
    }

    func testClearingQueryResetsManualOverride() {
        let model = LibrarySearchModel()
        model.manualMode = .qa
        model.query = "   "
        model.queryDidChange()
        XCTAssertNil(model.manualMode)
    }

    func testNormalizedQueryStripsKeywordSlash() {
        let model = LibrarySearchModel()
        model.query = "/ brex partnership"
        XCTAssertEqual(model.normalizedQuery, "brex partnership")
    }

    func testScopeReflectsProjectAndRecency() {
        let model = LibrarySearchModel()
        model.selectedProjectId = "P1"
        model.last90Days = true
        XCTAssertEqual(model.scope.projectIds, ["P1"])
        XCTAssertEqual(model.scope.lastNDays, 90)
    }

    func testRefusalDetection() {
        XCTAssertTrue(LibrarySearchModel.isLikelyRefusal("The context does not provide a response to \"hi\"."))
        XCTAssertTrue(LibrarySearchModel.isLikelyRefusal("I couldn't find anything about that in your meetings."))
        XCTAssertTrue(LibrarySearchModel.isLikelyRefusal("No relevant information was discussed."))
        XCTAssertFalse(LibrarySearchModel.isLikelyRefusal("Sarah agreed to hold pricing until retention improves [1]."))
    }

    func testKeywordHitsGroupByItemPreservingOrder() {
        let model = LibrarySearchModel()
        model.keywordHits = [
            KeywordHit(
                id: "transcript:A:1", source: .transcript, itemId: "A", projectId: nil, title: "Mtg A", snippet: "x",
                timestamp: 1),
            KeywordHit(
                id: "transcript:A:2", source: .transcript, itemId: "A", projectId: nil, title: "Mtg A", snippet: "y",
                timestamp: 2),
            KeywordHit(
                id: "notes:B", source: .notes, itemId: "B", projectId: nil, title: "Mtg B", snippet: "z", timestamp: nil
            ),
        ]
        let groups = model.groupedKeywordHits
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, "A")
        XCTAssertEqual(groups[0].source, .transcript)
        XCTAssertEqual(groups[0].hitCount, 2)
        XCTAssertEqual(groups[0].firstTimestamp, 1)
        XCTAssertEqual(groups[1].id, "B")
    }

    func testKeywordScopeDefaultsToAllSurfacesWhenNoChips() {
        let model = LibrarySearchModel()
        XCTAssertEqual(model.keywordScope.sources, [.meeting, .dictation, .voiceMemo, .file])
    }

    func testKeywordScopeUsesSelectedChips() {
        let model = LibrarySearchModel()
        model.toggleSource(.dictation)
        model.toggleSource(.file)
        XCTAssertEqual(model.keywordScope.sources, [.dictation, .file])
    }

    func testToggleSourceRemovesOnSecondTap() {
        let model = LibrarySearchModel()
        model.toggleSource(.dictation)
        model.toggleSource(.dictation)
        XCTAssertTrue(model.selectedSources.isEmpty)
        XCTAssertEqual(model.keywordScope.sources, [.meeting, .dictation, .voiceMemo, .file])
    }

    func testKeywordScopeCarriesProjectAndRecency() {
        let model = LibrarySearchModel()
        model.selectProject("P1")
        model.last90Days = true
        XCTAssertEqual(model.keywordScope.projectIds, ["P1"])
        XCTAssertEqual(model.keywordScope.lastNDays, 90)
    }

    func testQAScopeStaysMeetingsOnlyRegardlessOfChips() {
        let model = LibrarySearchModel()
        model.toggleSource(.dictation)
        // The Q&A scope must NOT pick up keyword type-filter chips.
        XCTAssertTrue(model.scope.sources.isEmpty)
    }

    func testGroupsAcrossMixedSources() {
        let model = LibrarySearchModel()
        model.keywordHits = [
            KeywordHit(
                id: "dictation:D1", source: .dictation, itemId: "D1", projectId: nil, title: "Quick note",
                snippet: "buy milk", timestamp: nil),
            KeywordHit(
                id: "file:F1", source: .file, itemId: "F1", projectId: nil, title: "interview.m4a",
                snippet: "the budget", timestamp: nil),
        ]
        let groups = model.groupedKeywordHits
        XCTAssertEqual(groups.map(\.source), [.dictation, .file])
        XCTAssertEqual(groups.map(\.id), ["D1", "F1"])
    }
}
