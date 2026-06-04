import XCTest

@testable import SharedCore

final class JsonlWriterTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAppendAndReadBack() async throws {
        let url = tempDir.appendingPathComponent("t.jsonl")
        let writer = JsonlWriter(url: url)
        let a = Utterance(t: 0.0, speaker: .you, text: "hi sarah", conf: 0.99, asr: "parakeet-eou")
        let b = Utterance(t: 2.3, speaker: .other(id: "remote_1"), text: "hey", conf: 0.97, diar: "lseend")
        try await writer.append(a)
        try await writer.append(b)
        try await writer.close()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)

        let restored: [Utterance] = try JsonlReader.readAll(Utterance.self, from: url)
        XCTAssertEqual(restored, [a, b])
    }

    func testReopenAppendsToEnd() async throws {
        let url = tempDir.appendingPathComponent("t2.jsonl")
        let w1 = JsonlWriter(url: url)
        try await w1.append(Utterance(t: 0, speaker: .you, text: "one", conf: 1))
        try await w1.close()

        let w2 = JsonlWriter(url: url)
        try await w2.append(Utterance(t: 1, speaker: .you, text: "two", conf: 1))
        try await w2.close()

        let all = try JsonlReader.readAll(Utterance.self, from: url)
        XCTAssertEqual(all.map(\.text), ["one", "two"])
    }

    func testReadAllOnMissingFileReturnsEmpty() throws {
        let url = tempDir.appendingPathComponent("missing.jsonl")
        let out: [Utterance] = try JsonlReader.readAll(Utterance.self, from: url)
        XCTAssertTrue(out.isEmpty)
    }
}

final class SessionLayoutTests: XCTestCase {
    func testPathsAreNested() {
        let root = URL(fileURLWithPath: "/tmp/root")
        let layout = SessionLayout(root: root, projectFolderName: "Acme", sessionId: "session_2026-05-27_10-00-00")
        XCTAssertEqual(layout.sessionDirectory.path, "/tmp/root/Acme/session_2026-05-27_10-00-00")
        XCTAssertEqual(layout.transcriptLiveURL.lastPathComponent, "transcript.live.jsonl")
        XCTAssertEqual(layout.micAudioURL.path, "/tmp/root/Acme/session_2026-05-27_10-00-00/audio/mic.caf")
    }

    func testCreateDirectoriesCreatesAllSubdirs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = SessionLayout(root: root, projectFolderName: "Proj", sessionId: SessionLayout.defaultSessionId())
        try layout.createDirectories()
        for dir in [
            layout.sessionDirectory, layout.audioDirectory, layout.attachmentsDirectory, layout.imagesDirectory,
        ] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        }
    }

    func testDefaultSessionIdMatchesPattern() {
        let id = SessionLayout.defaultSessionId()
        let pattern = #"^session_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#
        XCTAssertNotNil(id.range(of: pattern, options: .regularExpression))
    }
}
