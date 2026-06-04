import Foundation

public struct EnrolledSpeaker: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let meanEmbedding: [Float]
    public let embeddingModel: String

    public init(id: String, name: String, meanEmbedding: [Float], embeddingModel: String) {
        self.id = id
        self.name = name
        self.meanEmbedding = meanEmbedding
        self.embeddingModel = embeddingModel
    }
}

public struct SpeakerMatch: Sendable, Hashable {
    public let speaker: EnrolledSpeaker
    public let similarity: Float
}

public actor SpeakerEnrollment {
    public static let defaultThreshold: Float = 0.6

    private var speakers: [String: EnrolledSpeaker] = [:]
    private let threshold: Float

    public init(threshold: Float = SpeakerEnrollment.defaultThreshold, speakers: [EnrolledSpeaker] = []) {
        self.threshold = threshold
        for speaker in speakers { self.speakers[speaker.id] = speaker }
    }

    public func enroll(_ speaker: EnrolledSpeaker) {
        speakers[speaker.id] = speaker
    }

    public func remove(speakerID: String) {
        speakers.removeValue(forKey: speakerID)
    }

    public func match(embedding: [Float]) -> SpeakerMatch? {
        let normalized = CosineMath.normalize(embedding)
        var best: SpeakerMatch?
        for speaker in speakers.values {
            let other = CosineMath.normalize(speaker.meanEmbedding)
            guard other.count == normalized.count else { continue }
            let score = CosineMath.dotProduct(normalized, other)
            if score >= threshold, score > (best?.similarity ?? 0) {
                best = SpeakerMatch(speaker: speaker, similarity: score)
            }
        }
        return best
    }

    public func snapshot() -> [EnrolledSpeaker] {
        Array(speakers.values).sorted { $0.id < $1.id }
    }
}
