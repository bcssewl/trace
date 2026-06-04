@preconcurrency import AVFoundation
import Foundation

/// Reads a file URL into a contiguous Float32 mono PCM array at the canonical
/// ASR rate (16 kHz).
///
/// Streams from disk in chunks via `AVAudioFile`, applying
/// `AudioConverter` once for the entire input format, so peak memory is
/// roughly two chunks plus the accumulated output.
///
/// `FileAudioReader` is a `struct` deliberately — there is no shared mutable
/// state. Tests can swap the protocol form via `AudioFileReading`.
public protocol AudioFileReading: Sendable {
    /// Decodes `url` to canonical ASR samples (16 kHz Float32 mono) and reports
    /// the source duration in milliseconds.
    func read(url: URL) async throws -> AudioReadResult
}

public struct AudioReadResult: Sendable, Hashable {
    public let samples: [Float]
    public let durationMs: Int64
    public init(samples: [Float], durationMs: Int64) {
        self.samples = samples
        self.durationMs = durationMs
    }
}

public struct FileAudioReader: AudioFileReading {

    /// Maximum frames read per `AVAudioFile.read(into:)` call.
    ///
    /// Sized so a
    /// 90-minute 48 kHz stereo decoded chunk stays well under 20 MB.
    public let chunkFrames: AVAudioFrameCount

    public init(chunkFrames: AVAudioFrameCount = 65_536) {
        self.chunkFrames = chunkFrames
    }

    public func read(url: URL) async throws -> AudioReadResult {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TraceError.audioCaptureFailed(
                reason: "AVAudioFile(forReading:) failed for \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }

        let sourceFormat = file.processingFormat
        let totalFrames = file.length
        let durationSeconds = Double(totalFrames) / max(sourceFormat.sampleRate, 1)
        let durationMs = Int64((durationSeconds * 1000).rounded())

        let target = AudioFormat.canonicalASR
        let converter = try AudioConverter(inputFormat: sourceFormat, outputFormat: target)

        var samples: [Float] = []
        // Pre-reserve based on naive ratio with a margin for AVAudioConverter's
        // primer (~6% reduction documented in M03).
        let estimatedOut = Int(
            (Double(totalFrames) * (target.sampleRate / max(sourceFormat.sampleRate, 1))).rounded(.up))
        samples.reserveCapacity(max(estimatedOut, 0))

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
            throw TraceError.audioCaptureFailed(reason: "Failed to allocate input AVAudioPCMBuffer")
        }

        while file.framePosition < totalFrames {
            inputBuffer.frameLength = 0
            do {
                try file.read(into: inputBuffer)
            } catch {
                throw TraceError.audioCaptureFailed(
                    reason: "AVAudioFile.read failed: \(error.localizedDescription)"
                )
            }
            if inputBuffer.frameLength == 0 { break }
            let output = try converter.convert(inputBuffer)
            try Self.appendMono(buffer: output, into: &samples)
        }

        return AudioReadResult(samples: samples, durationMs: durationMs)
    }

    private static func appendMono(buffer: AVAudioPCMBuffer, into samples: inout [Float]) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
            buffer.format.channelCount == 1
        else {
            throw TraceError.audioCaptureFailed(
                reason: "FileAudioReader produced non-canonical buffer (\(buffer.format))"
            )
        }
        guard let ptr = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channelPtr = ptr[0]
        let bufferPointer = UnsafeBufferPointer(start: channelPtr, count: frames)
        samples.append(contentsOf: bufferPointer)
    }
}
