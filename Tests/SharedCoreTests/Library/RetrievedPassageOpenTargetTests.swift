import XCTest

@testable import SharedCore

/// `RetrievedPassage.openTarget` (BAS-27) decides what a citation's "open"
/// affordance does: deep-link a meeting at its timestamp, open a playbook source
/// file, or nothing.
///
/// It's the one place the meeting-vs-playbook branch lives so
/// the inline chip + the Citations-list row dispatch identically.
final class RetrievedPassageOpenTargetTests: XCTestCase {

    private func passage(
        kind: KbChunk.SourceKind,
        meetingId: String? = nil,
        tsSeconds: Double? = nil,
        sourceFile: String? = nil,
        breadcrumb: String? = nil
    ) -> RetrievedPassage {
        RetrievedPassage(
            id: "p", kind: kind, text: "body", meetingId: meetingId,
            tsSeconds: tsSeconds, sourceFile: sourceFile, breadcrumb: breadcrumb,
            score: 0, origin: .dense
        )
    }

    func testTranscriptOpensMeetingAtTimestamp() {
        let target = passage(kind: .transcript, meetingId: "M1", tsSeconds: 12).openTarget
        XCTAssertEqual(target, .meeting(id: "M1", tsSeconds: 12))
    }

    func testNotesOpensMeetingWithoutTimestamp() {
        let target = passage(kind: .notes, meetingId: "M1").openTarget
        XCTAssertEqual(target, .meeting(id: "M1", tsSeconds: nil))
    }

    func testSummaryOpensMeeting() {
        let target = passage(kind: .summary, meetingId: "M1").openTarget
        XCTAssertEqual(target, .meeting(id: "M1", tsSeconds: nil))
    }

    func testPlaybookOpensSourceFileWithBreadcrumb() {
        let target = passage(
            kind: .playbook, sourceFile: "sales/pricing.md", breadcrumb: "Sales > Pricing"
        ).openTarget
        XCTAssertEqual(target, .file(path: "sales/pricing.md", breadcrumb: "Sales > Pricing"))
    }

    func testPlaybookWithoutSourceFileHasNoTarget() {
        XCTAssertNil(passage(kind: .playbook, sourceFile: nil).openTarget)
        XCTAssertNil(passage(kind: .playbook, sourceFile: "").openTarget)
    }

    func testMeetingKindWithoutMeetingIdHasNoTarget() {
        // A transcript-kind passage missing its meeting id can't be opened.
        XCTAssertNil(passage(kind: .transcript, meetingId: nil).openTarget)
    }
}
