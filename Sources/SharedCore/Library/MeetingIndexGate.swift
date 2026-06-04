import Foundation

/// The mtime gate for the meeting-index reconcile pass (BAS-28).
///
/// Decides whether
/// a meeting must be re-read from disk + re-indexed, and provides the cheap
/// `stat`-based content-change probe it relies on.
///
/// The reconcile skips a meeting only when it's already embedded at the current
/// embedding fingerprint AND its content hasn't changed since the last successful
/// index — so an unchanged steady-state launch reads nothing from disk (just a
/// few `stat`s), an edited meeting is re-indexed, and an embedding-model change
/// (which empties the current-fingerprint set) re-indexes everything.
public enum MeetingIndexGate {

    /// - Parameters:
    ///   - indexedAtCurrentFingerprint: meeting already has chunks at the current
    ///     embedding fingerprint (false ⇒ new meeting or model changed).
    ///   - lastIndexedAt: the persisted `last_indexed_at` stamp (unix seconds).
    ///   - contentMtime: max mtime of the meeting's content files, or nil if none
    ///     are readable.
    public static func shouldReindex(
        indexedAtCurrentFingerprint: Bool, lastIndexedAt: Int64?, contentMtime: Int64?
    ) -> Bool {
        guard indexedAtCurrentFingerprint else { return true }
        guard let lastIndexedAt else { return true }
        guard let contentMtime else { return false }
        return contentMtime > lastIndexedAt
    }

    /// Files whose mtime represents a meeting's indexable content. `speakers.json`
    /// counts because a post-finalize rename rewrites it and the resolved speaker
    /// names are baked into transcript chunks (BAS-46) — so a rename must re-read.
    private static let contentFiles = [
        "notes.md", "summary.md", "transcript.final.jsonl", "transcript.live.jsonl",
        MeetingSpeakerNames.filename,
    ]

    /// Max modification time (unix seconds) across a meeting's content files, or
    /// nil when none exist / are readable.
    ///
    /// A `stat` per file — no content read.
    public static func contentMtime(sessionDirPath: String) -> Int64? {
        let dir = URL(fileURLWithPath: sessionDirPath)
        let fm = FileManager.default
        var maxMtime: Int64?
        for name in contentFiles {
            let path = dir.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                let date = attrs[.modificationDate] as? Date
            else { continue }
            let mtime = Int64(date.timeIntervalSince1970)
            maxMtime = max(maxMtime ?? mtime, mtime)
        }
        return maxMtime
    }
}
