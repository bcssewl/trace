import SharedCore
import XCTest

@testable import AppShell

@MainActor
final class FileBatchModelTests: XCTestCase {

    private func record(_ id: UUID, status: FileBatchStatus) -> FileRecord {
        FileRecord(
            id: id.uuidString, projectID: nil, title: "t",
            sourcePath: "/tmp/\(id.uuidString).m4a",
            transcriptPath: status == .completed ? "/n.md" : nil,
            engine: "e", durationMs: nil, status: status, errorReason: nil,
            createdAt: Date(), completedAt: nil, kind: .audio, origin: .dragDrop
        )
    }

    private func snapshot(_ id: UUID, status: FileBatchStatus) -> ProcessingSnapshot {
        ProcessingSnapshot(
            id: id, title: "t", sourcePath: "/tmp", kind: .audio, origin: .dragDrop,
            status: status, progressFraction: status.progressFraction,
            updatedAt: Date(), errorReason: nil
        )
    }

    func testEffectiveStatusPrefersLiveWhileInFlight() {
        let model = FileBatchModel()
        let id = UUID()
        let rec = record(id, status: .queued)
        model.records = [rec]
        model.live = [id.uuidString: snapshot(id, status: .transcribing)]
        XCTAssertEqual(model.effectiveStatus(for: rec), .transcribing)
        XCTAssertTrue(model.isInFlight(rec))
        XCTAssertEqual(model.progress(for: rec), FileBatchStatus.transcribing.progressFraction)
    }

    func testTerminalLiveFallsBackToPersistedStatus() {
        let model = FileBatchModel()
        let id = UUID()
        let rec = record(id, status: .completed)
        model.records = [rec]
        // A terminal live snapshot must not keep the row "in flight".
        model.live = [id.uuidString: snapshot(id, status: .completed)]
        XCTAssertEqual(model.effectiveStatus(for: rec), .completed)
        XCTAssertFalse(model.isInFlight(rec))
    }

    func testNoLiveOverlayUsesRecordStatus() {
        let model = FileBatchModel()
        let rec = record(UUID(), status: .failed)
        model.records = [rec]
        XCTAssertEqual(model.effectiveStatus(for: rec), .failed)
        XCTAssertFalse(model.isInFlight(rec))
        XCTAssertEqual(model.progress(for: rec), 1.0)
    }
}
