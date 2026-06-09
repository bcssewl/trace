import Foundation

/// One persisted dictation cycle.
///
/// Maps 1:1 to a row in the `dictations` table (schema v4 + the v34
/// `recovered` column). The id is a `session_yyyy-MM-dd_HH-mm-ss` string
/// written by `DictationHistoryStore`.
public struct DictationRecord: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let projectID: UUID?
    public let modeName: String?
    public let bundleID: String?
    public let rawText: String
    public let cleanedText: String
    public let inserted: Bool
    public let durationMs: Int
    public let startedAt: TimeInterval
    /// True when this record was produced by the crash-recovery path — an
    /// orphaned audio spool transcribed after the original session died —
    /// rather than by a live dictation cycle.
    public let recovered: Bool

    public init(
        id: String,
        projectID: UUID?,
        modeName: String?,
        bundleID: String?,
        rawText: String,
        cleanedText: String,
        inserted: Bool,
        durationMs: Int,
        startedAt: TimeInterval,
        recovered: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.modeName = modeName
        self.bundleID = bundleID
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.inserted = inserted
        self.durationMs = durationMs
        self.startedAt = startedAt
        self.recovered = recovered
    }

    /// Custom decode so JSON encoded before the `recovered` field existed
    /// still round-trips (absent → false).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        self.modeName = try container.decodeIfPresent(String.self, forKey: .modeName)
        self.bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        self.rawText = try container.decode(String.self, forKey: .rawText)
        self.cleanedText = try container.decode(String.self, forKey: .cleanedText)
        self.inserted = try container.decode(Bool.self, forKey: .inserted)
        self.durationMs = try container.decode(Int.self, forKey: .durationMs)
        self.startedAt = try container.decode(TimeInterval.self, forKey: .startedAt)
        self.recovered = try container.decodeIfPresent(Bool.self, forKey: .recovered) ?? false
    }

    /// Generates a fresh id from the current time using the meeting / session
    /// naming convention.
    public static func newID(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let uniq = String(UUID().uuidString.prefix(4))
        return "dictation_\(formatter.string(from: date))_\(uniq)"
    }
}
