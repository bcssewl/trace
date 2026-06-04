import Foundation

public struct CalendarEventLike: Sendable, Hashable {
    public let title: String
    public let attendees: [String]
    public let isRecurring: Bool

    public init(title: String, attendees: [String], isRecurring: Bool) {
        self.title = title
        self.attendees = attendees
        self.isRecurring = isRecurring
    }
}

public enum CalendarMatcher: Sendable, Hashable, Codable {
    case titleRegex(String)
    case attendeeDomain(String)
    case recurringSeries

    public func matches(_ event: CalendarEventLike) throws -> Bool {
        switch self {
        case .titleRegex(let pattern):
            do {
                let r = try NSRegularExpression(pattern: pattern, options: [])
                let range = NSRange(event.title.startIndex..., in: event.title)
                return r.firstMatch(in: event.title, options: [], range: range) != nil
            } catch {
                throw TraceError.configInvalid(
                    field: "calendarMatcher.titleRegex",
                    reason: "invalid regex '\(pattern)': \(error.localizedDescription)"
                )
            }
        case .attendeeDomain(let domain):
            let needle = "@" + domain.lowercased()
            return event.attendees.contains { $0.lowercased().hasSuffix(needle) }
        case .recurringSeries:
            return event.isRecurring
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case titleRegex, attendeeDomain, recurringSeries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .titleRegex: self = .titleRegex(try c.decode(String.self, forKey: .value))
        case .attendeeDomain: self = .attendeeDomain(try c.decode(String.self, forKey: .value))
        case .recurringSeries: self = .recurringSeries
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .titleRegex(let p):
            try c.encode(Kind.titleRegex, forKey: .kind)
            try c.encode(p, forKey: .value)
        case .attendeeDomain(let d):
            try c.encode(Kind.attendeeDomain, forKey: .kind)
            try c.encode(d, forKey: .value)
        case .recurringSeries:
            try c.encode(Kind.recurringSeries, forKey: .kind)
        }
    }
}
