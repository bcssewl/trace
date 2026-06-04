import XCTest

@testable import AppShell
@testable import SharedCore

/// Coverage for the Coach subscriber seam on `MeetingRuntime`
/// (`utteranceStream()`).
///
/// The yield-on-commit path runs inside the private,
/// audio-gated `commit(_:)`, so it is exercised by construction rather than
/// here; what is testable without real audio is the subscription plumbing:
/// multiple subscribers register safely, and `stop()` finishes every stream.
@MainActor
final class MeetingRuntimeUtteranceStreamTests: XCTestCase {

    private func makeTempDB() async throws -> SqliteDatabase {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try await SqliteDatabase.open(at: dir.appendingPathComponent("index.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        return db
    }

    private func makeRuntime(database: SqliteDatabase) -> MeetingRuntime {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-md-\(UUID().uuidString)").path
        return MeetingRuntime(
            database: database,
            markdownRoot: dir,
            liveModel: MeetingLiveModel(),
            activeCapture: ActiveCaptureModel(),
            asrResolver: { _ in nil }
        )
    }

    /// Two concurrent subscribers register without interfering, and `stop()`
    /// finishes both streams so their async iteration terminates.
    func testMultipleSubscribersFinishOnStop() async throws {
        let db = try await makeTempDB()
        let runtime = makeRuntime(database: db)

        let streamA = runtime.utteranceStream()
        let streamB = runtime.utteranceStream()

        // Each consumer drains until the stream finishes, then reports done.
        async let drainedA: Bool = {
            for await _ in streamA {}
            return true
        }()
        async let drainedB: Bool = {
            for await _ in streamB {}
            return true
        }()

        // No active session — stop() is safe and must finish the subscriptions.
        await runtime.stop()

        let a = await drainedA
        let b = await drainedB
        XCTAssertTrue(a, "Subscriber A's stream must finish when the meeting stops")
        XCTAssertTrue(b, "Subscriber B's stream must finish when the meeting stops")
    }
}
