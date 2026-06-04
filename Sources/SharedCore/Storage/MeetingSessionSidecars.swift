import Foundation

/// Loaders for a finalized meeting's on-disk speaker sidecars, read off the
/// saved-on-disk path (by `sessionDirPath`) where the live `MeetingLiveModel` is
/// no longer in memory — the reconcile pass + the saved-meeting rename path both
/// need them after a relaunch.

/// Shared JSON encode/decode for the per-meeting sidecar files, so each concrete
/// sidecar is just a filename + element type.
///
/// Reads are best-effort (missing or
/// corrupt → nil); writes are atomic.
private enum SessionSidecarJSON {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Per-session speaker rename map (`rawSpeakerID` → display name), persisted to
/// `speakers.json` at finalize (and on a post-finalize rename).
///
/// Feeds real names
/// into the meeting RAG indexer on the reconcile path (BAS-46). Missing or corrupt
/// → empty map (the indexer falls back to default `SpeakerLabel` labels).
public enum MeetingSpeakerNames {
    public static let filename = "speakers.json"

    public static func url(sessionDirPath: String) -> URL {
        URL(fileURLWithPath: sessionDirPath).appendingPathComponent(filename, isDirectory: false)
    }

    public static func write(_ names: [String: String], to url: URL) throws {
        try SessionSidecarJSON.write(names, to: url)
    }

    public static func load(sessionDirPath: String) -> [String: String] {
        SessionSidecarJSON.load([String: String].self, at: url(sessionDirPath: sessionDirPath)) ?? [:]
    }
}

/// Per-`remote_N` mean voiceprints from the finalize diarization pass, persisted
/// to `voiceprints.json` so a post-finalize rename can re-run cross-meeting
/// enrollment off the saved meeting (BAS-43).
///
/// Missing or corrupt → empty map.
public enum MeetingVoiceprints {
    public static let filename = "voiceprints.json"

    public static func url(sessionDirPath: String) -> URL {
        URL(fileURLWithPath: sessionDirPath).appendingPathComponent(filename, isDirectory: false)
    }

    public static func write(_ embeddings: [String: [Float]], to url: URL) throws {
        try SessionSidecarJSON.write(embeddings, to: url)
    }

    public static func load(sessionDirPath: String) -> [String: [Float]] {
        SessionSidecarJSON.load([String: [Float]].self, at: url(sessionDirPath: sessionDirPath)) ?? [:]
    }
}
