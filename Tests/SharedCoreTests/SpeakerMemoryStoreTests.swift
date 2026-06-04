import XCTest

@testable import SharedCore

/// `SpeakerMemoryStore` persists per-project enrolled voiceprints (BAS-11, design
/// §14.3) in SQLite.
///
/// These exercise the real store against a temp database —
/// round-trip, replace-by-id, project scoping (including the NULL/inbox bucket),
/// and clearing (the "stays on your Mac" memory the user can wipe).
final class SpeakerMemoryStoreTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!
    var store: SpeakerMemoryStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        try await AppSchema.bootstrap(database: db)
        store = SpeakerMemoryStore(database: db)
    }

    override func tearDown() async throws {
        try await db?.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func spk(_ id: String, _ name: String, _ emb: [Float]) -> EnrolledSpeaker {
        EnrolledSpeaker(id: id, name: name, meanEmbedding: emb, embeddingModel: "test-embed")
    }

    func testUpsertThenLoadByProjectRoundTrips() async throws {
        let project = UUID()
        try await store.upsert(spk("s1", "Sarah", [1, 2, 3]), projectId: project, lastSeen: Date())
        let loaded = try await store.enrolledSpeakers(projectId: project)
        XCTAssertEqual(loaded, [spk("s1", "Sarah", [1, 2, 3])])
    }

    func testUpsertReplacesByID() async throws {
        let project = UUID()
        try await store.upsert(spk("s1", "Sarah", [1, 0, 0]), projectId: project, lastSeen: Date())
        try await store.upsert(spk("s1", "Sarah Lee", [0, 1, 0]), projectId: project, lastSeen: Date())
        let loaded = try await store.enrolledSpeakers(projectId: project)
        XCTAssertEqual(loaded, [spk("s1", "Sarah Lee", [0, 1, 0])])
    }

    func testSpeakersAreScopedByProject() async throws {
        let projectA = UUID()
        let projectB = UUID()
        try await store.upsert(spk("s1", "A", [1, 0, 0]), projectId: projectA, lastSeen: Date())
        try await store.upsert(spk("s2", "B", [0, 1, 0]), projectId: projectB, lastSeen: Date())
        let loadedA = try await store.enrolledSpeakers(projectId: projectA)
        XCTAssertEqual(loadedA, [spk("s1", "A", [1, 0, 0])])
    }

    func testNilProjectIsItsOwnBucket() async throws {
        try await store.upsert(spk("s1", "Inbox", [1, 0, 0]), projectId: nil, lastSeen: Date())
        let loadedNil = try await store.enrolledSpeakers(projectId: nil)
        XCTAssertEqual(loadedNil, [spk("s1", "Inbox", [1, 0, 0])])
        let loadedOther = try await store.enrolledSpeakers(projectId: UUID())
        XCTAssertTrue(loadedOther.isEmpty)
    }

    func testClearProjectRemovesOnlyThatProject() async throws {
        let projectA = UUID()
        let projectB = UUID()
        try await store.upsert(spk("s1", "A", [1, 0, 0]), projectId: projectA, lastSeen: Date())
        try await store.upsert(spk("s2", "B", [0, 1, 0]), projectId: projectB, lastSeen: Date())
        try await store.clear(projectId: projectA)
        let afterA = try await store.enrolledSpeakers(projectId: projectA)
        XCTAssertTrue(afterA.isEmpty)
        let afterB = try await store.enrolledSpeakers(projectId: projectB)
        XCTAssertEqual(afterB, [spk("s2", "B", [0, 1, 0])])
    }

    func testClearAllRemovesEverythingAcrossScopes() async throws {
        try await store.upsert(spk("s1", "A", [1, 0, 0]), projectId: UUID(), lastSeen: Date())
        try await store.upsert(spk("s2", "B", [0, 1, 0]), projectId: nil, lastSeen: Date())
        try await store.clearAll()
        let count = try await store.totalCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - reconcileAndPersist (the finalize-time seam)

    /// The one call `MeetingRuntime` makes at finalize: load the project's
    /// voiceprints, reconcile against this meeting's embeddings + renames, persist
    /// the upserts, and return the auto-name assignments to apply to the live
    /// transcript.
    func testReconcileAndPersistAppliesMatchesAndEnrollsRenames() async throws {
        let project = UUID()
        // Sarah is already known to this project from a prior meeting.
        try await store.upsert(
            spk("s1", "Sarah", [1, 0, 0]), projectId: project, lastSeen: Date(timeIntervalSince1970: 1)
        )
        // This meeting: remote_1 is Sarah's voice (unnamed) and remote_2 is a new
        // voice the user named "Bob".
        let names = try await store.reconcileAndPersist(
            speakerEmbeddings: ["remote_1": [1, 0, 0], "remote_2": [0, 1, 0]],
            sessionNames: ["remote_2": "Bob"],
            projectId: project,
            embeddingModel: "test-embed",
            lastSeen: Date(timeIntervalSince1970: 100),
            makeID: { "bob-id" }
        )
        // Sarah's name is auto-applied; Bob was already named by the user.
        XCTAssertEqual(names, ["remote_1": "Sarah"])
        // Both voiceprints are now persisted for the project.
        let all = try await store.enrolledSpeakers(projectId: project)
        XCTAssertEqual(Set(all.map(\.name)), ["Sarah", "Bob"])
        XCTAssertEqual(all.first { $0.name == "Bob" }?.meanEmbedding, [0, 1, 0])
    }

    func testReconcileAndPersistWithNoMatchesOrRenamesPersistsNothing() async throws {
        let project = UUID()
        let names = try await store.reconcileAndPersist(
            speakerEmbeddings: ["remote_1": [1, 1, 1]],
            sessionNames: [:],
            projectId: project,
            embeddingModel: "test-embed",
            lastSeen: Date()
        )
        XCTAssertTrue(names.isEmpty)
        let all = try await store.enrolledSpeakers(projectId: project)
        XCTAssertTrue(all.isEmpty)
    }
}
