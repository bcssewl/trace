@preconcurrency import AVFoundation
import Foundation

/// Resamples mono float PCM between sample rates.
///
/// Shared by the diarization
/// engines — both the offline Pyannote wrapper and the live embedding extractor
/// need 16 kHz mono input — so the conversion lives in one place.
public enum AudioResampler {

    /// Resample mono float samples from `sourceRate` to `targetRate`.
    ///
    /// Returns the
    /// input unchanged when already at the target rate, and `[]` when conversion
    /// produces no frames. Throws if the converter can't be built.
    public static func resampleMono(
        _ samples: [Float], from sourceRate: Double, to targetRate: Double = 16_000
    ) throws -> [Float] {
        if abs(sourceRate - targetRate) < 1 { return samples }
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false
            ),
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(max(samples.count, 1))
            )
        else {
            throw TraceError.diarizationFailed(reason: "Could not build AVAudioFormat for resampling")
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress, let channel = inputBuffer.floatChannelData else { return }
            channel[0].update(from: base, count: samples.count)
        }
        let converter = try AudioConverter(inputFormat: inputFormat, outputFormat: outputFormat)
        let outputBuffer = try converter.convert(inputBuffer)
        let outFrames = Int(outputBuffer.frameLength)
        guard outFrames > 0, let outPtr = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: outPtr[0], count: outFrames))
    }
}
