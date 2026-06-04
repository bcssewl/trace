import XCTest

@testable import SharedCore

/// Tests for ``MeetingCalendarResolver``.
///
/// ``CalendarEvent`` has a public initializer (and a `.fixture(...)` helper), so
/// the pure `bestMatch` / `calendarText` members are tested directly against the
/// real value type — no surrogate struct is needed. `resolveCurrentEvent`
/// delegates to the live ``CalendarReader`` actor, which depends on EventKit and
/// is exercised separately in `BridgesCalendarReaderTests`; here we cover the
/// deterministic, EventKit-free logic.
final class MeetingCalendarResolverTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - bestMatch

    func testBestMatchPrefersEventContainingNow() {
        let now = base
        let earlier = CalendarEvent.fixture(title: "Earlier", startOffset: -3600, endOffset: -1800, base: base)
        let containing = CalendarEvent.fixture(title: "Containing", startOffset: -300, endOffset: 900, base: base)
        let later = CalendarEvent.fixture(title: "Later", startOffset: 1800, endOffset: 3600, base: base)

        let match = MeetingCalendarResolver.bestMatch(among: [earlier, containing, later], now: now)

        XCTAssertEqual(match?.title, "Containing")
    }

    func testBestMatchFallsBackToNearestStartWhenNoneContainNow() {
        let now = base
        // None contain `now`; "Soon" starts +120s (nearest), "Early" started -3600s.
        let early = CalendarEvent.fixture(title: "Early", startOffset: -3600, endOffset: -1800, base: base)
        let soon = CalendarEvent.fixture(title: "Soon", startOffset: 120, endOffset: 1800, base: base)
        let late = CalendarEvent.fixture(title: "Late", startOffset: 600, endOffset: 2400, base: base)

        let match = MeetingCalendarResolver.bestMatch(among: [early, soon, late], now: now)

        XCTAssertEqual(match?.title, "Soon")
    }

    func testBestMatchPrefersMostRecentlyStartedAmongOverlapping() {
        let now = base
        let longRunning = CalendarEvent.fixture(title: "Long", startOffset: -1800, endOffset: 1800, base: base)
        let justStarted = CalendarEvent.fixture(title: "JustStarted", startOffset: -60, endOffset: 1800, base: base)

        let match = MeetingCalendarResolver.bestMatch(among: [longRunning, justStarted], now: now)

        XCTAssertEqual(match?.title, "JustStarted")
    }

    func testBestMatchSkipsDeclinedAndFreeAndOooAndFocus() {
        let now = base
        let declined = CalendarEvent.fixture(
            title: "Declined", startOffset: -60, endOffset: 900, isDeclined: true, base: base)
        let free = CalendarEvent.fixture(
            title: "Free Block", startOffset: -60, endOffset: 900, availability: .free, base: base)
        let ooo = CalendarEvent.fixture(title: "OOO", startOffset: -60, endOffset: 900, base: base)
        let focus = CalendarEvent.fixture(title: "Focus Time", startOffset: -60, endOffset: 900, base: base)
        let real = CalendarEvent.fixture(title: "Real Meeting", startOffset: -60, endOffset: 900, base: base)

        let match = MeetingCalendarResolver.bestMatch(among: [declined, free, ooo, focus, real], now: now)

        XCTAssertEqual(match?.title, "Real Meeting")
    }

    func testBestMatchReturnsNilWhenEmpty() {
        XCTAssertNil(MeetingCalendarResolver.bestMatch(among: [], now: base))
    }

    func testBestMatchReturnsNilWhenAllFiltered() {
        let onlyFree = CalendarEvent.fixture(
            title: "Free", startOffset: -60, endOffset: 900, availability: .free, base: base)
        XCTAssertNil(MeetingCalendarResolver.bestMatch(among: [onlyFree], now: base))
    }

    // MARK: - calendarText

    func testCalendarTextFormatsTitleTimeAndAttendees() {
        // base = 1_700_000_000 → 2023-11-14 22:13:20 UTC.
        let event = CalendarEvent.fixture(
            title: "Quarterly Sync",
            startOffset: 0,
            endOffset: 1800,
            attendees: ["sarah@example.com", "alex@example.com"],
            base: base
        )

        let text = MeetingCalendarResolver.calendarText(for: event)

        XCTAssertEqual(
            text,
            """
            Title: Quarterly Sync
            Time: 2023-11-14 22:13–22:43 UTC
            Attendees: sarah@example.com, alex@example.com
            """
        )
    }

    func testCalendarTextOmitsAttendeesLineWhenNone() {
        let event = CalendarEvent.fixture(title: "Solo", startOffset: 0, endOffset: 1800, base: base)
        let text = MeetingCalendarResolver.calendarText(for: event)

        XCTAssertFalse(text.contains("Attendees:"))
        XCTAssertTrue(text.hasPrefix("Title: Solo"))
    }

    func testCalendarTextUsesUntitledPlaceholderForBlankTitle() {
        let event = CalendarEvent.fixture(title: "   ", startOffset: 0, endOffset: 1800, base: base)
        let text = MeetingCalendarResolver.calendarText(for: event)

        XCTAssertTrue(text.hasPrefix("Title: (untitled)"))
    }

    func testCalendarTextIsDeterministic() {
        let event = CalendarEvent.fixture(
            title: "Repeatable",
            startOffset: 0,
            endOffset: 1800,
            attendees: ["a@example.com"],
            base: base
        )
        XCTAssertEqual(
            MeetingCalendarResolver.calendarText(for: event),
            MeetingCalendarResolver.calendarText(for: event)
        )
    }
}
