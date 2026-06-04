import Foundation

/// One persisted dictation cycle.
///
/// Maps 1:1 to a row in the `dictations` table (schema v4). The id is a
/// `session_yyyy-MM-dd_HH-mm-ss` string written by `DictationHistoryStore`.
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

    public init(
        id: String,
        projectID: UUID?,
        modeName: String?,
        bundleID: String?,
        rawText: String,
        cleanedText: String,
        inserted: Bool,
        durationMs: Int,
        startedAt: TimeInterval
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
