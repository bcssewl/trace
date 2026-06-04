import XCTest

@testable import AppShell
@testable import SharedCore

/// BAS-8 (WhisperKit + Qwen3 selectable) and BAS-21/BAS-7 (cloud engine +
/// streaming) at the dictation registry layer.
final class ASREngineRegistryTests: XCTestCase {

    // MARK: BAS-8 — WhisperKit + Qwen3 are real, selectable dictation engines

    func testBackendForWhisperKitIsWhisperKitBackend() {
        XCTAssertTrue(ASREngineRegistry.backend(for: .whisperKit) is WhisperKitBackend)
    }

    func testBackendForQwen3IsQwen3Backend() {
        XCTAssertTrue(ASREngineRegistry.backend(for: .qwen3) is Qwen3Backend)
    }

    func testWhisperKitAndQwen3AreBatchOnly() {
        XCTAssertFalse(DictationASREngine.whisperKit.supportsStreaming)
        XCTAssertFalse(DictationASREngine.qwen3.supportsStreaming)
        XCTAssertNil(ASREngineRegistry.makeStreamingTranscriber(for: .whisperKit))
        XCTAssertNil(ASREngineRegistry.makeStreamingTranscriber(for: .qwen3))
    }

    func testWhisperKitAndQwen3AreNotCloud() {
        XCTAssertFalse(DictationASREngine.whisperKit.isCloud)
        XCTAssertFalse(DictationASREngine.qwen3.isCloud)
        XCTAssertFalse(DictationASREngine.parakeet.isCloud)
        XCTAssertFalse(DictationASREngine.appleSpeech.isCloud)
    }

    // MARK: BAS-21 — cloud is a selectable dictation engine

    func testBackendForCloudIsCloudBackend() {
        XCTAssertTrue(ASREngineRegistry.backend(for: .cloud, cloudProvider: .groq) is CloudASRBackend)
    }

    func testCloudEngineIsCloud() {
        XCTAssertTrue(DictationASREngine.cloud.isCloud)
    }

    // MARK: BAS-7 — a second streaming engine (Deepgram), via its own transcriber

    func testCloudDeepgramProvidesStreamingTranscriber() {
        guard let streamer = ASREngineRegistry.makeStreamingTranscriber(for: .cloud, cloudProvider: .deepgram) else {
            return XCTFail("expected a cloud streaming transcriber for Deepgram")
        }
        // Its OWN transcriber (BAS-7), not a reuse of Apple's local one.
        XCTAssertTrue(streamer is DeepgramStreamingTranscriber)
    }

    func testCloudNonStreamingProviderFallsBackToBatch() {
        // Groq has no realtime socket → nil here → pipeline uses the batch path.
        XCTAssertNil(ASREngineRegistry.makeStreamingTranscriber(for: .cloud, cloudProvider: .groq))
    }

    // MARK: every engine is presentable

    func testEveryEngineHasDisplayName() {
        for engine in DictationASREngine.allCases {
            XCTAssertFalse(engine.displayName.isEmpty, "\(engine) needs a display name")
        }
    }
}
