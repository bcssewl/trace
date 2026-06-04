@preconcurrency import AVFoundation
import Foundation

public enum BackendStatus: Sendable, Codable, Hashable {
    case unavailable(reason: String)
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case loaded
}

public enum ASRDelta: Sendable, Codable, Hashable {
    case partial(String)
    case final(String)
    case endpoint

    public var text: String {
        switch self {
        case .partial(let text), .final(let text): text
        case .endpoint: ""
        }
    }

    public var isFinal: Bool {
        if case .final = self { return true }
        return false
    }
}

public protocol TranscriptionBackend: Sendable {
    var displayName: String { get }
    func checkStatus() async -> BackendStatus
    func prepare(
        onStatus: @escaping @Sendable (BackendStatus) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String
    func transcribeStream(_ buffer: AVAudioPCMBuffer) async throws -> ASRDelta?
    func clearModelCache() async
}

public actor ScriptedTranscriptionBackend: TranscriptionBackend {
    public nonisolated let displayName = "Scripted"
    private let text: String

    public init(text: String) {
        self.text = text
    }

    public func checkStatus() async -> BackendStatus { .ready }
    public func prepare(
        onStatus: @escaping @Sendable (BackendStatus) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        onStatus(.loaded)
        onProgress(1)
    }
    public func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
        text
    }
    public func transcribeStream(_ buffer: AVAudioPCMBuffer) async throws -> ASRDelta? {
        .final(text)
    }
    public func clearModelCache() async {}
}
