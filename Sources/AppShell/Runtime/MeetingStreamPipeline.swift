@preconcurrency import AVFoundation
import Foundation
import SharedCore

/// Health signal from a meeting stream pipeline. Anything that silently loses
/// audio or transcript must emit one of these (no-silent-fallback rule); the
/// deliberate junk gates (near-silence RMS, punctuation-only results) stay
/// silent because nothing real is lost.
public enum PipelineHealthEvent: Sendable, Equatable {
    /// A finished speech segment failed transcription and was dropped from the
    /// transcript. `seconds` is the dropped segment's audio length.
    case asrSegmentDropped(stream: String, reason: String, seconds: TimeInterval)
    /// Incoming audio could not be converted to the canonical format and was
    /// dropped (fired once at the start of a failure streak, not per buffer).
    case audioConversionFailed(stream: String, reason: String)
    /// `finish(timeout:)` hit its deadline with audio still unprocessed — some
    /// tail audio never reached the transcript/archive.
    case drainTimedOut(stream: String)
    /// The call-recording archive could not be opened or written (fired once at
    /// the start of a failure streak). Offline diarisation refinement and the
    /// "keep call recording" promise both depend on this file.
    case archiveFailed(stream: String, reason: String)
}

/// How a pipeline drain ended — returned by `finish(timeout:)`.
enum PipelineDrainResult: Sendable, Equatable {
    /// The capture source finished its stream and every buffered sample was
    /// processed. The archive (when enabled) holds the complete recording.
    case drained
    /// The stream never finished, but all buffered audio had been processed
    /// and no more was arriving — the producer was stopped without closing the
    /// stream (the warm mic keeps its subscriber streams open by design).
    /// Nothing was lost; the pipeline just couldn't observe end-of-stream.
    case drainedIdle
    /// The deadline expired with audio still unprocessed; the in-flight
    /// segment was flushed but later buffered audio was dropped. A
    /// `.drainTimedOut` health event fires alongside this.
    case timedOut
}

/// Drives ONE meeting audio stream (mic or system) through VAD-segmented
/// near-live transcription:
///
///   canonicalize → VAD → accumulate a speech segment → on speech-end (or a
///   max-length flush) transcribe the segment with the routed backend → emit a
///   committed `Utterance`.
///
/// This reuses the existing batch backends (Parakeet is fast enough for
/// near-real-time at the speech-segment granularity) instead of token-level
/// streaming: a finalized line appears when the speaker pauses. The meeting
/// runtime owns one pipeline per stream and feeds each its own audio.
actor MeetingStreamPipeline {
    private let speaker: Utterance.Speaker
    private let diarLabel: String
    private let transcriber: any SampleTranscribing
    /// The language to decode (BAS-74) — `.autoDetect` lets Whisper detect it.
    private let locale: Locale
    private let onSpeaking: @Sendable (Bool) async -> Void
    private let onCommitted: @Sendable (Utterance) async -> Void
    private let vad: VADManager
    /// Optional live per-segment speaker resolution (system stream only): given a
    /// segment's samples + duration, returns a refined speaker (`remote_N`) or
    /// `nil` to keep the pipeline's default coarse `speaker`.
    ///
    /// Display-only.
    private let speakerResolver: (@Sendable ([Float], TimeInterval) async -> Utterance.Speaker?)?
    /// When set, every canonical buffer is archived here (16 kHz mono) so the
    /// offline diarization pass has the recorded audio to re-diarize at finalize.
    private let archiveURL: URL?
    private var archive: SystemAudioArchiver?
    /// Optional buffer recycler: called with each source buffer once the
    /// pipeline has copied everything it needs out of it. Wire this to
    /// `SystemAudioCapture.recycle` to enable the IO-proc buffer reuse pool.
    private let recycler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Optional health observer — see `PipelineHealthEvent`. Settable at init
    /// or later via `setOnHealthEvent`.
    private var onHealthEvent: (@Sendable (PipelineHealthEvent) -> Void)?

    private var converter: AudioConverter?
    private var segment: [Float] = []
    private var segmentStart: TimeInterval = 0
    private var inSpeech = false
    private var previousContext: String?
    private var consumeTask: Task<Void, Never>?

    /// Total canonical (16 kHz) samples consumed from the stream so far.
    /// Stream-relative time is DERIVED from this exact integer count —
    /// `elapsed` — rather than accumulated float durations, so timestamps stay
    /// sample-accurate across hours and across long ASR stalls (BAS: a slow
    /// inference must not skew the next utterance's VAD timestamps).
    private var samplesConsumed: Int = 0
    private var elapsed: TimeInterval { Double(samplesConsumed) / Self.canonicalRate }

    /// True while a segment is inside the ASR backend — lets the drain loop
    /// distinguish "no progress because inference is running" (keep waiting)
    /// from "no progress because the producer stopped" (safe to cancel).
    private var asrInFlight = false
    /// Set when `consume` finishes; how it exited (stream end vs cancellation).
    private var consumeFinished = false
    private var streamReachedEnd = false
    /// Tracks a canonicalization failure streak so the health event fires once
    /// per streak instead of hundreds of times a second.
    private var canonicalizeFailureStreak = 0
    /// Same once-per-streak gate for call-recording archive failures.
    private var archiveFailureStreak = 0

    private static let canonicalRate: Double = 16_000
    /// Skip blips shorter than ~0.25 s — they're almost always noise, and the
    /// ASR backends produce garbage on sub-word fragments.
    private let minSegmentSamples = 4_000
    /// Force-flush a continuous monologue every 30 s so the transcript stays
    /// live and memory stays bounded even when nobody pauses.
    private let maxSegmentSamples = 16_000 * 30

    /// While draining, treat this much continuous no-progress (with no ASR in
    /// flight) as "the producer has stopped" and stop waiting for more audio.
    private static let drainIdleGrace: Duration = .milliseconds(300)
    private static let drainPollInterval: Duration = .milliseconds(50)

    init(
        speaker: Utterance.Speaker,
        diarLabel: String,
        transcriber: any SampleTranscribing,
        locale: Locale = .current,
        vad: VADManager = VADManager(
            config: .init(energyThreshold: 0.01, minimumSpeechFrames: 3, minimumSilenceFrames: 8)
        ),
        speakerResolver: (@Sendable ([Float], TimeInterval) async -> Utterance.Speaker?)? = nil,
        archiveURL: URL? = nil,
        recycler: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        onHealthEvent: (@Sendable (PipelineHealthEvent) -> Void)? = nil,
        onSpeaking: @escaping @Sendable (Bool) async -> Void,
        onCommitted: @escaping @Sendable (Utterance) async -> Void
    ) {
        self.speaker = speaker
        self.diarLabel = diarLabel
        self.transcriber = transcriber
        self.locale = locale
        self.vad = vad
        self.speakerResolver = speakerResolver
        self.archiveURL = archiveURL
        self.recycler = recycler
        self.onHealthEvent = onHealthEvent
        self.onSpeaking = onSpeaking
        self.onCommitted = onCommitted
    }

    /// Wire (or replace) the health observer after construction.
    func setOnHealthEvent(_ closure: @escaping @Sendable (PipelineHealthEvent) -> Void) {
        onHealthEvent = closure
    }

    /// Begin consuming the stream.
    ///
    /// Returns immediately; transcription happens on
    /// a detached task until `finish()` or the stream ends.
    func run(_ stream: AsyncStream<AVAudioPCMBuffer>) {
        consumeTask = Task { await self.consume(stream) }
    }

    /// Legacy stop: bounded short drain (500 ms), then flush.
    ///
    /// Kept source-compatible for existing call sites; prefer
    /// `finish(timeout:)`, which reports whether the drain was clean.
    func finish() async {
        _ = await finish(timeout: .milliseconds(500))
    }

    /// Stop consuming: drain buffered audio until the stream completes, the
    /// producer goes idle, or `timeout` expires — then flush any in-progress
    /// segment so the last words aren't lost, and close the archive.
    ///
    /// Semantics:
    /// - stream completes → `.drained` (everything captured reached the
    ///   transcript/archive);
    /// - stream stays open but no audio is arriving and none is buffered →
    ///   `.drainedIdle` (nothing lost; the source never closed its stream —
    ///   the warm mic does this by design);
    /// - `timeout` expires with audio still unprocessed → `.timedOut`, fires a
    ///   `.drainTimedOut` health event, cancels the consumer (dropping the
    ///   remaining backlog), flushes what it has.
    ///
    /// A `timeout` of zero (or less) skips draining and cancels immediately.
    /// Safe to call once.
    func finish(timeout: Duration) async -> PipelineDrainResult {
        // `timeout <= .zero` means "cancel immediately, blind" — we can't tell
        // whether backlog was dropped, so it reports as `.timedOut` (without
        // the health event: the caller explicitly asked for an immediate stop).
        var deadlineExpired = timeout <= .zero
        if let task = consumeTask {
            if timeout > .zero {
                let clock = ContinuousClock()
                let deadline = clock.now + timeout
                var lastProgress = samplesConsumed
                var lastProgressAt = clock.now
                while !consumeFinished {
                    let now = clock.now
                    if now >= deadline {
                        deadlineExpired = true
                        break
                    }
                    if samplesConsumed != lastProgress {
                        lastProgress = samplesConsumed
                        lastProgressAt = now
                    } else if !asrInFlight, now - lastProgressAt >= Self.drainIdleGrace {
                        // Producer stopped and the backlog is empty — nothing
                        // more will arrive; don't burn the rest of the timeout.
                        break
                    }
                    // Actor-reentrant sleep: `consume` keeps making progress
                    // (it suspends at its awaits) while we poll.
                    try? await Task.sleep(for: Self.drainPollInterval)
                }
            }
            // Cancellation ends the AsyncStream iteration; `consume` then runs
            // its archive-closing tail, so awaiting the task is always bounded
            // (modulo an ASR call already in flight, which we let commit).
            task.cancel()
            await task.value
            consumeTask = nil

            if deadlineExpired, timeout > .zero, !streamReachedEnd {
                Loggers.meeting.error(
                    "Meeting pipeline (\(self.diarLabel, privacy: .public)) drain timed out after \(String(describing: timeout), privacy: .public); dropping remaining buffered audio"
                )
                emitHealth(.drainTimedOut(stream: diarLabel))
            }
        }

        let result: PipelineDrainResult
        if streamReachedEnd || !consumeFinished {
            // Clean end-of-stream drain (or no consume task ever ran).
            result = .drained
        } else if deadlineExpired {
            result = .timedOut
        } else {
            // Stream still open when we cancelled, but the producer was idle
            // and the backlog empty — nothing was lost.
            result = .drainedIdle
        }

        if inSpeech, segment.count >= minSegmentSamples {
            await transcribeSegment()
        }
        segment.removeAll(keepingCapacity: false)
        inSpeech = false
        await onSpeaking(false)
        return result
    }

    private func consume(_ stream: AsyncStream<AVAudioPCMBuffer>) async {
        if let archiveURL {
            // Record the full continuous stream (not just VAD speech) so the
            // offline diarizer can run its own segmentation over the recording.
            do {
                archive = try SystemAudioArchiver(url: archiveURL)
            } catch {
                // No recording means no offline speaker refinement and no kept
                // call audio — never let that happen wordlessly.
                onHealthEvent?(
                    .archiveFailed(stream: diarLabel, reason: error.localizedDescription))
            }
        }
        // Drain to stream completion: the runtime stops the capture (which for
        // the system tap finishes the stream) before awaiting `finish`, and
        // `finish(timeout:)` only cancels us once the stream is done, idle, or
        // the deadline passed. Draining to the real end is what gets the whole
        // recording into the archive for the offline diarization pass.
        for await buffer in stream {
            guard let canonical = canonicalize(buffer) else {
                recycler?(buffer)
                continue
            }
            let samples = Self.monoSamples(from: canonical)
            guard !samples.isEmpty else {
                recycler?(buffer)
                continue
            }
            if archive != nil {
                do {
                    try archive?.append(samples)
                    archiveFailureStreak = 0
                } catch {
                    // Audio is dropping out of the recording (e.g. disk full);
                    // say so once per streak, not per buffer.
                    archiveFailureStreak += 1
                    if archiveFailureStreak == 1 {
                        onHealthEvent?(
                            .archiveFailed(stream: diarLabel, reason: error.localizedDescription))
                    }
                }
            }

            let event = await vad.ingest(canonical, frameTimestamp: elapsed)
            // Everything needed from the source buffer is copied out by now
            // (`samples` is a copy; the VAD only read it) — safe to recycle.
            recycler?(buffer)
            samplesConsumed += samples.count

            switch event {
            case .speechStart(let timestamp):
                inSpeech = true
                segmentStart = timestamp
                segment = samples
                await onSpeaking(true)
            case .speechEnd:
                if inSpeech { segment.append(contentsOf: samples) }
                inSpeech = false
                await onSpeaking(false)
                if segment.count >= minSegmentSamples { await transcribeSegment() }
                segment.removeAll(keepingCapacity: true)
            case .none:
                if inSpeech {
                    segment.append(contentsOf: samples)
                    // Long-monologue flush: emit a partial segment and keep going.
                    if segment.count >= maxSegmentSamples {
                        await transcribeSegment()
                        segmentStart = elapsed
                        segment.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
        archive?.finish()
        archive = nil
        // `for await` returns nil both at true stream end and when our task is
        // cancelled mid-drain; record which one this was for `finish(timeout:)`.
        streamReachedEnd = !Task.isCancelled
        consumeFinished = true
    }

    private func transcribeSegment() async {
        let samples = segment
        guard samples.count >= minSegmentSamples else { return }
        // Skip near-silent segments (room tone / echo on the off-stream while the
        // other party is speaking). Every ASR backend hallucinates a bare "." on
        // silence, and Whisper wastes a full 30 s-window pass — so gate *before*
        // transcribing. Conservative floor (below the VAD speech threshold) so
        // quiet speech still passes; tune up if silence still leaks (BAS-76).
        guard Self.rms(samples) >= 0.005 else { return }
        let start = segmentStart
        let segmentSeconds = Double(samples.count) / Self.canonicalRate
        do {
            asrInFlight = true
            defer { asrInFlight = false }
            let raw = try await transcriber.transcribeSamples(
                samples, locale: locale, previousContext: previousContext
            )
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop empty AND punctuation-only results. A bare "." / "。" on marginal
            // audio otherwise floods the transcript and pumps the Coach pipeline
            // (an Ollama embedding + Apple FM call) once per junk utterance (BAS-76).
            // `isLetter` is true for CJK, so Chinese transcripts still pass.
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            previousContext = text
            // Live display diarization: resolve a per-speaker label for this
            // segment, falling back to the coarse stream default when unavailable.
            let duration = Double(samples.count) / Self.canonicalRate
            let resolvedSpeaker = await speakerResolver?(samples, duration) ?? speaker
            let utterance = Utterance(
                t: start,
                speaker: resolvedSpeaker,
                text: text,
                conf: 0.6,
                asr: transcriber.engineLabel,
                diar: diarLabel
            )
            await onCommitted(utterance)
        } catch {
            // `TraceError.localizedDescription` is a plain property, so going
            // through `any Error` would NSError-bridge it into the generic
            // "operation couldn't be completed" — keep the typed message.
            let reason = (error as? TraceError)?.localizedDescription ?? error.localizedDescription
            Loggers.meeting.error(
                "Meeting segment transcription failed (\(self.diarLabel, privacy: .public)): \(reason, privacy: .public)"
            )
            // The segment is gone from the transcript — surface it instead of
            // only logging (no-silent-fallback): the runtime can tell the user
            // "N segments lost — consider switching engine in Settings".
            emitHealth(
                .asrSegmentDropped(
                    stream: diarLabel,
                    reason: reason,
                    seconds: segmentSeconds))
        }
    }

    private func emitHealth(_ event: PipelineHealthEvent) {
        onHealthEvent?(event)
    }

    /// Root-mean-square energy of a 16 kHz mono segment — used to skip near-silent
    /// segments before the expensive ASR pass.
    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    private func canonicalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let canonical = AudioFormat.canonicalASR
        if Self.formatsMatch(buffer.format, canonical) { return buffer }
        do {
            if converter == nil || !Self.formatsMatch(buffer.format, converter!.inputFormat) {
                // Converter churn is worth seeing in the log: a mid-meeting
                // format change (device switch, rate renegotiation) silently
                // costs a converter rebuild per change.
                let from = converter.map {
                    "\(Int($0.inputFormat.sampleRate))Hz/\($0.inputFormat.channelCount)ch"
                }
                let detail =
                    "\(Int(buffer.format.sampleRate))Hz/\(buffer.format.channelCount)ch → 16000Hz/1ch"
                    + (from.map { " (input format changed from \($0))" } ?? " (first buffer)")
                Loggers.meeting.info(
                    "Meeting pipeline (\(self.diarLabel, privacy: .public)) building audio converter: \(detail, privacy: .public)"
                )
                converter = try AudioConverter(inputFormat: buffer.format, outputFormat: canonical)
            }
            let converted = try converter!.convert(buffer)
            canonicalizeFailureStreak = 0
            return converted
        } catch {
            Loggers.meeting.error(
                "Meeting audio canonicalization failed (\(self.diarLabel, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            // Audio is being dropped; tell the runtime once per failure streak
            // (this path can fire hundreds of times a second).
            canonicalizeFailureStreak += 1
            if canonicalizeFailureStreak == 1 {
                emitHealth(
                    .audioConversionFailed(stream: diarLabel, reason: error.localizedDescription))
            }
            return nil
        }
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
            buffer.format.channelCount == 1,
            buffer.frameLength > 0,
            let ptr = buffer.floatChannelData
        else { return [] }
        return Array(UnsafeBufferPointer(start: ptr[0], count: Int(buffer.frameLength)))
    }
}
