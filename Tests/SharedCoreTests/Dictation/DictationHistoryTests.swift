import Foundation
import XCTest

@testable import SharedCore

final class DictationRecordTests: XCTestCase {
    func testNewIDHasExpectedShape() {
        let id = DictationRecord.newID(at: Date(timeIntervalSince1970: 1_748_332_800))
        XCTAssertTrue(id.hasPrefix("dictation_"))
        XCTAssertTrue(id.contains("2025-05-27"))
        XCTAssertGreaterThan(id.count, 24)
    }

    func testCodableRoundTrip() throws {
        let record = DictationRecord(
            id: "dictation_test_1",
            projectID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            modeName: "Default",
            bundleID: "com.apple.mail",
            rawText: "send to sarah period",
            cleanedText: "Send to Sarah.",
            inserted: true,
            durationMs: 1_250,
            startedAt: 1_748_000_000
        )
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(DictationRecord.self, from: data)
        XCTAssertEqual(back, record)
    }
}

final class DictationHistoryStoreTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "history-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        // Full production schema: `delete(id:)` purges the entry_fts row in the
        // same transaction, so the keyword-search table must exist here too.
        try await AppSchema.bootstrap(database: db)
    }

    override func tearDown() async throws {
        try? await db?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    func testInsertAndFetchByID() async throws {
        let store = DictationHistoryStore(database: db)
        let record = DictationRecord(
            id: "dictation_test_1",
            projectID: nil,
            modeName: "Default",
            bundleID: "com.apple.mail",
            rawText: "hello sarah",
            cleanedText: "Hello, Sarah.",
            inserted: true,
            durationMs: 2_000,
            startedAt: 1_700_000_000
        )
        try await store.insert(record)
        let loaded = try await store.record(id: record.id)
        XCTAssertEqual(loaded, record)
    }

    func testRecentReturnsNewestFirst() async throws {
        let store = DictationHistoryStore(database: db)
        let oldest = DictationRecord(
            id: "dictation_a",
            projectID: nil,
            modeName: "Default",
            bundleID: nil,
            rawText: "a",
            cleanedText: "A",
            inserted: true,
            durationMs: 100,
            startedAt: 1_000
        )
        let middle = DictationRecord(
            id: "dictation_b",
            projectID: nil,
            modeName: "Default",
            bundleID: nil,
            rawText: "b",
            cleanedText: "B",
            inserted: true,
            durationMs: 100,
            startedAt: 2_000
        )
        let newest = DictationRecord(
            id: "dictation_c",
            projectID: nil,
            modeName: "Default",
            bundleID: nil,
            rawText: "c",
            cleanedText: "C",
            inserted: true,
            durationMs: 100,
            startedAt: 3_000
        )
        try await store.insert(oldest)
        try await store.insert(middle)
        try await store.insert(newest)
        let recent = try await store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), ["dictation_c", "dictation_b", "dictation_a"])
    }

    func testDeleteRemovesRecord() async throws {
        let store = DictationHistoryStore(database: db)
        let record = DictationRecord(
            id: "dictation_test_delete",
            projectID: nil,
            modeName: nil,
            bundleID: nil,
            rawText: "x",
            cleanedText: "X",
            inserted: false,
            durationMs: 0,
            startedAt: 0
        )
        try await store.insert(record)
        try await store.delete(id: record.id)
        let after = try await store.record(id: record.id)
        XCTAssertNil(after)
    }

    func testCount() async throws {
        let store = DictationHistoryStore(database: db)
        for i in 0..<3 {
            let record = DictationRecord(
                id: "dictation_count_\(i)",
                projectID: nil,
                modeName: nil,
                bundleID: nil,
                rawText: "x",
                cleanedText: "x",
                inserted: true,
                durationMs: 0,
                startedAt: TimeInterval(i)
            )
            try await store.insert(record)
        }
        let count = try await store.count()
        XCTAssertEqual(count, 3)
    }

    func testFailedDictationStoredWithInsertedFalse() async throws {
        let store = DictationHistoryStore(database: db)
        let failed = DictationRecord(
            id: "dictation_failed",
            projectID: nil,
            modeName: "Default",
            bundleID: nil,
            rawText: "lost in transcription",
            cleanedText: "",
            inserted: false,
            durationMs: 750,
            startedAt: 1_000
        )
        try await store.insert(failed)
        let back = try await store.record(id: failed.id)
        XCTAssertNotNil(back)
        XCTAssertFalse(back?.inserted ?? true)
    }

    func testRecoveredFlagRoundTrips() async throws {
        let store = DictationHistoryStore(database: db)
        let recovered = DictationRecord(
            id: "dictation_recovered_1",
            projectID: nil,
            modeName: "Recovered",
            bundleID: nil,
            rawText: "salvaged from a crash",
            cleanedText: "salvaged from a crash",
            inserted: false,
            durationMs: 9_000,
            startedAt: 2_000,
            recovered: true
        )
        try await store.insert(recovered)
        let back = try await store.record(id: recovered.id)
        XCTAssertEqual(back?.recovered, true)

        let normal = DictationRecord(
            id: "dictation_normal_1",
            projectID: nil,
            modeName: "Default",
            bundleID: nil,
            rawText: "live take",
            cleanedText: "Live take.",
            inserted: true,
            durationMs: 1_000,
            startedAt: 3_000
        )
        try await store.insert(normal)
        let backNormal = try await store.record(id: normal.id)
        XCTAssertEqual(backNormal?.recovered, false)
    }

    func testDecodeToleratesJSONWithoutRecoveredField() throws {
        // JSON persisted before the v34 `recovered` field existed.
        let legacy = """
            {"id":"dictation_legacy","projectID":null,"modeName":"Default",
             "bundleID":null,"rawText":"r","cleanedText":"c","inserted":true,
             "durationMs":10,"startedAt":1}
            """
        let record = try JSONDecoder().decode(DictationRecord.self, from: Data(legacy.utf8))
        XCTAssertFalse(record.recovered)
    }
}
