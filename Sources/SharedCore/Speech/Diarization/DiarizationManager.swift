@preconcurrency import AVFoundation
import FluidAudio
import Foundation

public struct DiarizedSegment: Sendable, Hashable, Codable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let speakerLabel: String
    public let embedding: [Float]?

    public init(startTime: TimeInterval, endTime: TimeInterval, speakerLabel: String, embedding: [Float]? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.speakerLabel = speakerLabel
        self.embedding = embedding
    }
}

public protocol DiarizerEngine: Sendable {
    func process(samples: [Float], sampleRate: Double) async throws -> [DiarizedSegment]
    func process(_ buffer: AVAudioPCMBuffer) async throws -> [DiarizedSegment]
    func process(contentsOf url: URL) async throws -> [DiarizedSegment]
    /// Download/compile + warm the models so the first real call doesn't pay for
    /// it (and so a meeting can confirm readiness up front).
    func prepare() async throws
}

extension DiarizerEngine {
    /// Default: load the whole file to mono samples and diarize those.
    ///
    /// Engines
    /// with an efficient file path (memory-mapped, chunked) should override.
    public func process(contentsOf url: URL) async throws -> [DiarizedSegment] {
        let (samples, sampleRate) = try DiarizationAudioReader.readMono(url)
        guard !samples.isEmpty else { return [] }
        return try await process(samples: samples, sampleRate: sampleRate)
    }

    /// Default: no-op (engines with no loadable models are always ready).
    public func prepare() async throws {}
}

public actor DiarizationManager {
    /// Identifier of the embedder behind the offline speaker segments (FluidAudio's
    /// WeSpeaker).
    ///
    /// Stamped into enrolled voiceprints (BAS-11) so a model change can
    /// be detected and stale-dimension records ignored at match time.
    public static let embeddingModel = "fluidaudio-wespeaker"

    private let engine: any DiarizerEngine

    public init(engine: any DiarizerEngine = OfflineFluidAudioDiarizer()) {
        self.engine = engine
    }

    public func diarize(_ buffer: AVAudioPCMBuffer) async throws -> [DiarizedSegment] {
        try await engine.process(buffer)
    }

    public func diarize(samples: [Float], sampleRate: Double = 16_000) async throws -> [DiarizedSegment] {
        try await engine.process(samples: samples, sampleRate: sampleRate)
    }

    /// Diarize a recorded audio file (the offline refinement path uses this on
    /// `sys.caf`).
    ///
    /// Delegates to the engine's file path.
    public func diarize(contentsOf url: URL) async throws -> [DiarizedSegment] {
        try await engine.process(contentsOf: url)
    }

    /// Download/compile + warm the diarization models (for readiness checks).
    public func prepare() async throws {
        try await engine.prepare()
    }
}

public final class OfflineFluidAudioDiarizer: DiarizerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var manager: OfflineDiarizerManager?

    public init() {}

    public func process(samples: [Float], sampleRate: Double) async throws -> [DiarizedSegment] {
        let manager = try await ensureManager()
        let normalized = try AudioResampler.resampleMono(samples, from: sampleRate)
        let result = try await manager.process(audio: normalized)
        return result.segments.map(Self.mapSegment)
    }

    /// Efficient file path: `OfflineDiarizerManager` reads + resamples the file
    /// with memory-mapped streaming, so we avoid loading the whole recording.
    public func process(contentsOf url: URL) async throws -> [DiarizedSegment] {
        let manager = try await ensureManager()
        let result = try await manager.process(url)
        return result.segments.map(Self.mapSegment)
    }

    private static func mapSegment(_ segment: TimedSpeakerSegment) -> DiarizedSegment {
        DiarizedSegment(
            startTime: TimeInterval(segment.startTimeSeconds),
            endTime: TimeInterval(segment.endTimeSeconds),
            speakerLabel: segment.speakerId,
            embedding: segment.embedding.isEmpty ? nil : segment.embedding
        )
    }

    public func process(_ buffer: AVAudioPCMBuffer) async throws -> [DiarizedSegment] {
        guard let ptr = buffer.floatChannelData else {
            throw TraceError.diarizationFailed(reason: "Expected Float32 PCM buffer")
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        let samples = Array(UnsafeBufferPointer(start: ptr[0], count: frames))
        return try await process(samples: samples, sampleRate: buffer.format.sampleRate)
    }

    public func prepare() async throws {
        _ = try await ensureManager()
    }

    private func ensureManager() async throws -> OfflineDiarizerManager {
        if let existing = lock.withLock({ manager }) { return existing }
        let mgr = OfflineDiarizerManager()
        try await mgr.prepareModels()
        lock.withLock { manager = mgr }
        return mgr
    }
}

/// Reads an audio file's first channel into mono float samples.
///
/// Backs the
/// default `DiarizerEngine.process(contentsOf:)`; the offline engine overrides
/// with a memory-mapped path so this only runs for fallback engines.
enum DiarizationAudioReader {
    static func readMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return ([], format.sampleRate) }
        return (
            Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))),
            format.sampleRate
        )
    }
}
