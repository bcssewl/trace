import XCTest

@testable import SharedCore

final class FtsIndexTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!
    var fts: FtsIndex!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("f.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        fts = FtsIndex(database: db)
    }

    override func tearDown() async throws {
        try await db?.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInsertAndSearchTranscript() async throws {
        try await fts.insertTranscript(meetingId: "m1", speaker: "you", text: "hello sarah how are you", timestamp: 0)
        try await fts.insertTranscript(meetingId: "m1", speaker: "sarah", text: "doing great", timestamp: 1.5)
        try await fts.insertTranscript(meetingId: "m2", speaker: "you", text: "different meeting", timestamp: 0)

        let hits = try await fts.searchTranscript(query: "sarah")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.meetingId, "m1")
    }

    func testSearchTranscriptHonorsMeetingFilter() async throws {
        try await fts.insertTranscript(meetingId: "m1", speaker: "you", text: "thirsty", timestamp: 0)
        try await fts.insertTranscript(meetingId: "m2", speaker: "you", text: "thirsty", timestamp: 0)

        let all = try await fts.searchTranscript(query: "thirsty")
        XCTAssertEqual(all.count, 2)

        let scoped = try await fts.searchTranscript(query: "thirsty", meetingId: "m1")
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.meetingId, "m1")
    }

    func testDeleteTranscriptRemovesAllRowsForMeeting() async throws {
        for i in 0..<5 {
            try await fts.insertTranscript(
                meetingId: "m1", speaker: "you", text: "row \(i) banana", timestamp: Double(i))
        }
        let before = try await fts.searchTranscript(query: "banana")
        XCTAssertEqual(before.count, 5)
        try await fts.deleteTranscript(meetingId: "m1")
        let after = try await fts.searchTranscript(query: "banana")
        XCTAssertEqual(after.count, 0)
    }

    func testUpsertNotesReplacesExisting() async throws {
        try await fts.upsertNotes(meetingId: "m1", text: "first version mango")
        let firstMango = try await fts.searchNotes(query: "mango")
        XCTAssertEqual(firstMango.count, 1)

        try await fts.upsertNotes(meetingId: "m1", text: "rewritten papaya")
        let secondMango = try await fts.searchNotes(query: "mango")
        XCTAssertEqual(secondMango.count, 0)
        let papaya = try await fts.searchNotes(query: "papaya")
        XCTAssertEqual(papaya.count, 1)
    }
}
