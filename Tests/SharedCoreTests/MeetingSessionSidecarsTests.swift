import XCTest

@testable import SharedCore

/// BAS-46 / BAS-43: loaders for a finalized meeting's speaker sidecars, read off
/// the saved-on-disk path after relaunch (the live model is gone).
final class MeetingSessionSidecarsTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSpeakerNamesRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"remote_1":"Sarah","remote_2":"Dana"}"#.utf8)
            .write(to: dir.appendingPathComponent("speakers.json"))

        let names = MeetingSpeakerNames.load(sessionDirPath: dir.path)
        XCTAssertEqual(names, ["remote_1": "Sarah", "remote_2": "Dana"])
    }

    func testSpeakerNamesMissingReturnsEmpty() {
        XCTAssertTrue(MeetingSpeakerNames.load(sessionDirPath: "/no/such/dir-\(UUID())").isEmpty)
    }

    func testSpeakerNamesCorruptReturnsEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent("speakers.json"))
        XCTAssertTrue(MeetingSpeakerNames.load(sessionDirPath: dir.path).isEmpty)
    }

    func testVoiceprintsRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voiceprints.json")

        try MeetingVoiceprints.write(["remote_1": [0.1, 0.2, 0.3], "remote_2": [0.4, 0.5]], to: url)
        let loaded = MeetingVoiceprints.load(sessionDirPath: dir.path)

        XCTAssertEqual(loaded["remote_1"], [0.1, 0.2, 0.3])
        XCTAssertEqual(loaded["remote_2"], [0.4, 0.5])
    }

    func testVoiceprintsMissingReturnsEmpty() {
        XCTAssertTrue(MeetingVoiceprints.load(sessionDirPath: "/no/such/dir-\(UUID())").isEmpty)
    }

    func testSessionLayoutVoiceprintsFilename() {
        let layout = SessionLayout(
            root: URL(fileURLWithPath: "/tmp"), projectFolderName: "Inbox", sessionId: "session_1"
        )
        XCTAssertEqual(layout.speakerVoiceprintsURL.lastPathComponent, "voiceprints.json")
        XCTAssertEqual(layout.speakerNamesURL.lastPathComponent, "speakers.json")
    }
}
