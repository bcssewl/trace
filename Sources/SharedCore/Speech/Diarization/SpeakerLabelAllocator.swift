import Foundation

/// Turns the opaque cluster ids a diarization engine emits (FluidAudio numbers
/// its speakers "1", "2", …; Pyannote uses "0", "1", …) into the stable
/// `remote_1 / remote_2 / …` labels the rest of the app renders via
/// `SpeakerLabel.display(forRawSpeaker:)`.
///
/// Numbering follows the order clusters
/// are first seen, so feeding clusters in time order yields labels that count up
/// as new speakers appear. Both the live and offline passes share this so a
/// given engine cluster always maps to the same `remote_N` within a meeting.
public struct SpeakerLabelAllocator {
    private var mapping: [String: String] = [:]
    private var nextIndex = 1

    public init() {}

    /// The stable `remote_N` for an engine cluster id, allocating the next number
    /// on first sight and returning the same label for every later lookup.
    public mutating func label(forEngineCluster clusterId: String) -> String {
        if let existing = mapping[clusterId] { return existing }
        let label = "remote_\(nextIndex)"
        nextIndex += 1
        mapping[clusterId] = label
        return label
    }

    /// The label already assigned to a cluster, or `nil` if it hasn't been seen.
    ///
    /// A pure read — never consumes a number.
    public func existingLabel(forEngineCluster clusterId: String) -> String? {
        mapping[clusterId]
    }
}
