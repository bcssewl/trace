import Foundation
import XCTest

@testable import SharedCore

final class DictationControllerTests: XCTestCase {
    var tempDir: URL!
    var db: SqliteDatabase!
    var modeRegistry: ModeRegistry!
    var resolver: ModeResolver!
    var personalDictionary: PersonalDictionary!
    var historyStore: DictationHistoryStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "controller-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        try await SchemaV1.bootstrap(database: db)

        modeRegistry = ModeRegistry(persistence: .ephemeral)
        try await modeRegistry.bootstrap()
        resolver = ModeResolver(registry: modeRegistry, bundleIDProvider: { "com.apple.mail" })
        personalDictionary = PersonalDictionary(database: nil, voiceCommands: [])
        try await personalDictionary.bootstrap()
        historyStore = DictationHistoryStore(database: db)
    }

    override func tearDown() async throws {
        try? await db?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func makeDeps(
        asrText: String = "hello world",
        cleanedTemplate: @escaping @Sendable (String) -> String = { $0.uppercased() },
        pasteOutcome: PasteResult = .axInserted,
        asrFailure: TraceError? = nil,
        cleanupFailure: TraceError? = nil,
        pasteFailure: TraceError? = nil
    ) -> ScriptedPipelineDeps {
        ScriptedPipelineDeps(
            modeRegistry: modeRegistry,
            modeResolver: resolver,
            personalDictionary: personalDictionary,
            historyStore: historyStore,
            audio: ScriptedAudioSource(),
            asr: ScriptedASR(finalText: asrText, failOnFinish: asrFailure),
            cleanup: ScriptedCleanup(template: cleanedTemplate, failure: cleanupFailure),
            paste: ScriptedPaste(outcome: pasteOutcome, failure: pasteFailure)
        )
    }

    func testHappyPathCycleReachesDone() async throws {
        let deps = makeDeps()
        let controller = Dictation.makeController(dependencies: deps)
        let result = try await controller.runOneCycle(mode: .pushToTalk)
        XCTAssertEqual(result.cleanedText, "HELLO WORLD")
        XCTAssertTrue(result.pasted)
        XCTAssertEqual(result.pasteStrategy, .axInserted)
        let state = await controller.currentState()
        XCTAssertEqual(state, .done)
    }

    func testHistoryReceivesSuccessfulRecord() async throws {
        let deps = makeDeps()
        let controller = Dictation.makeController(dependencies: deps)
        let result = try await controller.runOneCycle(mode: .pushToTalk)
        let recent = try await historyStore.recent(limit: 1)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.id, result.id)
        XCTAssertEqual(recent.first?.cleanedText, "HELLO WORLD")
        XCTAssertTrue(recent.first?.inserted ?? false)
    }

    func testCleanupReceivesModeSystemPrompt() async throws {
        let cleanup = ScriptedCleanup(template: { $0 })
        let deps = ScriptedPipelineDeps(
            modeRegistry: modeRegistry,
            modeResolver: resolver,
            personalDictionary: personalDictionary,
            historyStore: historyStore,
            audio: ScriptedAudioSource(),
            asr: ScriptedASR(finalText: "hi"),
            cleanup: cleanup,
            paste: ScriptedPaste()
        )
        let controller = Dictation.makeController(dependencies: deps)
        _ = try await controller.runOneCycle(mode: .pushToTalk)
        let calls = await cleanup.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.rawText, "hi")
        let email = await modeRegistry.mode(named: "Email")
        XCTAssertEqual(calls.first?.systemPrompt, email?.systemPrompt)
    }

    func testStartCaptureRejectsRecursiveStart() async throws {
        let deps = makeDeps()
        let controller = Dictation.makeController(dependencies: deps)
        try await controller.startCapture(mode: .pushToTalk)
        do {
            try await controller.startCapture(mode: .pushToTalk)
            XCTFail("expected throw")
        } catch let err as TraceError {
            guard case .configInvalid = err else {
                XCTFail("wrong error: \(err)")
                return
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCancelDuringRecordingTransitionsToCancelled() async throws {
        let deps = makeDeps()
        let controller = Dictation.makeController(dependencies: deps)
        try await controller.startCapture(mode: .pushToTalk)
        await controller.cancel()
        let state = await controller.currentState()
        XCTAssertEqual(state, .cancelled)
    }

    func testASRFailurePersistsFailedRecord() async throws {
        let deps = makeDeps(asrFailure: .asrInferenceFailed(engine: "scripted", reason: "broken"))
        let controller = Dictation.makeController(dependencies: deps)
        try await controller.startCapture(mode: .pushToTalk)
        do {
            _ = try await controller.stopCapture()
            XCTFail("expected throw")
        } catch {
            // expected
        }
        let state = await controller.currentState()
        XCTAssertEqual(state, .failed(reason: .asrFailed))
        let count = try await historyStore.count()
        XCTAssertEqual(count, 1)
        let recent = try await historyStore.recent(limit: 1)
        XCTAssertFalse(recent.first?.inserted ?? true)
    }

    func testCleanupFailurePersistsFailedRecord() async throws {
        let deps = makeDeps(cleanupFailure: .modelRouteUnresolved(taskClass: "dictationCleanup"))
        let controller = Dictation.makeController(dependencies: deps)
        try await controller.startCapture(mode: .pushToTalk)
        do {
            _ = try await controller.stopCapture()
            XCTFail("expected throw")
        } catch {
            // expected
        }
        let state = await controller.currentState()
        XCTAssertEqual(state, .failed(reason: .cleanupFailed))
    }

    func testPasteCopiedOnlyMeansNotInserted() async throws {
        let deps = makeDeps(pasteOutcome: .copiedOnly)
        let controller = Dictation.makeController(dependencies: deps)
        let result = try await controller.runOneCycle(mode: .pushToTalk)
        XCTAssertFalse(result.pasted)
        XCTAssertEqual(result.pasteStrategy, .copiedOnly)
        let recent = try await historyStore.recent(limit: 1)
        XCTAssertFalse(recent.first?.inserted ?? true)
    }

    func testToggleModeRunsSameCycle() async throws {
        let deps = makeDeps()
        let controller = Dictation.makeController(dependencies: deps)
        let result = try await controller.runOneCycle(mode: .toggle)
        XCTAssertEqual(result.cleanedText, "HELLO WORLD")
        XCTAssertTrue(result.pasted)
    }

    func testPersonalDictionaryAppliesBeforeCleanup() async throws {
        try await personalDictionary.recordCorrection(heard: "claude", corrected: "Claude", at: 0)
        let cleanup = ScriptedCleanup(template: { $0 })
        let deps = ScriptedPipelineDeps(
            modeRegistry: modeRegistry,
            modeResolver: resolver,
            personalDictionary: personalDictionary,
            historyStore: historyStore,
            audio: ScriptedAudioSource(),
            asr: ScriptedASR(finalText: "ask claude"),
            cleanup: cleanup,
            paste: ScriptedPaste()
        )
        let controller = Dictation.makeController(dependencies: deps)
        _ = try await controller.runOneCycle(mode: .pushToTalk)
        let calls = await cleanup.calls
        XCTAssertEqual(calls.first?.rawText, "ask Claude")
    }

    func testBundleIDIsStoredOnRecord() async throws {
        let deps = makeDeps()
        let controller = Dictation.makeController(dependencies: deps)
        await controller.setResolvedBundleID("com.apple.mail")
        _ = try await controller.runOneCycle(mode: .pushToTalk)
        let recent = try await historyStore.recent(limit: 1)
        XCTAssertEqual(recent.first?.bundleID, "com.apple.mail")
    }
}
