import XCTest

@testable import SharedCore

final class FileBatchStatusTests: XCTestCase {

    func testTerminalStatesAreOnlyCompletedFailedCancelled() {
        let terminal = FileBatchStatus.allCases.filter(\.isTerminal)
        XCTAssertEqual(Set(terminal), [.completed, .failed, .cancelled])
    }

    func testProgressIsMonotonicAcrossActiveStages() {
        let order: [FileBatchStatus] = [
            .queued, .extracting, .transcribing, .summarizing, .writing,
        ]
        let fractions = order.map(\.progressFraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(fractions.first, 0)
        XCTAssertLessThan(fractions.last ?? 1, 1)
    }

    func testTerminalStagesPinProgressToOne() {
        XCTAssertEqual(FileBatchStatus.completed.progressFraction, 1)
        XCTAssertEqual(FileBatchStatus.failed.progressFraction, 1)
        XCTAssertEqual(FileBatchStatus.cancelled.progressFraction, 1)
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(FileBatchStatus.queued.rawValue, "queued")
        XCTAssertEqual(FileBatchStatus.extracting.rawValue, "extracting")
        XCTAssertEqual(FileBatchStatus.transcribing.rawValue, "transcribing")
        XCTAssertEqual(FileBatchStatus.summarizing.rawValue, "summarizing")
        XCTAssertEqual(FileBatchStatus.writing.rawValue, "writing")
        XCTAssertEqual(FileBatchStatus.completed.rawValue, "completed")
        XCTAssertEqual(FileBatchStatus.failed.rawValue, "failed")
        XCTAssertEqual(FileBatchStatus.cancelled.rawValue, "cancelled")
    }

    func testFailurePayloadCarriesStageAndReason() {
        let failure = FileBatchFailure(stage: .transcribing, reason: "model missing")
        XCTAssertEqual(failure.stage, .transcribing)
        XCTAssertEqual(failure.reason, "model missing")
    }
}
