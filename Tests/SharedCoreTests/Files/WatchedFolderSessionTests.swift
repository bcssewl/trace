import XCTest
import os

@testable import SharedCore

final class WatchedFolderSessionTests: XCTestCase {

    /// Thread-safe mutable set the injected scanner reads, so a test can change
    /// the "folder contents" between scans deterministically.
    private final class ScanBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<Set<URL>>(initialState: [])
        var files: Set<URL> {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
    }

    /// Thread-safe collector for emitted jobs.
    private final class JobSink: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[FileBatchJob]>(initialState: [])
        func append(_ jobs: [FileBatchJob]) { lock.withLock { $0.append(contentsOf: jobs) } }
        var all: [FileBatchJob] { lock.withLock { $0 } }
    }

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func url(_ name: String) -> URL {
        tempDir.appendingPathComponent(name)
    }

    private func makeSession(
        importExisting: Bool,
        origin: FileBatchJob.Origin = .watchedFolder,
        projectID: String? = nil,
        templateID: String? = nil,
        box: ScanBox,
        sink: JobSink
    ) -> WatchedFolderSession {
        let config = WatchedFolderConfig(
            displayPath: tempDir.path,
            importExistingOnFirstScan: importExisting,
            projectID: projectID,
            templateID: templateID
        )
        return WatchedFolderSession(
            config: config,
            origin: origin,
            scanner: { _ in box.files },
            onJobs: { sink.append($0) }
        )
    }

    func testImportExistingEmitsBacklogForAllCurrentFiles() throws {
        let box = ScanBox()
        let sink = JobSink()
        box.files = [url("a.m4a"), url("b.mp3")]
        let session = makeSession(importExisting: true, box: box, sink: sink)
        session.start()
        defer { session.stop() }
        XCTAssertEqual(sink.all.count, 2)
        XCTAssertEqual(Set(sink.all.map(\.sourceURL.lastPathComponent)), ["a.m4a", "b.mp3"])
    }

    func testNoImportSeedsWithoutEmittingThenDetectsNewArrivals() throws {
        let box = ScanBox()
        let sink = JobSink()
        box.files = [url("existing.m4a")]
        let session = makeSession(importExisting: false, box: box, sink: sink)
        session.start()
        defer { session.stop() }
        XCTAssertTrue(sink.all.isEmpty, "Pre-existing files must NOT be imported when importExisting is false")

        // A new file appears → exactly one new job, for the new file only.
        box.files.insert(url("fresh.m4a"))
        session.scanNow()
        XCTAssertEqual(sink.all.map(\.sourceURL.lastPathComponent), ["fresh.m4a"])
    }

    func testKnownFilesDoNotRefireOnRepeatScan() throws {
        let box = ScanBox()
        let sink = JobSink()
        box.files = [url("a.m4a")]
        let session = makeSession(importExisting: false, box: box, sink: sink)
        session.start()
        defer { session.stop() }
        box.files.insert(url("b.m4a"))
        session.scanNow()
        session.scanNow()  // same contents → no further jobs
        XCTAssertEqual(sink.all.count, 1)
    }

    func testStopPreventsFurtherEmits() throws {
        let box = ScanBox()
        let sink = JobSink()
        box.files = []
        let session = makeSession(importExisting: false, box: box, sink: sink)
        session.start()
        session.stop()
        box.files = [url("late.m4a")]
        session.scanNow()
        XCTAssertTrue(sink.all.isEmpty, "A stopped session must not emit")
    }

    func testEmittedJobsCarryConfiguredOriginProjectAndTemplate() throws {
        let box = ScanBox()
        let sink = JobSink()
        box.files = [url("memo.m4a")]
        let session = makeSession(
            importExisting: true, origin: .voiceMemosSync,
            projectID: "proj-1", templateID: "tmpl-1", box: box, sink: sink
        )
        session.start()
        defer { session.stop() }
        let job = try XCTUnwrap(sink.all.first)
        XCTAssertEqual(job.origin, .voiceMemosSync)
        XCTAssertEqual(job.projectID, "proj-1")
        XCTAssertEqual(job.templateID, "tmpl-1")
    }

    func testUnsupportedFilesAreIgnored() throws {
        let box = ScanBox()
        let sink = JobSink()
        // The scanner itself would filter these in production; assert the session
        // also drops anything unsupported the diff is handed (belt and braces).
        box.files = [url("notes.txt"), url("clip.m4a")]
        let session = makeSession(importExisting: true, box: box, sink: sink)
        session.start()
        defer { session.stop() }
        XCTAssertEqual(sink.all.map(\.sourceURL.lastPathComponent), ["clip.m4a"])
    }
}
