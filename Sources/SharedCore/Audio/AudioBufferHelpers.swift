@preconcurrency import AVFoundation
import Accelerate
import Foundation

public enum AudioBufferHelpers {

    public enum Error: Swift.Error, Sendable, Equatable {
        case unsupportedFormat(String)
        case allocationFailed
        case missingChannelData
    }

    public static func extractChannelZero(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard input.format.commonFormat == .pcmFormatFloat32 else {
            throw Error.unsupportedFormat(
                "extractChannelZero requires Float32, got \(input.format.commonFormat.rawValue)")
        }
        guard let inPtr = input.floatChannelData else {
            throw Error.missingChannelData
        }

        if input.format.channelCount == 1 {
            return input
        }

        guard
            let outFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: input.format.sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw Error.allocationFailed
        }

        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: input.frameCapacity) else {
            throw Error.allocationFailed
        }
        out.frameLength = input.frameLength

        guard let outPtr = out.floatChannelData else {
            throw Error.missingChannelData
        }

        let n = Int(input.frameLength)
        // Copy channel 0's contiguous Float32 samples (stride 1, non-overlapping
        // buffers) using the standard-library typed-memory copy. Replaces the
        // deprecated `cblas_scopy` (deprecated in macOS 13.3); behavior is
        // identical for a stride-1 contiguous single-precision copy.
        outPtr[0].update(from: inPtr[0], count: n)
        return out
    }

    public static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
            let ptr = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return 0
        }
        let n = vDSP_Length(buffer.frameLength)
        var total: Float = 0
        let channels = Int(buffer.format.channelCount)
        for ch in 0..<channels {
            var sumOfSquares: Float = 0
            vDSP_svesq(ptr[ch], 1, &sumOfSquares, n)
            total += sumOfSquares
        }
        let mean = total / Float(Int(n) * channels)
        return mean.squareRoot()
    }

    internal static func averageAllChannelsForTesting(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard input.format.commonFormat == .pcmFormatFloat32,
            let inPtr = input.floatChannelData,
            let outFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: input.format.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: input.frameCapacity)
        else {
            fatalError("averageAllChannelsForTesting: setup failed")
        }
        out.frameLength = input.frameLength
        guard let outPtr = out.floatChannelData else { return out }

        let n = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        var scale: Float = 1.0 / Float(channels)
        vDSP_vsmul(inPtr[0], 1, &scale, outPtr[0], 1, vDSP_Length(n))
        for ch in 1..<channels {
            vDSP_vsma(inPtr[ch], 1, &scale, outPtr[0], 1, outPtr[0], 1, vDSP_Length(n))
        }
        return out
    }
}
