import Foundation
import XCTest

@testable import CoachModule

// MARK: - Banner model (dismissal + rate-limit rules)

final class CoachHealthBannerModelTests: XCTestCase {
    func testHealthyHasNoMessage() {
        XCTAssertNil(CoachHealthBannerModel().activeMessage)
    }

    func testListenerFailureShowsPausedMessageInBritishEnglish() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .listener, reason: "x"))
        XCTAssertEqual(
            model.activeMessage,
            "Coach paused — its model isn't responding. Check Settings → AI models.")
    }

    func testSearchOnlyFailureShowsDegradedMessage() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .search, reason: "x"))
        XCTAssertEqual(
            model.activeMessage,
            "Coach can't search your notes — cards may miss things from your documents, but answers and suggestions still work. Check Settings → AI models."
        )
    }

    func testListenerOutranksSearch() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .search, reason: "x"))
        model.apply(.stageUnavailable(stage: .listener, reason: "x"))
        XCTAssertEqual(
            model.activeMessage,
            "Coach paused — its model isn't responding. Check Settings → AI models.")
    }

    func testDismissHidesUntilSituationChanges() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .listener, reason: "x"))
        model.dismissCurrent()
        XCTAssertNil(model.activeMessage, "dismissed")
        // Same failing set → stays dismissed (no banner per check).
        model.apply(.stageUnavailable(stage: .listener, reason: "again"))
        XCTAssertNil(model.activeMessage, "unchanged situation must not re-raise a dismissed banner")
        // A NEW failing stage is new information → banner returns.
        model.apply(.stageUnavailable(stage: .search, reason: "x"))
        XCTAssertNotNil(model.activeMessage, "a new failing stage must re-raise the banner")
    }

    func testRecoveryClearsBannerAndDismissal() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .listener, reason: "x"))
        model.dismissCurrent()
        model.apply(.stageRecovered(stage: .listener))
        XCTAssertNil(model.activeMessage)
        // A fresh outage after full recovery shows again despite the old dismissal.
        model.apply(.stageUnavailable(stage: .listener, reason: "x"))
        XCTAssertNotNil(model.activeMessage)
    }

    func testResetForNewMeetingClearsEverything() {
        var model = CoachHealthBannerModel()
        model.apply(.stageUnavailable(stage: .search, reason: "x"))
        model.dismissCurrent()
        model.resetForNewMeeting()
        XCTAssertNil(model.activeMessage)
        XCTAssertTrue(model.failingStages.isEmpty)
    }
}

// MARK: - Dismiss-for-meeting state

final class CoachOverlayDismissStateTests: XCTestCase {
    func testDefaultsToAcceptingCards() {
        XCTAssertTrue(CoachOverlayDismissState().acceptsCards)
        XCTAssertFalse(CoachOverlayDismissState().isDismissedForMeeting)
    }

    func testDismissForMeetingStopsAcceptingCards() {
        var state = CoachOverlayDismissState()
        state.dismissForMeeting()
        XCTAssertTrue(state.isDismissedForMeeting)
        XCTAssertFalse(state.acceptsCards, "dismissed means hidden for the meeting — no cards pop")
    }

    func testReopenRestoresAcceptance() {
        var state = CoachOverlayDismissState()
        state.dismissForMeeting()
        state.reopen()
        XCTAssertTrue(state.acceptsCards)
        XCTAssertFalse(state.isDismissedForMeeting)
    }
}

// MARK: - RecentTrigger label hygiene

final class RecentTriggerLabelTests: XCTestCase {
    func testNormalTitlePreserved() {
        let trigger = RecentTrigger(label: "Pricing question", kind: .answer, wasSurfaced: true)
        XCTAssertEqual(trigger.label, "Pricing question")
    }

    func testEmptyTitleClampsToKindName() {
        XCTAssertEqual(
            RecentTrigger(label: "", kind: .answer, wasSurfaced: true).label, "Answer")
        XCTAssertEqual(
            RecentTrigger(label: "", kind: .recall, wasSurfaced: true).label, "From your notes")
        XCTAssertEqual(
            RecentTrigger(label: "   ", kind: .suggestion, wasSurfaced: false).label, "Suggestion")
    }

    func testWhitespaceAndPunctuationOnlyTitleClampsToKindName() {
        XCTAssertEqual(
            RecentTrigger(label: " \n\t …—-· ", kind: .suggestion, wasSurfaced: false).label,
            "Suggestion")
    }

    func testNewlinesCollapseToSingleSpaces() {
        let trigger = RecentTrigger(
            label: "What they\nasked   about\tpricing", kind: .answer, wasSurfaced: true)
        XCTAssertEqual(trigger.label, "What they asked about pricing")
    }

    func testControlCharactersStripped() {
        let trigger = RecentTrigger(
            label: "Bad\u{0007}model\u{0000}output", kind: .answer, wasSurfaced: true)
        XCTAssertEqual(trigger.label, "Badmodeloutput")
    }

    func testOverlongTitleTruncatesWithEllipsis() {
        let long = String(repeating: "word ", count: 40)  // 200 chars
        let trigger = RecentTrigger(label: long, kind: .answer, wasSurfaced: true)
        XCTAssertLessThanOrEqual(trigger.label.count, 80)
        XCTAssertTrue(trigger.label.hasSuffix("…"))
    }
}
