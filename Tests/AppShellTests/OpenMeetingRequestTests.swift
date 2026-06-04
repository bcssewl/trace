import XCTest

@testable import AppShell

/// The typed replacement (BAS-32) for the stringly-typed `.traceOpenMeeting`
/// `userInfo: ["meetingId", "timestamp"]` payload.
///
/// The request travels as the
/// notification `object`; `from(_:)` is the one decode seam.
final class OpenMeetingRequestTests: XCTestCase {

    func testExtractsTypedPayloadFromObject() {
        let note = Notification(
            name: .traceOpenMeeting,
            object: OpenMeetingRequest(meetingId: "M1", timestamp: 42)
        )
        let req = OpenMeetingRequest.from(note)
        XCTAssertEqual(req?.meetingId, "M1")
        XCTAssertEqual(req?.timestamp, 42)
    }

    func testNilWhenObjectMissing() {
        let note = Notification(name: .traceOpenMeeting, object: nil)
        XCTAssertNil(OpenMeetingRequest.from(note))
    }

    func testNilWhenObjectWrongType() {
        let note = Notification(name: .traceOpenMeeting, object: "not a request")
        XCTAssertNil(OpenMeetingRequest.from(note))
    }

    func testTimestampDefaultsToNil() {
        XCTAssertNil(OpenMeetingRequest(meetingId: "M2").timestamp)
    }
}
