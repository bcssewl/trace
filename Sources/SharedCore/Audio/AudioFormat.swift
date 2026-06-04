@preconcurrency import AVFoundation
import Foundation

public enum AudioFormat {

    public static let canonicalASR: AVAudioFormat = {
        guard
            let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        else {
            fatalError("Failed to construct canonical ASR audio format.")
        }
        return fmt
    }()

    public static let canonicalArchive: AVAudioFormat = {
        guard
            let fmt = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48_000,
                channels: 2,
                interleaved: true
            )
        else {
            fatalError("Failed to construct canonical archive audio format.")
        }
        return fmt
    }()

    public static func isBuiltInMicName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("macbook")
            || lower.contains("built-in")
            || lower.contains("builtin")
    }
}
