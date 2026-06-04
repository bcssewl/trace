import XCTest

@testable import SharedCore

final class ProjectStoreTests: XCTestCase {

    private var tempDir: URL!
    private var db: SqliteDatabase!
    private var store: ProjectStore!
    private var files: FileRepository!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        try await AppSchema.bootstrap(database: db)
        store = ProjectStore(database: db)
        files = FileRepository(database: db)
    }

    override func tearDown() async throws {
        try await db.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func insertFile(_ name: String, origin: FileBatchJob.Origin, project: UUID) async throws {
        let kind: FileBatchJob.Kind = FileRecord.voiceMemoOrigins.contains(origin) ? .voiceMemo : .audio
        let job = FileBatchJob(
            sourceURL: URL(fileURLWithPath: "/tmp/\(name).m4a"),
            kind: kind, origin: origin, projectID: project.uuidString
        )
        try await files.insertQueued(job: job, engine: "stub")
    }

    func testCreateAndListRoundTrips() async throws {
        let p = try await store.create(name: "Optivise", indicatorColor: "#ff3300")
        let list = try await store.list()
        XCTAssertEqual(list.map(\.id), [p.id])
        XCTAssertEqual(list.first?.name, "Optivise")
    }

    func testChildCountsBucketsFilesAndVoiceMemosByOrigin() async throws {
        let p = try await store.create(name: "Work")
        try await insertFile("a", origin: .dragDrop, project: p.id)
        try await insertFile("b", origin: .watchedFolder, project: p.id)
        try await insertFile("m1", origin: .voiceMemoCapture, project: p.id)
        try await insertFile("m2", origin: .voiceMemosSync, project: p.id)

        let counts = try await store.childCounts(projectId: p.id)
        XCTAssertEqual(counts.files, 2, "drag-drop + watched-folder count as files")
        XCTAssertEqual(counts.voiceMemos, 2, "captured + synced count as voice memos")
    }

    func testAllChildCountsMatchesPerProjectAndBucketsByOrigin() async throws {
        let a = try await store.create(name: "Alpha")
        let b = try await store.create(name: "Beta")
        try await insertFile("a1", origin: .dragDrop, project: a.id)
        try await insertFile("a2", origin: .watchedFolder, project: a.id)
        try await insertFile("am1", origin: .voiceMemoCapture, project: a.id)
        try await insertFile("b1", origin: .voiceMemosSync, project: b.id)

        let all = try await store.allChildCounts()
        XCTAssertEqual(all[a.id]?.files, 2)
        XCTAssertEqual(all[a.id]?.voiceMemos, 1)
        XCTAssertEqual(all[b.id]?.files, 0)
        XCTAssertEqual(all[b.id]?.voiceMemos, 1)
        // The bulk path must agree with the per-project path.
        let perA = try await store.childCounts(projectId: a.id)
        XCTAssertEqual(all[a.id], perA)
    }

    func testDeleteRemovesProject() async throws {
        let p = try await store.create(name: "Temp")
        try await store.delete(id: p.id)
        let list = try await store.list()
        XCTAssertTrue(list.isEmpty)
    }

    // MARK: - rename / overrides (BAS-23)

    func testRenameUpdatesName() async throws {
        let p = try await store.create(name: "Old")
        try await store.rename(id: p.id, name: "New")
        let fetched = try await store.fetch(id: p.id)
        XCTAssertEqual(fetched?.name, "New")
    }

    func testRenameToDuplicateThrows() async throws {
        _ = try await store.create(name: "Alpha")
        let b = try await store.create(name: "Beta")
        do {
            try await store.rename(id: b.id, name: "Alpha")
            XCTFail("renaming to an existing name must violate the UNIQUE constraint")
        } catch {
            // expected
        }
    }

    func testFreshProjectHasEmptyOverrides() async throws {
        let p = try await store.create(name: "Fresh")
        let fetched = try await store.fetch(id: p.id)
        XCTAssertTrue(fetched?.overrides.isEmpty ?? false)
    }

    func testSetOverridesRoundTrips() async throws {
        let p = try await store.create(name: "Routed")
        var overrides = ProjectOverrides()
        overrides.modelRouteOverrides = [.meetingSummary: LLMRoute(provider: .ollama, model: "llama3.2")]
        overrides.vocabulary = ["Optivise"]
        try await store.setOverrides(id: p.id, overrides)

        let fetched = try await store.fetch(id: p.id)
        XCTAssertEqual(fetched?.overrides, overrides)
    }

    func testFullUpdateWritesNameColorTemplateCoachAndOverrides() async throws {
        let p = try await store.create(name: "P")
        let template = UUID()
        var overrides = ProjectOverrides()
        overrides.asrRouteOverrides = [
            .fileBatchEnglish: ASRRoute(engineIdentifier: "whisperkit", modelIdentifier: "lg", allowsCloud: false)
        ]
        try await store.update(
            id: p.id, name: "P2", indicatorColor: "#00ff00",
            defaultTemplateId: template, coachConfigJson: #"{"enabled":false}"#,
            overrides: overrides
        )
        let fetched = try await store.fetch(id: p.id)
        XCTAssertEqual(fetched?.name, "P2")
        XCTAssertEqual(fetched?.indicatorColor, "#00ff00")
        XCTAssertEqual(fetched?.defaultTemplateId, template)
        XCTAssertEqual(fetched?.coachConfigJson, #"{"enabled":false}"#)
        XCTAssertEqual(fetched?.overrides, overrides)
    }
}
