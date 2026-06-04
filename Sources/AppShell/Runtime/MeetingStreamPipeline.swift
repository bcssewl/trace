@preconcurrency import AVFoundation
import Foundation
import SharedCore

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

    private var converter: AudioConverter?
    private var segment: [Float] = []
    private var segmentStart: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private var inSpeech = false
    private var previousContext: String?
    private var consumeTask: Task<Void, Never>?

    private static let canonicalRate: Double = 16_000
    /// Skip blips shorter than ~0.25 s — they're almost always noise, and the
    /// ASR backends produce garbage on sub-word fragments.
    private let minSegmentSamples = 4_000
    /// Force-flush a continuous monologue every 30 s so the transcript stays
    /// live and memory stays bounded even when nobody pauses.
    private let maxSegmentSamples = 16_000 * 30

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
        self.onSpeaking = onSpeaking
        self.onCommitted = onCommitted
    }

    /// Begin consuming the stream.
    ///
    /// Returns immediately; transcription happens on
    /// a detached task until `finish()` or the stream ends.
    func run(_ stream: AsyncStream<AVAudioPCMBuffer>) {
        consumeTask = Task { await self.consume(stream) }
    }

    /// Stop consuming and flush any in-progress segment so the last words aren't
    /// lost.
    ///
    /// Safe to call once.
    func finish() async {
        consumeTask?.cancel()
        await consumeTask?.value
        consumeTask = nil
        if inSpeech, segment.count >= minSegmentSamples {
            await transcribeSegment()
        }
        segment.removeAll(keepingCapacity: false)
        inSpeech = false
        await onSpeaking(false)
    }

    private func consume(_ stream: AsyncStream<AVAudioPCMBuffer>) async {
        if let archiveURL {
            // Record the full continuous stream (not just VAD speech) so the
            // offline diarizer can run its own segmentation over the recording.
            archive = try? SystemAudioArchiver(url: archiveURL)
        }
        // Drain to stream completion (the runtime stops the capture, which
        // finishes the stream, before awaiting `finish()`). Draining rather than
        // bailing on cancellation ensures the whole recording reaches the archive
        // for the offline diarization pass — no lost tail audio.
        for await buffer in stream {
            guard let canonical = canonicalize(buffer) else { continue }
            let samples = Self.monoSamples(from: canonical)
            guard !samples.isEmpty else { continue }
            try? archive?.append(samples)
            let duration = Double(samples.count) / Self.canonicalRate

            let event = await vad.ingest(canonical, frameTimestamp: elapsed)
            elapsed += duration

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
        do {
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
            Loggers.meeting.error(
                "Meeting segment transcription failed (\(self.diarLabel, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
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
                converter = try AudioConverter(inputFormat: buffer.format, outputFormat: canonical)
            }
            return try converter!.convert(buffer)
        } catch {
            Loggers.meeting.error(
                "Meeting audio canonicalization failed (\(self.diarLabel, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
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
