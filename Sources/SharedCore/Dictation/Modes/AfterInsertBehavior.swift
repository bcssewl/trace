import Foundation

/// What the dictation HUD does after a successful insert.
///
/// Encoded as a tagged-union JSON value:
///
///     {"kind": "keepOpen"}
///     {"kind": "closeHud"}
///     {"kind": "closeHudAfterDelay", "seconds": 1.5}
public enum AfterInsertBehavior: Sendable, Hashable, Codable {
    /// Leave the HUD visible so the user can immediately start another capture.
    case keepOpen
    /// Hide the HUD immediately after insert.
    case closeHud
    /// Hide the HUD after `seconds` of inactivity.
    case closeHudAfterDelay(seconds: TimeInterval)

    private enum CodingKeys: String, CodingKey {
        case kind
        case seconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "keepOpen":
            self = .keepOpen
        case "closeHud":
            self = .closeHud
        case "closeHudAfterDelay":
            let seconds = try container.decode(TimeInterval.self, forKey: .seconds)
            self = .closeHudAfterDelay(seconds: seconds)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown AfterInsertBehavior kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keepOpen:
            try container.encode("keepOpen", forKey: .kind)
        case .closeHud:
            try container.encode("closeHud", forKey: .kind)
        case .closeHudAfterDelay(let seconds):
            try container.encode("closeHudAfterDelay", forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        }
    }
}
