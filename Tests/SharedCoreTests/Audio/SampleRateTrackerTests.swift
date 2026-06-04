import XCTest

@testable import SharedCore

final class SampleRateTrackerTests: XCTestCase {

    func testNoDriftReportedBeforeMinimumDuration() {
        let tracker = SampleRateTracker(declaredRate: 48_000, minimumDuration: 3.0, divergenceThreshold: 0.05)
        let report = tracker.ingest(frameCount: 48_000, wallClock: 1.0)
        XCTAssertEqual(report, .insufficient)
    }

    func testNoDriftReportedWhenWithinThreshold() {
        let tracker = SampleRateTracker(declaredRate: 48_000, minimumDuration: 3.0, divergenceThreshold: 0.05)
        let report = tracker.ingest(frameCount: 144_000, wallClock: 3.0)
        switch report {
        case .stable(let measured):
            XCTAssertEqual(measured, 48_000, accuracy: 1)
        default:
            XCTFail("Expected .stable, got \(report)")
        }
    }

    func testDriftReportedWhenAboveThreshold() {
        let tracker = SampleRateTracker(declaredRate: 48_000, minimumDuration: 3.0, divergenceThreshold: 0.05)
        let report = tracker.ingest(frameCount: 100_000, wallClock: 3.0)
        switch report {
        case .drift(let measured):
            XCTAssertEqual(measured, 33_333, accuracy: 100)
        default:
            XCTFail("Expected .drift, got \(report)")
        }
    }

    func testDriftAccumulatesAcrossMultipleIngests() {
        let tracker = SampleRateTracker(declaredRate: 48_000, minimumDuration: 3.0, divergenceThreshold: 0.05)
        var lastReport: SampleRateTracker.Report = .insufficient
        for _ in 0..<6 {
            lastReport = tracker.ingest(frameCount: 21_600, wallClock: 0.5)
        }
        switch lastReport {
        case .drift(let measured):
            XCTAssertEqual(measured, 43_200, accuracy: 50)
        default:
            XCTFail("Expected .drift accumulated over multiple ingests, got \(lastReport)")
        }
    }

    func testResetClearsState() {
        let tracker = SampleRateTracker(declaredRate: 48_000, minimumDuration: 3.0, divergenceThreshold: 0.05)
        _ = tracker.ingest(frameCount: 100_000, wallClock: 3.0)
        tracker.reset()
        XCTAssertEqual(tracker.ingest(frameCount: 1, wallClock: 0.1), .insufficient)
    }
}
