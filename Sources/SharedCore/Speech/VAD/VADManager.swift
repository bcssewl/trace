@preconcurrency import AVFoundation
import Accelerate
import Foundation

public actor VADManager {
    public struct Config: Sendable, Hashable {
        public let energyThreshold: Float
        public let minimumSpeechFrames: Int
        public let minimumSilenceFrames: Int
        public init(energyThreshold: Float = 0.01, minimumSpeechFrames: Int = 3, minimumSilenceFrames: Int = 5) {
            self.energyThreshold = energyThreshold
            self.minimumSpeechFrames = minimumSpeechFrames
            self.minimumSilenceFrames = minimumSilenceFrames
        }
    }

    public enum Event: Sendable, Equatable {
        case speechStart(timestamp: TimeInterval)
        case speechEnd(timestamp: TimeInterval)
    }

    private let config: Config
    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0
    private var inSpeech = false

    public init(config: Config = Config()) {
        self.config = config
    }

    public func ingest(_ buffer: AVAudioPCMBuffer, frameTimestamp: TimeInterval) -> Event? {
        let rms = AudioBufferHelpers.rms(buffer)
        let isSpeechFrame = rms > config.energyThreshold

        if isSpeechFrame {
            consecutiveSpeechFrames += 1
            consecutiveSilenceFrames = 0
            if !inSpeech, consecutiveSpeechFrames >= config.minimumSpeechFrames {
                inSpeech = true
                return .speechStart(timestamp: frameTimestamp)
            }
        } else {
            consecutiveSilenceFrames += 1
            consecutiveSpeechFrames = 0
            if inSpeech, consecutiveSilenceFrames >= config.minimumSilenceFrames {
                inSpeech = false
                return .speechEnd(timestamp: frameTimestamp)
            }
        }
        return nil
    }
}
