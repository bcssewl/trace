@preconcurrency import AVFoundation
import Foundation
import XCTest

@testable import DictationModule

final class DictationModuleTests: XCTestCase {
    func testModuleNameIsCorrect() {
        XCTAssertEqual(DictationModule.moduleName, "DictationModule")
    }

    func testSharedCoreTypesReExported() async throws {
        // Verifying the @_exported import works: types defined in SharedCore
        // should be usable through DictationModule without an explicit
        // `import SharedCore` in the test file.
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let all = await registry.all()
        XCTAssertEqual(all.count, 5)
    }

    func testBootstrapRuntimeAssemblesHandle() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let resolver = ModeResolver(registry: registry, bundleIDProvider: { nil })
        let dictionary = PersonalDictionary(database: nil, voiceCommands: [])
        try await dictionary.bootstrap()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "module-runtime-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("idx.sqlite"))
        try await SchemaV1.bootstrap(database: db)
        let history = DictationHistoryStore(database: db)

        let runtime = DictationModule.bootstrapRuntime(
            controller: DictationController(
                dependencies: SyntheticPipelineDeps(
                    modeRegistry: registry,
                    modeResolver: resolver,
                    personalDictionary: dictionary,
                    historyStore: history
                )
            ),
            modeRegistry: registry,
            personalDictionary: dictionary,
            historyStore: history
        )
        let state = await runtime.controller.currentState()
        XCTAssertEqual(state, .idle)

        try await db.close()
    }
}

/// Minimal synthetic deps to satisfy DictationController initialization in
/// the bootstrap assembly test.
///
/// Mirrors the scripted doubles in
/// SharedCoreTests/Dictation but is duplicated here so DictationModuleTests
/// remains independent of SharedCoreTests target.
struct SyntheticPipelineDeps: PipelineDependencies {
    let modeRegistry: ModeRegistry
    let modeResolver: ModeResolver
    let personalDictionary: PersonalDictionary
    let historyStore: DictationHistoryStore?
    let audio: PipelineAudioSource
    let asr: PipelineASR
    let cleanup: PipelineCleanup
    let paste: PipelinePaste

    init(
        modeRegistry: ModeRegistry,
        modeResolver: ModeResolver,
        personalDictionary: PersonalDictionary,
        historyStore: DictationHistoryStore
    ) {
        self.modeRegistry = modeRegistry
        self.modeResolver = modeResolver
        self.personalDictionary = personalDictionary
        self.historyStore = historyStore
        self.audio = NoopAudio()
        self.asr = NoopASR()
        self.cleanup = NoopCleanup()
        self.paste = NoopPaste()
    }

    func now() -> TimeInterval { 0 }
}

actor NoopAudio: PipelineAudioSource {
    nonisolated let stream: AsyncStream<AVAudioPCMBuffer>
    init() {
        let (s, _) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.stream = s
    }
    func startCapture() async throws {}
    func stopCapture() async {}
    nonisolated func buffers() -> AsyncStream<AVAudioPCMBuffer> { stream }
}

actor NoopASR: PipelineASR {
    func beginCycle() async throws {}
    func finishCycle() async throws -> String { "" }
}

actor NoopCleanup: PipelineCleanup {
    func clean(rawText: String, systemPrompt: String, routeOverride: LLMRoute?) async throws -> String {
        rawText
    }
}

actor NoopPaste: PipelinePaste {
    func insert(_ text: String, behavior: InsertBehavior) async throws -> PasteResult { .axInserted }
}
