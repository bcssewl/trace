import XCTest

@testable import SharedCore

final class FileInboxTests: XCTestCase {

    func testJobsFromDropFiltersUnsupportedAndDedupes() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.m4a"),
            URL(fileURLWithPath: "/tmp/b.txt"),
            URL(fileURLWithPath: "/tmp/c.mov"),
            URL(fileURLWithPath: "/tmp/a.m4a"),
            URL(fileURLWithPath: "/tmp/d.zip"),
        ]
        let jobs = FileInbox.jobsFromDrop(urls: urls)
        XCTAssertEqual(jobs.map(\.sourceURL.lastPathComponent), ["a.m4a", "c.mov"])
    }

    func testDropAttachesProjectAndTemplate() {
        let urls = [URL(fileURLWithPath: "/tmp/recording.m4a")]
        let jobs = FileInbox.jobsFromDrop(
            urls: urls, projectID: "proj-7", templateID: "tpl-3"
        )
        XCTAssertEqual(jobs.first?.projectID, "proj-7")
        XCTAssertEqual(jobs.first?.templateID, "tpl-3")
        XCTAssertEqual(jobs.first?.origin, .dragDrop)
    }

    func testDefaultVoiceMemosFolderResolvesToICloudPath() {
        let home = URL(fileURLWithPath: "/Users/me")
        let folder = FileInbox.defaultVoiceMemosFolder(home: home)
        XCTAssertEqual(
            folder.path,
            "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Voice Memos"
        )
    }

    func testVoiceMemoBacklogRespectsImportFlag() {
        let urls = [
            URL(fileURLWithPath: "/tmp/old1.m4a"),
            URL(fileURLWithPath: "/tmp/old2.m4a"),
        ]
        XCTAssertEqual(
            FileInbox.voiceMemosBacklogJobs(currentlyInFolder: urls, importExisting: false), []
        )
        let imported = FileInbox.voiceMemosBacklogJobs(
            currentlyInFolder: urls, importExisting: true
        )
        XCTAssertEqual(imported.count, 2)
        XCTAssertTrue(imported.allSatisfy { $0.origin == .voiceMemosSync })
    }

    func testWatchedFolderSnapshotDetectsOnlyNewSupportedFiles() {
        var snapshot = WatchedFolderSnapshot(
            existing: [URL(fileURLWithPath: "/tmp/a.m4a")]
        )
        let added = snapshot.diff(currentFiles: [
            URL(fileURLWithPath: "/tmp/a.m4a"),
            URL(fileURLWithPath: "/tmp/b.txt"),
            URL(fileURLWithPath: "/tmp/c.wav"),
        ])
        XCTAssertEqual(added.map(\.sourceURL.lastPathComponent), ["c.wav"])
    }

    func testWatchedFolderSnapshotRemembersPathsAcrossDiffCalls() {
        var snapshot = WatchedFolderSnapshot(existing: [])
        let first = snapshot.diff(currentFiles: [
            URL(fileURLWithPath: "/tmp/a.m4a"),
            URL(fileURLWithPath: "/tmp/b.m4a"),
        ])
        XCTAssertEqual(first.count, 2)
        let secondCall = snapshot.diff(currentFiles: [
            URL(fileURLWithPath: "/tmp/a.m4a"),
            URL(fileURLWithPath: "/tmp/b.m4a"),
            URL(fileURLWithPath: "/tmp/c.m4a"),
        ])
        XCTAssertEqual(secondCall.map(\.sourceURL.lastPathComponent), ["c.m4a"])
    }

    func testWatchedFolderSnapshotForgetsRemovedFiles() {
        var snapshot = WatchedFolderSnapshot(existing: [])
        _ = snapshot.diff(currentFiles: [
            URL(fileURLWithPath: "/tmp/a.m4a")
        ])
        let afterRemoval = snapshot.diff(currentFiles: [])
        XCTAssertEqual(afterRemoval, [])
        // Re-adding the same path now counts as new again.
        let reAdded = snapshot.diff(currentFiles: [URL(fileURLWithPath: "/tmp/a.m4a")])
        XCTAssertEqual(reAdded.count, 1)
    }

    func testWatchedFolderScanReturnsOnlySupportedRegularFiles() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let m4a = tempRoot.appendingPathComponent("a.m4a")
        let txt = tempRoot.appendingPathComponent("b.txt")
        let mp4 = tempRoot.appendingPathComponent("c.mp4")
        try Data().write(to: m4a)
        try Data().write(to: txt)
        try Data().write(to: mp4)

        let supported = WatchedFolderScan.currentSupportedFiles(in: tempRoot)
        let names = supported.map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["a.m4a", "c.mp4"])
    }

    func testWatchedFolderConfigResolvesToPlainURLWithoutBookmark() throws {
        let cfg = WatchedFolderConfig(displayPath: "/tmp")
        let resolved = try cfg.resolve()
        XCTAssertEqual(resolved.url.path, "/tmp")
        XCTAssertFalse(resolved.isStale)
    }
}
