@preconcurrency import AVFoundation
import Foundation
import os.lock

@testable import SharedCore

/// Tells the scripted audio source what to publish on `startCapture()`.
struct ScriptedAudioScript: Sendable {
    let buffers: [AVAudioPCMBuffer]
}

actor ScriptedAudioSource: PipelineAudioSource {
    private let script: ScriptedAudioScript
    nonisolated let stream: AsyncStream<AVAudioPCMBuffer>
    nonisolated let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private(set) var startCount: Int = 0
    private(set) var stopCount: Int = 0

    init(script: ScriptedAudioScript = .init(buffers: [])) {
        self.script = script
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.stream = stream
        self.continuation = continuation
    }

    func startCapture() async throws {
        startCount += 1
        for buffer in script.buffers {
            continuation.yield(buffer)
        }
        // The scripted clip is finite: once its buffers are delivered the audio
        // is over, so end the stream. `runOneCycle`'s VAD endpoint loop treats a
        // finished stream as the capture endpoint (a real finite recording ends
        // the same way) rather than waiting for a VAD speech-end a fixed script
        // can't produce — so an empty script finalizes immediately instead of
        // hanging to the timeout. Hand-driven, stays-open audio is a separate
        // double (`LiveControllableAudio`).
        continuation.finish()
    }

    func stopCapture() async {
        stopCount += 1
        continuation.finish()
    }

    nonisolated func buffers() -> AsyncStream<AVAudioPCMBuffer> {
        stream
    }
}

actor ScriptedASR: PipelineASR {
    private let finalText: String
    private let failOnFinish: TraceError?
    private(set) var beginCount = 0
    private(set) var finishCount = 0

    init(finalText: String, failOnFinish: TraceError? = nil) {
        self.finalText = finalText
        self.failOnFinish = failOnFinish
    }

    func beginCycle() async throws {
        beginCount += 1
    }

    func finishCycle() async throws -> String {
        finishCount += 1
        if let failure = failOnFinish { throw failure }
        return finalText
    }
}

actor ScriptedCleanup: PipelineCleanup {
    private let template: (String) -> String
    private let failure: TraceError?
    private(set) var calls: [(rawText: String, systemPrompt: String, routeOverride: LLMRoute?)] = []

    init(template: @escaping @Sendable (String) -> String, failure: TraceError? = nil) {
        self.template = template
        self.failure = failure
    }

    func clean(rawText: String, systemPrompt: String, routeOverride: LLMRoute?) async throws -> String {
        calls.append((rawText, systemPrompt, routeOverride))
        if let failure { throw failure }
        return template(rawText)
    }
}

actor ScriptedPaste: PipelinePaste {
    private let outcome: PasteResult
    private let failure: TraceError?
    private(set) var calls: [(text: String, behavior: InsertBehavior)] = []

    init(outcome: PasteResult = .axInserted, failure: TraceError? = nil) {
        self.outcome = outcome
        self.failure = failure
    }

    func insert(_ text: String, behavior: InsertBehavior) async throws -> PasteResult {
        calls.append((text, behavior))
        if let failure { throw failure }
        return outcome
    }
}

struct ScriptedPipelineDeps: PipelineDependencies {
    let modeRegistry: ModeRegistry
    let modeResolver: ModeResolver
    let personalDictionary: PersonalDictionary
    let historyStore: DictationHistoryStore?
    let audio: PipelineAudioSource
    let asr: PipelineASR
    let cleanup: PipelineCleanup
    let paste: PipelinePaste
    let clock: ScriptedClock

    init(
        modeRegistry: ModeRegistry,
        modeResolver: ModeResolver,
        personalDictionary: PersonalDictionary,
        historyStore: DictationHistoryStore? = nil,
        audio: PipelineAudioSource,
        asr: PipelineASR,
        cleanup: PipelineCleanup,
        paste: PipelinePaste,
        clock: ScriptedClock = ScriptedClock()
    ) {
        self.modeRegistry = modeRegistry
        self.modeResolver = modeResolver
        self.personalDictionary = personalDictionary
        self.historyStore = historyStore
        self.audio = audio
        self.asr = asr
        self.cleanup = cleanup
        self.paste = paste
        self.clock = clock
    }

    func now() -> TimeInterval {
        clock.now()
    }
}

final class ScriptedClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<TimeInterval>(initialState: 1_700_000_000)

    func now() -> TimeInterval {
        lock.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { $0 += seconds }
    }
}
