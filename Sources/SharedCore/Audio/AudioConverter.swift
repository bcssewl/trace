@preconcurrency import AVFoundation
import Foundation
import os

public final class AudioConverter {

    public private(set) var inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat

    private var converter: AVAudioConverter

    public init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
        guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TraceError.audioCaptureFailed(
                reason: "AVAudioConverter init failed: \(inputFormat) → \(outputFormat)")
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = conv
    }

    public var currentInputSampleRate: Double {
        inputFormat.sampleRate
    }

    public func rebuildForMeasuredRate(_ measured: Double) throws {
        guard
            let newInputFmt = AVAudioFormat(
                commonFormat: inputFormat.commonFormat,
                sampleRate: measured,
                channels: inputFormat.channelCount,
                interleaved: inputFormat.isInterleaved
            )
        else {
            throw TraceError.audioCaptureFailed(
                reason: "Failed to build AVAudioFormat at measured rate \(measured)")
        }
        guard let conv = AVAudioConverter(from: newInputFmt, to: outputFormat) else {
            throw TraceError.audioCaptureFailed(
                reason: "AVAudioConverter rebuild failed at measured rate \(measured)")
        }
        self.inputFormat = newInputFmt
        self.converter = conv
        Loggers.audio.info("AudioConverter rebuilt at measured \(measured, privacy: .public) Hz")
    }

    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard input.format.sampleRate == inputFormat.sampleRate,
            input.format.channelCount == inputFormat.channelCount,
            input.format.commonFormat == inputFormat.commonFormat
        else {
            throw TraceError.audioCaptureFailed(
                reason: "Input buffer format mismatch: \(input.format) vs \(inputFormat)")
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outFrameCapacity = AVAudioFrameCount(
            (Double(input.frameLength) * ratio).rounded(.up) + 32)

        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outFrameCapacity
            )
        else {
            throw TraceError.audioCaptureFailed(reason: "AVAudioPCMBuffer alloc failed")
        }

        let consumed = OSAllocatedUnfairLock(initialState: false)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            let wasConsumed = consumed.withLock { value -> Bool in
                let prior = value
                value = true
                return prior
            }
            if wasConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)

        switch status {
        case .haveData, .endOfStream, .inputRanDry:
            return output
        case .error:
            throw TraceError.audioCaptureFailed(
                reason: "AVAudioConverter error: \(error?.localizedDescription ?? "<nil>")")
        @unknown default:
            throw TraceError.audioCaptureFailed(reason: "AVAudioConverter unknown status: \(status)")
        }
    }
}
