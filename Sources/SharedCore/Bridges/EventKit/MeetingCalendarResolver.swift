import Foundation

/// Resolves the `CalendarEvent` a meeting most likely belongs to (within a
/// symmetric window around "now") and formats it as plain, untrusted calendar
/// text for the augmented-notes merge.
///
/// This builds on the real ``CalendarReader`` / ``CalendarReadingClient``
/// EventKit bridge (`Sources/SharedCore/Bridges/EventKit/CalendarReader.swift`)
/// and the value type it returns, ``CalendarEvent``. The calendar text produced
/// here is treated as *untrusted input* by the summarizer: it is plain text with
/// no instructions, only the event's title, time, and attendees.
public struct MeetingCalendarResolver: Sendable {
    private let reader: CalendarReader

    public init(reader: CalendarReader) {
        self.reader = reader
    }

    /// Best meeting event within `[now - windowMinutes, now + windowMinutes]`,
    /// or `nil` if nothing plausible is found.
    ///
    /// Selection is delegated to the real ``CalendarReader``, which fetches
    /// events in a ±15-minute window around `now` and applies the same
    /// declined / free / out-of-office / focus filtering used by ``bestMatch``.
    ///
    /// - Note: ``CalendarReader/bestEvent(near:attendeesHint:)`` fixes the fetch
    ///   window at ±15 minutes. `windowMinutes` is honoured by post-filtering the
    ///   reader's result to within the requested window; the default (15) matches
    ///   the reader exactly so no candidate is dropped.
    public func resolveCurrentEvent(now: Date, windowMinutes: Int = 15) async -> CalendarEvent? {
        let window = TimeInterval(max(0, windowMinutes) * 60)
        do {
            guard let event = try await reader.bestEvent(near: now) else { return nil }
            // Keep results that overlap or start within the requested window.
            let startsWithinWindow = abs(event.startDate.timeIntervalSince(now)) <= window
            let overlapsNow =
                event.startDate <= now.addingTimeInterval(window)
                && event.endDate >= now.addingTimeInterval(-window)
            guard startsWithinWindow || overlapsNow else { return nil }
            return event
        } catch {
            Loggers.bridges.error(
                "MeetingCalendarResolver event fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Pure, testable best-match selection.
    ///
    /// Skips declined events, events marked free, and out-of-office / focus
    /// blocks. Prefers an event whose `[startDate, endDate]` interval contains
    /// `now`; if several do, the one with the latest start (most recently begun)
    /// wins. If none contain `now`, the event whose `startDate` is nearest to
    /// `now` is returned. Returns `nil` for an empty / fully-filtered input.
    public static func bestMatch(among events: [CalendarEvent], now: Date) -> CalendarEvent? {
        let usable = events.filter { isUsable($0) }
        guard !usable.isEmpty else { return nil }

        let containing = usable.filter { contains(now, $0) }
        if !containing.isEmpty {
            // Most recently started ongoing event is the strongest "current" signal.
            return containing.max { lhs, rhs in lhs.startDate < rhs.startDate }
        }

        return usable.min { lhs, rhs in
            distance(of: lhs, to: now) < distance(of: rhs, to: now)
        }
    }

    /// Format an event as plain untrusted calendar text (title, time, attendees)
    /// for the merge.
    ///
    /// Deterministic for a given event and `formatter` settings:
    /// the time range uses UTC so the output is stable across machines, and
    /// attendees preserve their source order.
    public static func calendarText(for event: CalendarEvent) -> String {
        var lines: [String] = []

        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Title: \(title.isEmpty ? "(untitled)" : title)")
        lines.append("Time: \(timeRange(event))")

        if !event.attendees.isEmpty {
            lines.append("Attendees: \(event.attendees.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Selection helpers

    private static func isUsable(_ event: CalendarEvent) -> Bool {
        guard !event.isDeclined else { return false }
        guard event.availability != .free else { return false }
        let title = event.title
        if title.localizedCaseInsensitiveContains("ooo") { return false }
        if title.localizedCaseInsensitiveContains("focus") { return false }
        return true
    }

    private static func contains(_ now: Date, _ event: CalendarEvent) -> Bool {
        // Inclusive of the start, exclusive of the end so a back-to-back event
        // boundary attributes `now` to the one that has just begun.
        event.startDate <= now && now < event.endDate
    }

    private static func distance(of event: CalendarEvent, to now: Date) -> TimeInterval {
        abs(event.startDate.timeIntervalSince(now))
    }

    // MARK: - Formatting helpers

    private static func timeRange(_ event: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let start = formatter.string(from: event.startDate)

        let endFormatter = DateFormatter()
        endFormatter.locale = Locale(identifier: "en_US_POSIX")
        endFormatter.timeZone = TimeZone(identifier: "UTC")
        endFormatter.dateFormat = "HH:mm"
        let end = endFormatter.string(from: event.endDate)

        return "\(start)–\(end) UTC"
    }
}
