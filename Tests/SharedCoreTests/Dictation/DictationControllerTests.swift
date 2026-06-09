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
        try await DictationSchemaV34.bootstrap(database: db)

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

    // MARK: - cancel propagates to the ASR adapter (spool discard)

    func testCancelTellsASRToAbandonCycle() async throws {
        let asr = ScriptedASR(finalText: "ignored")
        let deps = ScriptedPipelineDeps(
            modeRegistry: modeRegistry,
            modeResolver: resolver,
            personalDictionary: personalDictionary,
            historyStore: historyStore,
            audio: ScriptedAudioSource(),
            asr: asr,
            cleanup: ScriptedCleanup(template: { $0 }),
            paste: ScriptedPaste()
        )
        let controller = Dictation.makeController(dependencies: deps)
        try await controller.startCapture(mode: .pushToTalk)
        await controller.cancel()

        let state = await controller.currentState()
        XCTAssertEqual(state, .cancelled)
        let cancels = await asr.cancelCount
        XCTAssertEqual(cancels, 1, "cancel() must let the ASR adapter discard its samples + spool")
        let finishes = await asr.finishCount
        XCTAssertEqual(finishes, 0)
    }

    // MARK: - start epochs (stop-before-ready zombie)

    func testStaleEpochAbortsStartBeforeAnythingHappens() async throws {
        let asr = ScriptedASR(finalText: "x")
        let audio = ScriptedAudioSource()
        let deps = ScriptedPipelineDeps(
            modeRegistry: modeRegistry,
            modeResolver: resolver,
            personalDictionary: personalDictionary,
            historyStore: historyStore,
            audio: audio,
            asr: asr,
            cleanup: ScriptedCleanup(template: { $0 }),
            paste: ScriptedPaste()
        )
        let controller = Dictation.makeController(dependencies: deps)

        let token = await controller.currentEpoch()
        // The "stop" arrives while the start path is still being assembled.
        await controller.invalidatePendingStarts()

        do {
            try await controller.startCapture(mode: .toggle, epoch: token)
            XCTFail("expected cancelledBeforeStart")
        } catch let err as DictationStartError {
            XCTAssertEqual(err, .cancelledBeforeStart)
        }

        let state = await controller.currentState()
        XCTAssertEqual(state, .idle, "an aborted pending start must leave the machine idle")
        let begins = await asr.beginCount
        XCTAssertEqual(begins, 0)
        let starts = await audio.startCount
        XCTAssertEqual(starts, 0)
    }

    func testFreshEpochStartsNormally() async throws {
        let deps = makeDeps()
        let controller = Dictation.makeController(dependencies: deps)
        let token = await controller.invalidatePendingStarts()
        try await controller.startCapture(mode: .pushToTalk, epoch: token)
        let state = await controller.currentState()
        XCTAssertEqual(state, .recording)
        await controller.cancel()
    }

    func testCancelInvalidatesInFlightEpoch() async throws {
        let deps = makeDeps()
        let controller = Dictation.makeController(dependencies: deps)
        let token = await controller.currentEpoch()
        await controller.cancel()  // user said stop — even before recording began
        do {
            try await controller.startCapture(mode: .toggle, epoch: token)
            XCTFail("expected cancelledBeforeStart")
        } catch let err as DictationStartError {
            XCTAssertEqual(err, .cancelledBeforeStart)
        }
    }

    // MARK: - chained start (no 8 s busy-wait, no silent discard)

    func testStartChainsBehindPreviousCycleTail() async throws {
        let cleanup = GatedCleanup()
        let deps = ScriptedPipelineDeps(
            modeRegistry: modeRegistry,
            modeResolver: resolver,
            personalDictionary: personalDictionary,
            historyStore: historyStore,
            audio: ScriptedAudioSource(),
            asr: ScriptedASR(finalText: "first take"),
            cleanup: cleanup,
            paste: ScriptedPaste()
        )
        let controller = Dictation.makeController(dependencies: deps)

        // Cycle 1: start + stop, with the cleanup stage gated OPEN so the tail
        // (cleaning) is still running when cycle 2 tries to start.
        try await controller.startCapture(mode: .pushToTalk)
        let stopTask = Task { try await controller.stopCapture() }

        // Wait until the first cycle is genuinely parked in .cleaning.
        var state = await controller.currentState()
        var spins = 0
        while state != .cleaning && spins < 200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            state = await controller.currentState()
            spins += 1
        }
        XCTAssertEqual(state, .cleaning)

        // Cycle 2 queues behind the tail instead of being dropped.
        let startTask = Task { try await controller.startCapture(mode: .pushToTalk) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let stillCleaning = await controller.currentState()
        XCTAssertEqual(stillCleaning, .cleaning, "queued start must not preempt the tail")

        // Release the tail — the chained start should fire immediately after.
        await cleanup.release()
        let result = try await stopTask.value
        XCTAssertEqual(result?.cleanedText, "FIRST TAKE")
        try await startTask.value

        let after = await controller.currentState()
        XCTAssertEqual(after, .recording, "chained start begins the instant the tail completes")
        await controller.cancel()
    }

    func testStopDuringChainedWaitCancelsTheQueuedStart() async throws {
        let cleanup = GatedCleanup()
        let deps = ScriptedPipelineDeps(
            modeRegistry: modeRegistry,
            modeResolver: resolver,
            personalDictionary: personalDictionary,
            historyStore: historyStore,
            audio: ScriptedAudioSource(),
            asr: ScriptedASR(finalText: "first take"),
            cleanup: cleanup,
            paste: ScriptedPaste()
        )
        let controller = Dictation.makeController(dependencies: deps)

        try await controller.startCapture(mode: .pushToTalk)
        let stopTask = Task { try await controller.stopCapture() }
        var state = await controller.currentState()
        var spins = 0
        while state != .cleaning && spins < 200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            state = await controller.currentState()
            spins += 1
        }
        XCTAssertEqual(state, .cleaning)

        // Queue a start, then invalidate it (the user pressed stop again)
        // BEFORE the tail completes.
        let token = await controller.currentEpoch()
        let startTask = Task { try await controller.startCapture(mode: .pushToTalk, epoch: token) }
        try await Task.sleep(nanoseconds: 30_000_000)
        await controller.invalidatePendingStarts()
        await cleanup.release()
        _ = try await stopTask.value

        do {
            try await startTask.value
            XCTFail("expected cancelledBeforeStart")
        } catch let err as DictationStartError {
            XCTAssertEqual(err, .cancelledBeforeStart)
        }

        // The queued start must not have begun recording.
        let after = await controller.currentState()
        XCTAssertNotEqual(after, .recording)
    }
}
