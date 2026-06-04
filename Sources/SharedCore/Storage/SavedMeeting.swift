import Foundation

/// A finalized meeting loaded back from disk for read-only display in the
/// library ("All meetings").
///
/// Markdown is the source of truth; any missing file
/// degrades to empty rather than failing the load.
public struct SavedMeeting: Sendable, Hashable {
    public let metadata: SessionMetadata
    public let notes: String
    public let summary: String?
    public let utterances: [Utterance]

    public init(metadata: SessionMetadata, notes: String, summary: String?, utterances: [Utterance]) {
        self.metadata = metadata
        self.notes = notes
        self.summary = summary
        self.utterances = utterances
    }
}
