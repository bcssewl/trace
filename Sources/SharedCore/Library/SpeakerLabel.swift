import Foundation

/// Maps a raw transcript speaker id (`"you"`, `"system_audio"`, `"remote_2"`)
/// to a human display name.
///
/// This is the stateless half of
/// `MeetingLiveModel.displayName(for:)` — the live view additionally honors
/// per-session renames held only in memory, which aren't available off the
/// finalized-on-disk path the library indexer + search run on, so those code
/// paths fall back to these defaults.
public enum SpeakerLabel {
    public static func display(forRawSpeaker raw: String) -> String {
        switch raw {
        case "you": return "You"
        case "system_audio": return "Others"
        default:
            if raw.hasPrefix("remote_"), let n = Int(raw.dropFirst("remote_".count)) {
                return "Speaker \(n)"
            }
            return raw
        }
    }
}
