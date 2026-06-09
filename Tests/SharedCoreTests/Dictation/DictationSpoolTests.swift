import Foundation
import XCTest

@testable import SharedCore

final class DictationSpoolTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spool-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func writeSpool(
        id: String = DictationAudioSpool.newID(),
        seconds: Double = 1.0,
        startedAt: Date = Date(),
        keep: Bool = true
    ) throws -> DictationAudioSpool {
        let spool = try DictationAudioSpool(
            directory: tempDir, id: id, sampleRate: 16_000, startedAt: startedAt)
        let samples = [Float](repeating: 0.25, count: Int(16_000 * seconds))
        try spool.append(samples)
        if keep {
            spool.keepForRecovery()
        }
        return spool
    }

    // MARK: writer lifecycle

    func testAppendWritesRawPCMAndSidecar() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let spool = try DictationAudioSpool(
            directory: tempDir, id: "spool_test_a", sampleRate: 16_000, startedAt: started)
        try spool.append([0.1, -0.2, 0.3])
        try spool.append([0.4])
        XCTAssertEqual(spool.samplesWritten, 4)

        // Raw PCM: 4 bytes per sample, readable mid-write (no header to patch).
        let pcmSize = try FileManager.default.attributesOfItem(atPath: spool.pcmURL.path)[.size] as? Int
        XCTAssertEqual(pcmSize, 16)

        let sidecar = try JSONDecoder().decode(
            DictationSpoolMetadata.self, from: Data(contentsOf: spool.sidecarURL))
        XCTAssertEqual(sidecar.sampleRate, 16_000)
        XCTAssertEqual(sidecar.startedAt, 1_700_000_000)
        spool.finishClean()
    }

    func testFinishCleanRemovesBothFiles() throws {
        let spool = try writeSpool(keep: false)
        spool.finishClean()
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.pcmURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.sidecarURL.path))
        XCTAssertTrue(DictationSpoolStore.orphanedSpools(in: tempDir).isEmpty)
    }

    func testDiscardRemovesBothFiles() throws {
        let spool = try writeSpool(keep: false)
        spool.discard()
        XCTAssertTrue(DictationSpoolStore.orphanedSpools(in: tempDir).isEmpty)
    }

    // MARK: orphan detection

    func testActiveSpoolIsNotAnOrphanUntilKept() throws {
        let spool = try DictationAudioSpool(directory: tempDir, id: "spool_active")
        try spool.append([Float](repeating: 0.5, count: 16_000))

        // Mid-recording (registered active): the scan must skip it.
        XCTAssertTrue(DictationSpoolStore.orphanedSpools(in: tempDir).isEmpty)

        // Kept for recovery (e.g. transcription failed): now it appears.
        spool.keepForRecovery()
        let orphans = DictationSpoolStore.orphanedSpools(in: tempDir)
        XCTAssertEqual(orphans.map(\.id), ["spool_active"])
        XCTAssertEqual(orphans.first?.sampleCount, 16_000)
        XCTAssertEqual(orphans.first!.duration, 1.0, accuracy: 0.01)
    }

    func testOrphansSortNewestFirstAndCarryMetadata() throws {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_900)
        _ = try writeSpool(id: "spool_old", seconds: 2, startedAt: older)
        _ = try writeSpool(id: "spool_new", seconds: 5, startedAt: newer)

        let orphans = DictationSpoolStore.orphanedSpools(in: tempDir)
        XCTAssertEqual(orphans.map(\.id), ["spool_new", "spool_old"])
        XCTAssertEqual(orphans.first!.duration, 5.0, accuracy: 0.01)
        XCTAssertEqual(orphans.first?.startedAt, newer)
    }

    func testTinySpoolsAreSweptNotSurfaced() throws {
        _ = try writeSpool(id: "spool_blip", seconds: 0.05)
        XCTAssertTrue(DictationSpoolStore.orphanedSpools(in: tempDir).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("spool_blip.pcm").path))
    }

    func testPCMWithoutSidecarIsSwept() throws {
        let stray = tempDir.appendingPathComponent("spool_stray.pcm")
        try Data(repeating: 7, count: 64_000).write(to: stray)
        XCTAssertTrue(DictationSpoolStore.orphanedSpools(in: tempDir).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    func testLoadSamplesRoundTripsAudio() throws {
        let spool = try DictationAudioSpool(directory: tempDir, id: "spool_rt")
        let original: [Float] = [0.5, -0.25, 0.125, 1.0, -1.0]
        try spool.append(original)
        // Pad to clear the tiny-spool sweep threshold.
        try spool.append([Float](repeating: 0.01, count: 16_000))
        spool.keepForRecovery()

        let orphan = DictationSpoolStore.orphanedSpools(in: tempDir).first
        let samples = try DictationSpoolStore.loadSamples(of: XCTUnwrap(orphan))
        XCTAssertEqual(Array(samples.prefix(5)), original)
        XCTAssertEqual(samples.count, original.count + 16_000)
    }

    // MARK: disk cap

    func testEnforceCapPrunesAncientSpools() throws {
        let ancient = Date().addingTimeInterval(-DictationSpoolStore.maxSpoolAge - 3_600)
        _ = try writeSpool(id: "spool_ancient", seconds: 1, startedAt: ancient)
        _ = try writeSpool(id: "spool_fresh", seconds: 1)

        let pruned = DictationSpoolStore.enforceCap(in: tempDir)
        XCTAssertEqual(pruned.map(\.id), ["spool_ancient"])
        XCTAssertEqual(DictationSpoolStore.orphanedSpools(in: tempDir).map(\.id), ["spool_fresh"])
    }

    func testEnforceCapPrunesOldestBeyondByteBudget() throws {
        let base = Date()
        _ = try writeSpool(id: "spool_1_oldest", seconds: 2, startedAt: base.addingTimeInterval(-300))
        _ = try writeSpool(id: "spool_2_mid", seconds: 2, startedAt: base.addingTimeInterval(-200))
        _ = try writeSpool(id: "spool_3_newest", seconds: 2, startedAt: base.addingTimeInterval(-100))

        // Budget fits two 2-second spools (2 s × 16 000 × 4 B = 128 000 B each).
        let pruned = DictationSpoolStore.enforceCap(in: tempDir, maxBytes: 300_000)
        XCTAssertEqual(pruned.map(\.id), ["spool_1_oldest"])
        XCTAssertEqual(
            DictationSpoolStore.orphanedSpools(in: tempDir).map(\.id),
            ["spool_3_newest", "spool_2_mid"]
        )
    }

    // MARK: recovery

    private func makeHistoryStore() async throws -> (DictationHistoryStore, SqliteDatabase) {
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        try await DictationSchemaV34.bootstrap(database: db)
        return (DictationHistoryStore(database: db), db)
    }

    func testRecoverTranscribesSavesTagsAndCopies() async throws {
        // Recent (within the prune window) and whole-second so the sidecar's
        // JSON round-trip compares exactly.
        let started = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3_600)
        _ = try writeSpool(id: "spool_recover", seconds: 3, startedAt: started)
        let (store, db) = try await makeHistoryStore()
        defer { Task { try? await db.close() } }
        let clipboard = RecordingClipboard()

        let recovery = DictationSpoolRecovery(directory: tempDir, historyStore: store, clipboard: clipboard)
        let scanned = await recovery.orphans()
        let orphan = try XCTUnwrap(scanned.first)
        let record = try await recovery.recover(orphan) { samples in
            XCTAssertEqual(samples.count, 48_000)
            return "  the five minute take, saved  "
        }

        XCTAssertTrue(record.recovered)
        XCTAssertEqual(record.modeName, "Recovered")
        XCTAssertEqual(record.rawText, "the five minute take, saved")
        XCTAssertFalse(record.inserted)
        XCTAssertEqual(record.durationMs, 3_000)
        XCTAssertEqual(record.startedAt, started.timeIntervalSince1970)

        // Persisted to history…
        let stored = try await store.record(id: record.id)
        XCTAssertEqual(stored?.recovered, true)
        // …copied to the clipboard…
        let copied = await clipboard.value()
        XCTAssertEqual(copied, "the five minute take, saved")
        // …and the spool is gone.
        XCTAssertTrue(DictationSpoolStore.orphanedSpools(in: tempDir).isEmpty)
    }

    func testRecoverEmptyTranscriptThrowsAndKeepsSpool() async throws {
        _ = try writeSpool(id: "spool_silent", seconds: 1)
        let (store, db) = try await makeHistoryStore()
        defer { Task { try? await db.close() } }

        let recovery = DictationSpoolRecovery(
            directory: tempDir, historyStore: store, clipboard: RecordingClipboard())
        let scanned = await recovery.orphans()
        let orphan = try XCTUnwrap(scanned.first)
        do {
            _ = try await recovery.recover(orphan) { _ in "   " }
            XCTFail("expected asrInferenceFailed")
        } catch let err as TraceError {
            guard case .asrInferenceFailed = err else {
                XCTFail("wrong error: \(err)")
                return
            }
        }
        // Failure keeps the audio for another attempt — never silently gone.
        XCTAssertEqual(DictationSpoolStore.orphanedSpools(in: tempDir).map(\.id), ["spool_silent"])
        let count = try await store.count()
        XCTAssertEqual(count, 0)
    }

    func testDiscardViaRecoveryRemovesSpool() async throws {
        _ = try writeSpool(id: "spool_unwanted", seconds: 1)
        let (store, db) = try await makeHistoryStore()
        defer { Task { try? await db.close() } }

        let recovery = DictationSpoolRecovery(
            directory: tempDir, historyStore: store, clipboard: RecordingClipboard())
        let scanned = await recovery.orphans()
        let orphan = try XCTUnwrap(scanned.first)
        await recovery.discard(orphan)
        XCTAssertTrue(DictationSpoolStore.orphanedSpools(in: tempDir).isEmpty)
    }

    func testCapPruneLeavesLoudHistoryNote() async throws {
        let ancient = Date().addingTimeInterval(-DictationSpoolStore.maxSpoolAge - 3_600)
        _ = try writeSpool(id: "spool_ancient_noted", seconds: 4, startedAt: ancient)
        let (store, db) = try await makeHistoryStore()
        defer { Task { try? await db.close() } }

        let recovery = DictationSpoolRecovery(
            directory: tempDir, historyStore: store, clipboard: RecordingClipboard())
        let orphans = await recovery.orphans()

        XCTAssertTrue(orphans.isEmpty, "the ancient spool was pruned")
        let notes = try await store.recent(limit: 10)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.recovered, true)
        XCTAssertTrue(notes.first?.rawText.contains("was removed without being recovered") ?? false)
    }
}

private actor RecordingClipboard: ClipboardStoring {
    private var stored: String?
    func readString() async -> String? { stored }
    func writeString(_ text: String) async { stored = text }
    func changeCount() async -> Int { 0 }
    func value() -> String? { stored }
}
