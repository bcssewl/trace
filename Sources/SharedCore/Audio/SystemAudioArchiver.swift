@preconcurrency import AVFoundation
import Foundation

/// Streams the meeting's remote (system) audio to a lossless 16 kHz mono float
/// CAF during capture.
///
/// BAS-10's offline diarization pass re-diarizes the
/// recorded system audio at finalize, but the live pipeline only ever held the
/// samples transiently for transcription — so without this nothing reaches disk
/// to re-diarize. The live system pipeline appends each canonical buffer's
/// samples here as they flow past; `finish()` flushes and closes the file.
///
/// Used only from within the system pipeline actor (single-threaded access), so
/// it keeps no internal locking.
public final class SystemAudioArchiver {

    private let format: AVAudioFormat
    private var file: AVAudioFile?

    /// Total mono frames written so far.
    public private(set) var framesWritten: Int64 = 0

    public init(url: URL, sampleRate: Double = 16_000) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
            )
        else {
            throw TraceError.audioCaptureFailed(
                reason: "SystemAudioArchiver: could not build \(sampleRate) Hz mono format"
            )
        }
        self.format = format

        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    /// Append mono float samples (at the archive's sample rate).
    ///
    /// Empty input and
    /// post-`finish()` calls are no-ops.
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty, let file else { return }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
            )
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress, let channel = buffer.floatChannelData else { return }
            channel[0].update(from: base, count: samples.count)
        }
        try file.write(from: buffer)
        framesWritten += Int64(samples.count)
    }

    /// Flush and close the file.
    ///
    /// Releasing the `AVAudioFile` finalizes it on disk.
    public func finish() {
        file = nil
    }
}
