import XCTest

@testable import SharedCore

final class BridgesCalendarReaderTests: XCTestCase {
    func testAutoAttachUsesPlusMinusFifteenMinutesAndSkipsBlockedEvents() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = StubCalendarClient(
            events: [
                .fixture(title: "Focus Time", startOffset: -60, endOffset: 1800, availability: .busy),
                .fixture(title: "OOO", startOffset: -60, endOffset: 1800, availability: .free),
                .fixture(title: "Customer Call", startOffset: -600, endOffset: 1800, availability: .busy),
                .fixture(title: "Too Late", startOffset: 1200, endOffset: 2400, availability: .busy),
            ], now: now)

        let reader = CalendarReader(client: client)
        let match = try await reader.bestEvent(near: now, attendeesHint: ["sarah@example.com"])

        XCTAssertEqual(match?.title, "Customer Call")
    }

    func testAttendeeOverlapBreaksTie() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = StubCalendarClient(
            events: [
                .fixture(title: "Generic", startOffset: -100, attendees: ["x@example.com"]),
                .fixture(title: "Sarah Sync", startOffset: -100, attendees: ["sarah@example.com"]),
            ], now: now)

        let reader = CalendarReader(client: client)
        let match = try await reader.bestEvent(near: now, attendeesHint: ["sarah@example.com"])

        XCTAssertEqual(match?.title, "Sarah Sync")
    }
}

private struct StubCalendarClient: CalendarReadingClient {
    let events: [CalendarEvent]
    let now: Date
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { events }
}
