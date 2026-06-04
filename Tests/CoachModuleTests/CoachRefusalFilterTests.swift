import XCTest

@testable import CoachModule

/// BAS-76 — the Coach must not surface Apple FM guardrail refusals as cards.
final class CoachRefusalFilterTests: XCTestCase {
    func testAppleFMRefusalsAreDetected() {
        XCTAssertTrue(CoachOrchestrator.isLikelyRefusal("I cannot help with that request."))
        XCTAssertTrue(CoachOrchestrator.isLikelyRefusal("I can't help with that request"))
        XCTAssertTrue(CoachOrchestrator.isLikelyRefusal("I'm sorry, but I cannot assist with this."))
        XCTAssertTrue(CoachOrchestrator.isLikelyRefusal("I am not able to provide that."))
    }

    func testRealCoachingIsNotFlagged() {
        XCTAssertFalse(CoachOrchestrator.isLikelyRefusal("Take a breath — slow down and trim the \"um\"s."))
        XCTAssertFalse(CoachOrchestrator.isLikelyRefusal("Ask about the capital of Spain to keep the topic going."))
        XCTAssertFalse(CoachOrchestrator.isLikelyRefusal("Madrid is the capital — confirm and move on."))
        XCTAssertFalse(CoachOrchestrator.isLikelyRefusal(""))
    }

    // BAS-76 follow-up: the substance gate that stops "yeah"-type junk from
    // triggering the embedding storm.
    func testBackchannelsAreNotSubstantive() {
        for junk in ["yeah", "Yeah.", "ok", "okay", "um", "uh", "right", "sure", "嗯", "对", "好的"] {
            XCTAssertFalse(CoachOrchestrator.isSubstantive(junk), "\(junk) should be skipped")
        }
        XCTAssertFalse(CoachOrchestrator.isSubstantive(""))
        XCTAssertFalse(CoachOrchestrator.isSubstantive("I think so"))  // too short
    }

    func testRealSentencesAreSubstantive() {
        XCTAssertTrue(CoachOrchestrator.isSubstantive("No, I don't go to the beach, I'm in Madrid."))
        XCTAssertTrue(CoachOrchestrator.isSubstantive("What is the capital of Spain again?"))
        XCTAssertTrue(CoachOrchestrator.isSubstantive("我昨天去了北京的长城那边玩"))  // CJK, no spaces
    }
}
