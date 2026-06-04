import Foundation

public struct LibraryItem: Sendable, Hashable, Identifiable {

    public enum Source: String, Sendable, Hashable, Codable {
        case meeting
        case dictation
        case file
        case voiceMemo
        case transcript
        case notes
        case playbook
    }

    public let id: String
    public let source: Source
    public let projectId: String?
    public let title: String
    public let startedAt: Date

    public init(id: String, source: Source, projectId: String?, title: String, startedAt: Date) {
        self.id = id
        self.source = source
        self.projectId = projectId
        self.title = title
        self.startedAt = startedAt
    }
}

public struct KeywordHit: Sendable, Hashable, Identifiable {
    public let id: String
    public let source: LibraryItem.Source
    /// The owning item's id: a `meetingId` for transcript/notes hits, or the
    /// dictation / file / voice-memo id for entry hits.
    ///
    /// Used as the grouping key
    /// and the open-target id.
    public let itemId: String
    public let projectId: String?
    public let title: String
    public let snippet: String
    /// Transcript-utterance offset (seconds) for deep-link seek; nil for notes and
    /// for whole-item (dictation / file / voice-memo) hits.
    public let timestamp: Double?
    /// Resolved speaker display name for a transcript hit; nil otherwise.
    public let speaker: String?
    /// Item start, for "Last 90 d" scope + when-column display.
    public let startedAt: Date?

    public init(
        id: String, source: LibraryItem.Source, itemId: String, projectId: String?,
        title: String, snippet: String, timestamp: Double?,
        speaker: String? = nil, startedAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.itemId = itemId
        self.projectId = projectId
        self.title = title
        self.snippet = snippet
        self.timestamp = timestamp
        self.speaker = speaker
        self.startedAt = startedAt
    }
}

public struct SemanticHit: Sendable, Hashable, Identifiable {
    public let id: String
    public let chunk: KbChunk
    public let score: Float

    public init(id: String, chunk: KbChunk, score: Float) {
        self.id = id
        self.chunk = chunk
        self.score = score
    }
}
