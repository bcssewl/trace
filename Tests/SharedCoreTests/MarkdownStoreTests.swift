import XCTest

@testable import SharedCore

final class MarkdownStoreTests: XCTestCase {
    var tempDir: URL!
    var config: MarkdownFolderConfig!
    var store: MarkdownStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        config = MarkdownFolderConfig(displayPath: tempDir.path)
        store = MarkdownStore(folderConfig: config)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWriteAndReadNotes() throws {
        let layout = try store.layout(projectFolderName: "Proj", sessionId: "s1")
        try store.writeNotes("# Hello", to: layout)
        let back = try store.readNotes(at: layout)
        XCTAssertEqual(back, "# Hello")
    }

    func testWriteSessionJsonRoundTrip() throws {
        let layout = try store.layout(projectFolderName: "Proj", sessionId: "s2")
        let meta = SessionMetadata(
            sessionId: "s2",
            projectId: "p1",
            title: "Demo",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionDirPath: layout.sessionDirectory.path
        )
        try store.writeSessionJson(meta, to: layout)
        let restored = try store.readSessionJson(at: layout)
        XCTAssertEqual(restored, meta)
    }

    func testListProjectFolders() throws {
        let layoutA = try store.layout(projectFolderName: "Alpha", sessionId: "s1")
        let layoutB = try store.layout(projectFolderName: "Bravo", sessionId: "s1")
        try store.writeNotes("a", to: layoutA)
        try store.writeNotes("b", to: layoutB)
        let folders = try store.listProjectFolders()
        XCTAssertEqual(folders, ["Alpha", "Bravo"])
    }

    func testListSessionsInProject() throws {
        let l1 = try store.layout(projectFolderName: "P", sessionId: "session_a")
        let l2 = try store.layout(projectFolderName: "P", sessionId: "session_b")
        try store.writeNotes("1", to: l1)
        try store.writeNotes("2", to: l2)
        let sessions = try store.listSessions(inProject: "P")
        XCTAssertEqual(sessions, ["session_a", "session_b"])
    }

    func testReadNotesOnMissingFileReturnsEmpty() throws {
        let layout = try store.layout(projectFolderName: "Missing", sessionId: "no_such")
        XCTAssertEqual(try store.readNotes(at: layout), "")
    }
}
