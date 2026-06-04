import XCTest

@testable import SharedCore

/// BAS-28: the reconcile pass should re-read a meeting from disk only when it's
/// not embedded at the current fingerprint, or its content changed since the last
/// index (max content-file mtime > `last_indexed_at`). `MeetingIndexGate` is the
/// pure decision + the cheap `stat`-based mtime probe.
final class MeetingIndexGateTests: XCTestCase {

    // MARK: shouldReindex

    func testReindexWhenNotIndexedAtCurrentFingerprint() {
        // Covers a brand-new meeting AND an embedding-model change.
        XCTAssertTrue(
            MeetingIndexGate.shouldReindex(indexedAtCurrentFingerprint: false, lastIndexedAt: 999, contentMtime: 1))
    }

    func testReindexWhenIndexedButNoStampYet() {
        // Indexed before BAS-28 shipped → no stamp → reindex once to create it.
        XCTAssertTrue(
            MeetingIndexGate.shouldReindex(indexedAtCurrentFingerprint: true, lastIndexedAt: nil, contentMtime: 100))
    }

    func testSkipWhenIndexedAndContentOlderThanStamp() {
        XCTAssertFalse(
            MeetingIndexGate.shouldReindex(indexedAtCurrentFingerprint: true, lastIndexedAt: 500, contentMtime: 400))
    }

    func testSkipWhenIndexedAndContentEqualToStamp() {
        XCTAssertFalse(
            MeetingIndexGate.shouldReindex(indexedAtCurrentFingerprint: true, lastIndexedAt: 500, contentMtime: 500))
    }

    func testReindexWhenContentNewerThanStamp() {
        XCTAssertTrue(
            MeetingIndexGate.shouldReindex(indexedAtCurrentFingerprint: true, lastIndexedAt: 500, contentMtime: 600))
    }

    func testSkipWhenIndexedAndNoContentToStat() {
        // No readable content files → nothing to (re)index → skip.
        XCTAssertFalse(
            MeetingIndexGate.shouldReindex(indexedAtCurrentFingerprint: true, lastIndexedAt: 500, contentMtime: nil))
    }

    // MARK: contentMtime

    func testContentMtimeNilForEmptyDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(MeetingIndexGate.contentMtime(sessionDirPath: dir.path))
    }

    func testContentMtimeReturnsMaxAcrossContentFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try write(dir, "notes.md", mtime: 5_000)
        try write(dir, "summary.md", mtime: 9_000)
        // A non-content file's mtime must be ignored.
        try write(dir, "session.json", mtime: 50_000)

        XCTAssertEqual(MeetingIndexGate.contentMtime(sessionDirPath: dir.path), 9_000)
    }

    func testContentMtimeCountsSpeakersJson() throws {
        // BAS-46: a post-finalize speaker rename rewrites `speakers.json`, which
        // changes the names baked into transcript chunks — so it IS indexable
        // content and the gate must re-read the meeting when it's newer.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try write(dir, "notes.md", mtime: 5_000)
        try write(dir, "speakers.json", mtime: 80_000)

        XCTAssertEqual(MeetingIndexGate.contentMtime(sessionDirPath: dir.path), 80_000)
    }

    private func write(_ dir: URL, _ name: String, mtime: TimeInterval) throws {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: url.path
        )
    }
}
