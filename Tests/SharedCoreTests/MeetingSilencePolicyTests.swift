import XCTest

@testable import SharedCore

/// `MeetingSilencePolicy` decides, from how long it's been since any captured
/// speech, whether to drop the soft "Call ended?" notch prompt or hard-stop the
/// meeting (BAS-13).
///
/// The hard stop is a separate, longer threshold and takes
/// priority; a nil hard threshold means hard auto-stop is disabled.
final class MeetingSilencePolicyTests: XCTestCase {

    func testBelowSoftThresholdDoesNothing() {
        let action = MeetingSilencePolicy.evaluate(
            secondsSinceSpeech: 20, softThreshold: 60, hardThreshold: 600, alreadyPrompted: false
        )
        XCTAssertEqual(action, .none)
    }

    func testAtSoftThresholdPromptsOnceWhenNotYetPrompted() {
        let action = MeetingSilencePolicy.evaluate(
            secondsSinceSpeech: 65, softThreshold: 60, hardThreshold: 600, alreadyPrompted: false
        )
        XCTAssertEqual(action, .promptSoftEnd)
    }

    func testAtSoftThresholdDoesNothingWhenAlreadyPrompted() {
        let action = MeetingSilencePolicy.evaluate(
            secondsSinceSpeech: 120, softThreshold: 60, hardThreshold: 600, alreadyPrompted: true
        )
        XCTAssertEqual(action, .none)
    }

    func testAtHardThresholdHardStops() {
        let action = MeetingSilencePolicy.evaluate(
            secondsSinceSpeech: 600, softThreshold: 60, hardThreshold: 600, alreadyPrompted: false
        )
        XCTAssertEqual(action, .hardStop)
    }

    func testHardStopTakesPriorityEvenAfterPrompt() {
        // Past both thresholds and already soft-prompted → still hard-stops.
        let action = MeetingSilencePolicy.evaluate(
            secondsSinceSpeech: 900, softThreshold: 60, hardThreshold: 600, alreadyPrompted: true
        )
        XCTAssertEqual(action, .hardStop)
    }

    func testNilHardThresholdDisablesHardStop() {
        // Auto-stop off: a long silence only ever soft-prompts (once).
        let prompted = MeetingSilencePolicy.evaluate(
            secondsSinceSpeech: 5000, softThreshold: 60, hardThreshold: nil, alreadyPrompted: true
        )
        XCTAssertEqual(prompted, .none)
        let firstPrompt = MeetingSilencePolicy.evaluate(
            secondsSinceSpeech: 5000, softThreshold: 60, hardThreshold: nil, alreadyPrompted: false
        )
        XCTAssertEqual(firstPrompt, .promptSoftEnd)
    }
}
