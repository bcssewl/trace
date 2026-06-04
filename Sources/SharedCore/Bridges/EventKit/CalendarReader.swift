import EventKit
import Foundation

public struct CalendarEvent: Sendable, Hashable, Identifiable {
    public enum Availability: Sendable, Hashable { case busy, free, tentative, unavailable }
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let attendees: [String]
    public let availability: Availability
    public let isDeclined: Bool

    public init(
        id: String, title: String, startDate: Date, endDate: Date,
        attendees: [String] = [], availability: Availability = .busy,
        isDeclined: Bool = false
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.attendees = attendees
        self.availability = availability
        self.isDeclined = isDeclined
    }
}

extension CalendarEvent {
    public static func fixture(
        title: String, startOffset: TimeInterval,
        endOffset: TimeInterval = 1800,
        attendees: [String] = [],
        availability: Availability = .busy,
        isDeclined: Bool = false,
        base: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> CalendarEvent {
        CalendarEvent(
            id: UUID().uuidString, title: title,
            startDate: base.addingTimeInterval(startOffset),
            endDate: base.addingTimeInterval(endOffset),
            attendees: attendees, availability: availability,
            isDeclined: isDeclined)
    }
}

public protocol CalendarReadingClient: Sendable {
    func events(from: Date, to: Date) async throws -> [CalendarEvent]
}

public actor CalendarReader {
    private let client: any CalendarReadingClient

    public init(client: any CalendarReadingClient = EventKitCalendarClient()) {
        self.client = client
    }

    public func bestEvent(near date: Date, attendeesHint: [String] = []) async throws -> CalendarEvent? {
        let start = date.addingTimeInterval(-15 * 60)
        let end = date.addingTimeInterval(15 * 60)
        let hint = Set(attendeesHint.map { $0.lowercased() })

        let candidates = try await client.events(from: start, to: end)
            .filter { event in
                !event.isDeclined && event.availability != .free && !event.title.localizedCaseInsensitiveContains("ooo")
                    && !event.title.localizedCaseInsensitiveContains("focus")
            }

        return candidates.max { lhs, rhs in
            score(lhs, near: date, hint: hint) < score(rhs, near: date, hint: hint)
        }
    }

    private func score(_ event: CalendarEvent, near date: Date, hint: Set<String>) -> Double {
        let distance = abs(event.startDate.timeIntervalSince(date))
        let closeness = max(0, 900 - distance) / 900
        let attendees = Set(event.attendees.map { $0.lowercased() })
        let overlap = hint.isEmpty ? 0 : Double(attendees.intersection(hint).count)
        return closeness + overlap
    }
}

public struct EventKitCalendarClient: CalendarReadingClient {
    public init() {}

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                attendees: event.attendees?.compactMap { participant -> String? in
                    let str = participant.url.absoluteString
                    if str.lowercased().hasPrefix("mailto:") {
                        return String(str.dropFirst("mailto:".count))
                    }
                    return str.isEmpty ? nil : str
                } ?? [],
                availability: CalendarEvent.Availability(event.availability),
                isDeclined: event.status == .canceled
            )
        }
    }
}

extension CalendarEvent.Availability {
    fileprivate init(_ availability: EKEventAvailability) {
        switch availability {
        case .free: self = .free
        case .tentative: self = .tentative
        case .unavailable: self = .unavailable
        case .busy, .notSupported: self = .busy
        @unknown default: self = .busy
        }
    }
}
