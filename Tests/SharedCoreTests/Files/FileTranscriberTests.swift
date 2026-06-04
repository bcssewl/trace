import XCTest

@testable import SharedCore

final class FileTranscriberTests: XCTestCase {

    actor StubReader: AudioFileReading {
        let result: AudioReadResult
        var receivedURLs: [URL] = []
        init(result: AudioReadResult) { self.result = result }
        func read(url: URL) async throws -> AudioReadResult {
            receivedURLs.append(url)
            return result
        }
    }

    actor StubExtractor: VideoAudioExtracting {
        let output: URL
        var receivedURLs: [URL] = []
        init(output: URL) { self.output = output }
        func extractAudio(from videoURL: URL) async throws -> URL {
            receivedURLs.append(videoURL)
            return output
        }
    }

    actor StubBackend: SampleTranscribing {
        nonisolated let engineLabel = "Stub ASR"
        private(set) var receivedSampleCounts: [Int] = []
        private let text: String
        init(text: String) { self.text = text }

        func transcribeSamples(
            _ samples: [Float], locale: Locale, previousContext: String?
        ) async throws -> String {
            receivedSampleCounts.append(samples.count)
            return text
        }
        func observedCounts() -> [Int] { receivedSampleCounts }
    }

    private func audioJob(_ name: String) -> FileBatchJob {
        FileBatchJob.makeIfSupported(
            url: URL(fileURLWithPath: "/tmp/\(name).m4a"), origin: .dragDrop
        )!
    }

    private func videoJob(_ name: String) -> FileBatchJob {
        FileBatchJob.makeIfSupported(
            url: URL(fileURLWithPath: "/tmp/\(name).mp4"), origin: .dragDrop
        )!
    }

    func testAudioInputSkipsExtractor() async throws {
        let reader = StubReader(
            result: AudioReadResult(
                samples: [0.0, 0.5, 1.0], durationMs: 1_500
            ))
        let extractor = StubExtractor(output: URL(fileURLWithPath: "/tmp/extract.m4a"))
        let backend = StubBackend(text: "hello world")
        let transcriber = FileTranscriber(
            reader: reader, extractor: extractor
        ) { _, _ in backend }

        let job = audioJob("clip")
        let result = try await transcriber.transcribe(job, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.audioURL, job.sourceURL)
        XCTAssertEqual(result.durationMs, 1_500)
        let extractorCalls = await extractor.receivedURLs
        XCTAssertTrue(extractorCalls.isEmpty)
        let backendCounts = await backend.observedCounts()
        XCTAssertEqual(backendCounts, [3])
    }

    func testVideoInputRoutesThroughExtractor() async throws {
        let extractedURL = URL(fileURLWithPath: "/tmp/extracted.m4a")
        let reader = StubReader(result: AudioReadResult(samples: [], durationMs: 0))
        let extractor = StubExtractor(output: extractedURL)
        let backend = StubBackend(text: "transcribed video")
        let transcriber = FileTranscriber(
            reader: reader, extractor: extractor
        ) { _, _ in backend }

        let job = videoJob("call")
        let result = try await transcriber.transcribe(job)

        XCTAssertEqual(result.audioURL, extractedURL)
        let extractorCalls = await extractor.receivedURLs
        XCTAssertEqual(extractorCalls, [job.sourceURL])
        let readerCalls = await reader.receivedURLs
        XCTAssertEqual(readerCalls, [extractedURL])
        XCTAssertEqual(result.text, "transcribed video")
    }

    func testStageCallbackOrdering() async throws {
        let reader = StubReader(result: AudioReadResult(samples: [0], durationMs: 1))
        let extractor = StubExtractor(output: URL(fileURLWithPath: "/tmp/x.m4a"))
        let backend = StubBackend(text: "ok")
        let transcriber = FileTranscriber(
            reader: reader, extractor: extractor
        ) { _, _ in backend }

        let stages = StagesCollector()
        let job = videoJob("call")
        _ = try await transcriber.transcribe(job) { stage in
            await stages.append(stage)
        }
        let observed = await stages.values
        XCTAssertEqual(observed, [.extracting, .transcribing])
    }

    func testMissingBackendSurfacesASRModelMissing() async throws {
        let reader = StubReader(result: AudioReadResult(samples: [], durationMs: 0))
        let extractor = StubExtractor(output: URL(fileURLWithPath: "/tmp/x.m4a"))
        let transcriber = FileTranscriber(
            reader: reader, extractor: extractor
        ) { _, _ in nil }

        do {
            _ = try await transcriber.transcribe(audioJob("clip"))
            XCTFail("Missing backend must throw")
        } catch let err as TraceError {
            if case .asrModelMissing = err {
                // expected
            } else {
                XCTFail("Wrong error: \(err)")
            }
        }
    }
}

private actor StagesCollector {
    private(set) var values: [FileBatchStatus] = []
    func append(_ stage: FileBatchStatus) { values.append(stage) }
}
