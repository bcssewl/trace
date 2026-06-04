@preconcurrency import AVFoundation
import Foundation
import os

/// Shared mic-buffer → 16 kHz mono conversion for the dictation ASR engines.
///
/// Every batch backend expects 16 kHz mono Float32; the cloud streaming socket
/// (`DeepgramStreamingTranscriber`) wants the same audio as little-endian
/// `linear16`. Both go through here so there's exactly one resampler.
///
/// Uses `AVAudioConverter` (a proper anti-aliasing low-pass), not naive linear
/// interpolation — interpolation folds aliasing into the speech band and Apple
/// Speech rejects the result.
enum ASRAudioConvert {
    static let targetSampleRate: Double = 16_000

    static func mono16kFloat(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let inRate = buffer.format.sampleRate
        guard inRate > 0, buffer.frameLength > 0 else { return [] }
        if abs(inRate - targetSampleRate) < 1, buffer.format.channelCount == 1 {
            guard let ptr = buffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: ptr[0], count: Int(buffer.frameLength)))
        }
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )
        else { return [] }
        guard let converter = AVAudioConverter(from: buffer.format, to: outFormat) else { return [] }
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * targetSampleRate / inRate) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return [] }
        var error: NSError?
        // The input block is an `@Sendable AVAudioConverterInputBlock`, so a plain
        // captured `var` flag would be a cross-domain shared mutable. Hold the
        // one-shot "already handed over our single buffer" state in a lock-backed
        // reference instead — the closure captures the `let` lock and mutates only
        // under `withLock`, so there is no shared mutable capture. Matches
        // `SharedCore/Audio/AudioConverter.swift`.
        let pulled = OSAllocatedUnfairLock(initialState: false)
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            let alreadyPulled = pulled.withLock { value -> Bool in
                let prior = value
                value = true
                return prior
            }
            if alreadyPulled {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let outPtr = outBuffer.floatChannelData else {
            return []
        }
        return Array(UnsafeBufferPointer(start: outPtr[0], count: Int(outBuffer.frameLength)))
    }

    /// Same audio as `mono16kFloat`, packed as little-endian 16-bit PCM — the
    /// `linear16` wire format the Deepgram realtime socket expects.
    static func mono16kInt16LEData(_ buffer: AVAudioPCMBuffer) -> Data {
        let floats = mono16kFloat(buffer)
        guard !floats.isEmpty else { return Data() }
        var data = Data(capacity: floats.count * 2)
        for sample in floats {
            let clamped = max(-1.0, min(1.0, sample))
            let i16 = Int16(clamped * 32_767.0)
            withUnsafeBytes(of: i16.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
