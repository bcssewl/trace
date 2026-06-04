import Foundation
import XCTest

@testable import SharedCore

/// BAS-44 — oldest-first pruning of retained audio recordings to a cache budget.
final class AudioArchivePrunerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bas44-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func writeFile(_ relativePath: String, bytes: Int, modified: Date) throws -> URL {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testSelectKeepsAllUnderBudget() {
        let entries = [
            AudioArchivePruner.Entry(
                url: URL(fileURLWithPath: "/a.caf"), sizeBytes: 100, modified: Date(timeIntervalSince1970: 1)),
            AudioArchivePruner.Entry(
                url: URL(fileURLWithPath: "/b.caf"), sizeBytes: 100, modified: Date(timeIntervalSince1970: 2)),
        ]
        XCTAssertTrue(AudioArchivePruner.selectForDeletion(entries, budgetBytes: 1000).isEmpty)
    }

    func testSelectRemovesOldestFirstUntilUnderBudget() {
        let old = AudioArchivePruner.Entry(
            url: URL(fileURLWithPath: "/old.caf"), sizeBytes: 100, modified: Date(timeIntervalSince1970: 1))
        let mid = AudioArchivePruner.Entry(
            url: URL(fileURLWithPath: "/mid.caf"), sizeBytes: 100, modified: Date(timeIntervalSince1970: 2))
        let new = AudioArchivePruner.Entry(
            url: URL(fileURLWithPath: "/new.caf"), sizeBytes: 100, modified: Date(timeIntervalSince1970: 3))
        // total 300, budget 150 ⇒ delete the two oldest (leaves 100 ≤ 150).
        let deleted = AudioArchivePruner.selectForDeletion([new, old, mid], budgetBytes: 150)
        XCTAssertEqual(deleted.map { $0.url.lastPathComponent }, ["old.caf", "mid.caf"])
    }

    func testPruneScansRecursivelyAndDeletesOldestCafOnly() throws {
        let old = try writeFile("proj/session/audio/sys.caf", bytes: 1000, modified: Date(timeIntervalSince1970: 1))
        let new = try writeFile("recent.caf", bytes: 1000, modified: Date(timeIntervalSince1970: 100))
        let notes = try writeFile("proj/session/notes.md", bytes: 5000, modified: Date(timeIntervalSince1970: 1))

        let result = AudioArchivePruner().prune(roots: [dir], budgetBytes: 1500)

        // Compare by filename (the enumerator resolves /var → /private/var symlinks).
        XCTAssertEqual(
            result.deleted.map { $0.lastPathComponent }, ["sys.caf"],
            "the oldest .caf is pruned to fit; the newer one stays")
        XCTAssertEqual(result.freedBytes, 1000)
        XCTAssertEqual(result.totalBytesBefore, 2000, "only matching audio counts toward the budget")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path), "non-audio files are never pruned")
    }

    func testPruneNoOpWhenUnderBudget() throws {
        try writeFile("a.caf", bytes: 100, modified: Date(timeIntervalSince1970: 1))
        let result = AudioArchivePruner().prune(roots: [dir], budgetBytes: 10_000)
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.totalBytesBefore, 100)
    }

    func testMissingRootIsIgnored() {
        let result = AudioArchivePruner().prune(roots: [dir.appendingPathComponent("does-not-exist")], budgetBytes: 0)
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.totalBytesBefore, 0)
    }
}
