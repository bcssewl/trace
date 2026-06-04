@preconcurrency import AVFoundation
import Foundation

enum SyntheticBuffers {

    private static func makeFloat32Format(sampleRate: Double, channels: Int) -> AVAudioFormat {
        if channels <= 2 {
            guard
                let fmt = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: AVAudioChannelCount(channels),
                    interleaved: false
                )
            else {
                fatalError("Failed to build float32 format for \(channels) channels")
            }
            return fmt
        }
        let layoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
            fatalError("Failed to build channel layout for \(channels) channels")
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )
    }

    static func float32(
        sampleRate: Double = 48_000,
        channelConstants: [Float],
        frameCount: AVAudioFrameCount = 480
    ) -> AVAudioPCMBuffer {
        let fmt = makeFloat32Format(sampleRate: sampleRate, channels: channelConstants.count)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else {
            fatalError("Failed to allocate buffer")
        }
        buf.frameLength = frameCount
        guard let ptr = buf.floatChannelData else {
            fatalError("Missing floatChannelData on buffer")
        }
        for ch in 0..<channelConstants.count {
            let value = channelConstants[ch]
            for i in 0..<Int(frameCount) {
                ptr[ch][i] = value
            }
        }
        return buf
    }

    static func sineMonoOnChannel(
        zeroOfChannels channels: Int,
        sampleRate: Double = 48_000,
        frequency: Double = 1_000,
        frameCount: AVAudioFrameCount = 4_800,
        amplitude: Float = 0.5
    ) -> (buffer: AVAudioPCMBuffer, expectedRMS: Float) {
        precondition(channels >= 1)
        let fmt = makeFloat32Format(sampleRate: sampleRate, channels: channels)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else {
            fatalError("alloc")
        }
        buf.frameLength = frameCount
        guard let ptr = buf.floatChannelData else { fatalError("data") }
        let n = Int(frameCount)
        for i in 0..<n {
            let phase = 2.0 * .pi * frequency * Double(i) / sampleRate
            ptr[0][i] = amplitude * Float(sin(phase))
        }
        for ch in 1..<channels {
            for i in 0..<n {
                ptr[ch][i] = 0
            }
        }
        return (buf, amplitude / Float(2.0).squareRoot())
    }

    static func silence(
        sampleRate: Double = 48_000,
        channels: Int = 1,
        frameCount: AVAudioFrameCount = 480
    ) -> AVAudioPCMBuffer {
        float32(
            sampleRate: sampleRate,
            channelConstants: Array(repeating: 0, count: channels),
            frameCount: frameCount
        )
    }
}
