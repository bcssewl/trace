@preconcurrency import AVFoundation
import SharedCore
import XCTest
import os

@testable import AppShell

/// Covers the drain semantics of `finish(timeout:)`, sample-count-derived VAD
/// timestamps across slow ASR calls, the health-event callback, and the
/// buffer-recycler hook.
final class MeetingStreamPipelineDrainTests: XCTestCase {

    private struct FixedTranscriber: SampleTranscribing {
        let engineLabel = "fake"
        let text: String
        var delayNanoseconds: UInt64 = 0
        func transcribeSamples(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return text
        }
    }

    private struct ThrowingTranscriber: SampleTranscribing {
        let engineLabel = "fake"
        func transcribeSamples(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
            throw TraceError.asrInferenceFailed(engine: "fake", reason: "synthetic failure")
        }
    }

    private actor Collector {
        private(set) var utterances: [Utterance] = []
        func add(_ u: Utterance) { utterances.append(u) }
    }

    /// A canonical 16 kHz mono float buffer of constant amplitude.
    private func buffer(amplitude: Float, frames: Int) -> AVAudioPCMBuffer {
        let format = AudioFormat.canonicalASR
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for i in 0..<frames { channel[i] = amplitude }
        return buffer
    }

    private func makePipeline(
        transcriber: any SampleTranscribing,
        recycler: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        onHealthEvent: (@Sendable (PipelineHealthEvent) -> Void)? = nil,
        collector: Collector
    ) -> MeetingStreamPipeline {
        MeetingStreamPipeline(
            speaker: .you,
            diarLabel: "test-stream",
            transcriber: transcriber,
            recycler: recycler,
            onHealthEvent: onHealthEvent,
            onSpeaking: { _ in },
            onCommitted: { await collector.add($0) }
        )
    }

    /// A source that stops yielding but never finishes its stream (the warm
    /// mic does exactly this): finish must NOT hang — it drains the backlog,
    /// detects the idle producer, flushes the in-progress segment, and returns
    /// well before the deadline.
    func testFinishOnIdleNeverFinishingStreamFlushesAndReturnsEarly() async {
        let collector = Collector()
        let pipeline = makePipeline(
            transcriber: FixedTranscriber(text: "last words"), collector: collector)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        await pipeline.run(stream)
        // 5 loud buffers → speechStart fires; NO trailing silence, NO finish:
        // an in-progress segment is left hanging when the producer goes quiet.
        for _ in 0..<5 { continuation.yield(buffer(amplitude: 0.3, frames: 2_000)) }

        let clock = ContinuousClock()
        let started = clock.now
        let result = await pipeline.finish(timeout: .seconds(10))
        let took = clock.now - started

        XCTAssertEqual(result, .drainedIdle)
        XCTAssertLessThan(took, .seconds(5), "idle stream must not burn the whole timeout")
        let committed = await collector.utterances
        XCTAssertEqual(committed.count, 1, "the in-progress segment must be flushed")
        XCTAssertEqual(committed.first?.text, "last words")
        continuation.finish()
    }

    /// A source that keeps producing past the deadline: finish returns AT the
    /// deadline with `.timedOut`, flushes what it has, and fires the
    /// `.drainTimedOut` health event (dropped tail audio is never silent).
    func testFinishTimesOutOnActivelyProducingStream() async throws {
        let collector = Collector()
        let events = OSAllocatedUnfairLock<[PipelineHealthEvent]>(initialState: [])
        let pipeline = makePipeline(
            transcriber: FixedTranscriber(text: "partial"),
            onHealthEvent: { event in events.withLock { $0.append(event) } },
            collector: collector)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        await pipeline.run(stream)

        // Producer that never stops and never finishes the stream. (One shared
        // buffer instance is fine: the pipeline copies samples per iteration
        // and the contents never change.)
        let speechBuffer = buffer(amplitude: 0.3, frames: 2_000)
        let producer = Task {
            while !Task.isCancelled {
                continuation.yield(speechBuffer)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer {
            producer.cancel()
            continuation.finish()
        }
        // Let some speech accumulate first.
        try await Task.sleep(nanoseconds: 200_000_000)

        let clock = ContinuousClock()
        let started = clock.now
        let result = await pipeline.finish(timeout: .milliseconds(600))
        let took = clock.now - started

        XCTAssertEqual(result, .timedOut)
        XCTAssertGreaterThanOrEqual(took, .milliseconds(550))
        XCTAssertLessThan(took, .seconds(5), "finish must return promptly after the deadline")
        XCTAssertTrue(
            events.withLock { $0 }.contains(.drainTimedOut(stream: "test-stream")),
            "dropped tail audio must surface as a health event")
        let committed = await collector.utterances
        XCTAssertGreaterThanOrEqual(committed.count, 1, "in-progress segment must still be flushed")
    }

    /// A cleanly finished stream drains fully and reports `.drained`.
    func testFinishReportsCleanDrainWhenStreamCompletes() async {
        let collector = Collector()
        let pipeline = makePipeline(
            transcriber: FixedTranscriber(text: "hello"), collector: collector)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        await pipeline.run(stream)
        for _ in 0..<5 { continuation.yield(buffer(amplitude: 0.3, frames: 2_000)) }
        for _ in 0..<9 { continuation.yield(buffer(amplitude: 0.0, frames: 2_000)) }
        continuation.finish()

        let result = await pipeline.finish(timeout: .seconds(10))
        XCTAssertEqual(result, .drained)
        let committed = await collector.utterances
        XCTAssertEqual(committed.count, 1)
    }

    /// Utterance timestamps derive from EXACT consumed-sample counts, so a
    /// slow ASR inference mid-stream must not skew the next segment's VAD
    /// timestamps. Layout (2 000-frame buffers = 0.125 s each):
    ///   segment 1: 5 speech + 9 silence → speechStart after buffer 3 → t = 0.25
    ///   segment 2: 5 speech + 9 silence → speechStart after buffer 17 → t = 2.0
    func testTimestampsStaySampleAccurateAcrossSlowASR() async {
        let collector = Collector()
        let pipeline = makePipeline(
            transcriber: FixedTranscriber(text: "words", delayNanoseconds: 400_000_000),
            collector: collector)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        await pipeline.run(stream)
        for _ in 0..<5 { continuation.yield(buffer(amplitude: 0.3, frames: 2_000)) }
        for _ in 0..<9 { continuation.yield(buffer(amplitude: 0.0, frames: 2_000)) }
        for _ in 0..<5 { continuation.yield(buffer(amplitude: 0.3, frames: 2_000)) }
        for _ in 0..<9 { continuation.yield(buffer(amplitude: 0.0, frames: 2_000)) }
        continuation.finish()

        let result = await pipeline.finish(timeout: .seconds(30))
        XCTAssertEqual(result, .drained)
        let committed = await collector.utterances
        XCTAssertEqual(committed.count, 2)
        XCTAssertEqual(committed[0].t, 0.25, accuracy: 0.0001)
        XCTAssertEqual(
            committed[1].t, 2.0, accuracy: 0.0001,
            "second segment's timestamp must come from consumed samples, not wall-clock drift")
    }

    /// An ASR failure mid-meeting drops the segment — that loss must surface
    /// through the health callback instead of only a log line.
    func testASRFailureFiresSegmentDroppedHealthEvent() async {
        let collector = Collector()
        let events = OSAllocatedUnfairLock<[PipelineHealthEvent]>(initialState: [])
        let pipeline = makePipeline(
            transcriber: ThrowingTranscriber(),
            onHealthEvent: { event in events.withLock { $0.append(event) } },
            collector: collector)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        await pipeline.run(stream)
        for _ in 0..<5 { continuation.yield(buffer(amplitude: 0.3, frames: 2_000)) }
        for _ in 0..<9 { continuation.yield(buffer(amplitude: 0.0, frames: 2_000)) }
        continuation.finish()
        _ = await pipeline.finish(timeout: .seconds(10))

        let committed = await collector.utterances
        XCTAssertTrue(committed.isEmpty)
        let dropped = events.withLock { $0 }.filter { event in
            if case .asrSegmentDropped(let stream, let reason, let seconds) = event {
                XCTAssertEqual(stream, "test-stream")
                XCTAssertTrue(reason.contains("synthetic failure"))
                XCTAssertGreaterThan(seconds, 0)
                return true
            }
            return false
        }
        XCTAssertEqual(dropped.count, 1)
    }

    /// Every source buffer is handed to the recycler exactly once, after the
    /// pipeline has copied its samples out — the hook that feeds the capture's
    /// IO buffer reuse pool.
    func testRecyclerReceivesEveryBufferOnce() async {
        let collector = Collector()
        let recycled = OSAllocatedUnfairLock(initialState: 0)
        let pipeline = makePipeline(
            transcriber: FixedTranscriber(text: "hi"),
            recycler: { _ in recycled.withLock { $0 += 1 } },
            collector: collector)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        await pipeline.run(stream)
        for _ in 0..<5 { continuation.yield(buffer(amplitude: 0.3, frames: 2_000)) }
        for _ in 0..<9 { continuation.yield(buffer(amplitude: 0.0, frames: 2_000)) }
        continuation.finish()
        let result = await pipeline.finish(timeout: .seconds(10))

        XCTAssertEqual(result, .drained)
        XCTAssertEqual(recycled.withLock { $0 }, 14)
    }
}
