import Foundation

/// A single retrieved context passage feeding cross-meeting Q&A. It unifies the
/// two arms of hybrid retrieval — dense (cosine over `kb_chunks`) and lexical
/// (FTS5 over transcripts/notes) — behind one type so the pipeline can fuse,
/// rank, cite, and (for meeting-derived passages) deep-link to `meeting @ ts`.
public struct RetrievedPassage: Sendable, Hashable, Identifiable {

    public enum Origin: String, Sendable, Hashable, Codable {
        case dense  // cosine vector match
        case lexical  // FTS5 keyword match
    }

    public let id: String
    public let kind: KbChunk.SourceKind
    public let text: String
    public let projectId: String?
    public let meetingId: String?
    public let title: String?
    public let speaker: String?
    public let tsSeconds: Double?
    public let sourceFile: String?
    public let breadcrumb: String?
    public let score: Float
    public let origin: Origin

    public init(
        id: String,
        kind: KbChunk.SourceKind,
        text: String,
        projectId: String? = nil,
        meetingId: String? = nil,
        title: String? = nil,
        speaker: String? = nil,
        tsSeconds: Double? = nil,
        sourceFile: String? = nil,
        breadcrumb: String? = nil,
        score: Float,
        origin: Origin
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.projectId = projectId
        self.meetingId = meetingId
        self.title = title
        self.speaker = speaker
        self.tsSeconds = tsSeconds
        self.sourceFile = sourceFile
        self.breadcrumb = breadcrumb
        self.score = score
        self.origin = origin
    }

    /// True when this passage points at a meeting the UI can open at a timestamp.
    public var isMeetingAnchored: Bool {
        meetingId != nil && (kind == .transcript || kind == .notes || kind == .summary)
    }

    /// What a citation's "open" affordance should do.
    ///
    /// Meeting-derived passages
    /// deep-link to `meeting @ ts`; playbook passages open their source file at the
    /// breadcrumb; anything without enough provenance to act on returns nil (so the
    /// UI hides the affordance). One home for the meeting-vs-playbook branch shared
    /// by the inline chip + the Citations-list row (BAS-27).
    public enum OpenTarget: Sendable, Hashable {
        case meeting(id: String, tsSeconds: Double?)
        case file(path: String, breadcrumb: String?)
    }

    public var openTarget: OpenTarget? {
        if isMeetingAnchored, let meetingId {
            return .meeting(id: meetingId, tsSeconds: tsSeconds)
        }
        if kind == .playbook, let sourceFile, !sourceFile.isEmpty {
            return .file(path: sourceFile, breadcrumb: breadcrumb)
        }
        return nil
    }

    /// Uppercase source-kind label for citation chrome (TRANSCRIPT / NOTES / …).
    public var kindLabel: String {
        switch kind {
        case .transcript: return "TRANSCRIPT"
        case .notes: return "NOTES"
        case .summary: return "SUMMARY"
        case .playbook: return "PLAYBOOK"
        }
    }

    /// Human-readable provenance pieces (excluding the kind label): meeting title,
    /// speaker, `@ mm:ss`, or a playbook breadcrumb — joined by the caller.
    public var provenanceParts: [String] {
        switch kind {
        case .playbook:
            if let breadcrumb, !breadcrumb.isEmpty { return [breadcrumb] }
            return sourceFile.map { [$0] } ?? []
        case .transcript, .notes, .summary:
            var parts: [String] = []
            if let title, !title.isEmpty { parts.append(title) }
            if let speaker, !speaker.isEmpty { parts.append(speaker) }
            if let tsSeconds { parts.append("@ \(TranscriptChunker.timeLabel(tsSeconds))") }
            return parts
        }
    }

    /// Stable key for collapsing overlapping dense/lexical hits that refer to the
    /// same region of the same meeting (timestamps bucketed to ~1 min) or the
    /// same playbook section, so one cited source isn't listed twice.
    public var dedupeKey: String {
        if let meetingId {
            let bucket = tsSeconds.map { Int(($0 / 60).rounded(.down)) } ?? -1
            return "m:\(meetingId):\(kind.rawValue):\(bucket)"
        }
        return "p:\(sourceFile ?? id):\(breadcrumb ?? "")"
    }

    /// Build a dense passage from a provenance-bearing vector hit.
    public init(denseHit chunk: KbChunk, score: Float) {
        self.init(
            id: "dense:\(chunk.id)",
            kind: chunk.sourceKind,
            text: chunk.text,
            projectId: chunk.projectId,
            meetingId: chunk.meetingId,
            title: chunk.title,
            speaker: chunk.speaker,
            tsSeconds: chunk.tsSeconds,
            sourceFile: chunk.sourceFile,
            breadcrumb: chunk.breadcrumb.isEmpty ? nil : chunk.breadcrumb,
            score: score,
            origin: .dense
        )
    }
}
