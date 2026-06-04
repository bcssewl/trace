import Foundation

public struct KbChunk: Sendable, Hashable, Codable, Identifiable {

    /// What kind of source a chunk was derived from.
    ///
    /// Drives citation rendering
    /// (playbook → open file; transcript → seek meeting@timestamp) and scope
    /// filtering. Playbook is the default so pre-provenance rows decode cleanly.
    public enum SourceKind: String, Sendable, Codable, Hashable {
        case playbook
        case transcript
        case notes
        case summary
    }

    public let id: String
    public let sourceFile: String
    public let breadcrumb: String
    public let text: String
    public let sourceSha256: String

    // MARK: Provenance (nil / .playbook for playbook chunks)

    public let sourceKind: SourceKind
    /// Owning project for meeting-derived chunks; nil for global playbooks.
    public let projectId: String?
    /// Session id for transcript/notes/summary chunks — the click-through target.
    public let meetingId: String?
    /// Display name(s) of the speaker(s) in a transcript chunk.
    public let speaker: String?
    /// Start offset (seconds from meeting start) for a transcript chunk.
    public let tsSeconds: Double?
    /// Denormalized meeting title for self-contained citation rendering.
    public let title: String?
    /// Denormalized meeting start (epoch seconds) for the "Last 90 d" filter.
    public let startedAt: Date?

    public init(
        id: String = UUID().uuidString,
        sourceFile: String,
        breadcrumb: String,
        text: String,
        sourceSha256: String,
        sourceKind: SourceKind = .playbook,
        projectId: String? = nil,
        meetingId: String? = nil,
        speaker: String? = nil,
        tsSeconds: Double? = nil,
        title: String? = nil,
        startedAt: Date? = nil
    ) {
        self.id = id
        self.sourceFile = sourceFile
        self.breadcrumb = breadcrumb
        self.text = text
        self.sourceSha256 = sourceSha256
        self.sourceKind = sourceKind
        self.projectId = projectId
        self.meetingId = meetingId
        self.speaker = speaker
        self.tsSeconds = tsSeconds
        self.title = title
        self.startedAt = startedAt
    }

}

public struct KbEmbedding: Sendable, Hashable {
    public let chunkId: String
    public let vector: [Float]
    public let configFingerprint: String

    public init(chunkId: String, vector: [Float], configFingerprint: String) {
        self.chunkId = chunkId
        self.vector = vector
        self.configFingerprint = configFingerprint
    }
}
