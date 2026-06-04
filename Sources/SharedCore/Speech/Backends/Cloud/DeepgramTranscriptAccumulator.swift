import Foundation

/// Turns Deepgram's realtime result frames into one cumulative transcript.
///
/// Deepgram's streaming socket emits a series of JSON result frames. Each frame
/// carries `channel.alternatives[0].transcript` plus an `is_final` flag:
/// interim frames (`is_final == false`) *replace* the in-progress utterance with
/// a refined guess, and a final frame *commits* it — after which the next interim
/// starts a brand-new utterance. So, exactly like Apple's on-device chunking, we
/// keep finalized text in `committed` and the live guess in `interim`, and expose
/// their join.
///
/// Pure and synchronous so it can be unit-tested with scripted frames; the
/// network socket (`DeepgramStreamingTranscriber`) just feeds it raw frames.
public struct DeepgramTranscriptAccumulator {
    private var committed = ""
    private var interim = ""

    public init() {}

    /// The full transcript so far: committed finals plus the current interim.
    public var cumulative: String { Self.join(committed, interim) }

    /// Ingests one raw JSON frame.
    ///
    /// Returns the new cumulative transcript when the
    /// frame advanced it, or `nil` when the frame carried nothing usable (not a
    /// result, unparseable, or an empty transcript) so the caller can skip a
    /// redundant UI update.
    public mutating func ingest(jsonFrame: String) -> String? {
        guard let data = jsonFrame.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let channel = root["channel"] as? [String: Any],
            let alternatives = channel["alternatives"] as? [[String: Any]],
            let transcript = alternatives.first?["transcript"] as? String,
            !transcript.isEmpty
        else { return nil }

        let isFinal = (root["is_final"] as? Bool) ?? false
        if isFinal {
            committed = Self.join(committed, transcript)
            interim = ""
        } else {
            interim = transcript
        }
        return cumulative
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
