import XCTest
@testable import NewsBar

final class TimelineDateParserTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
    }

    private func key(_ date: Date) -> String {
        TimelineDateParser.dayKey(date, calendar: calendar)
    }

    func testChineseFullDate() throws {
        let parsed = try XCTUnwrap(TimelineDateParser.parse("2026年8月3日 12:30", now: now, calendar: calendar))
        XCTAssertEqual(key(parsed.date), "2026-08-03")
        XCTAssertEqual(parsed.precision, .day)

        let slashed = try XCTUnwrap(TimelineDateParser.parse("2026/8/5", now: now, calendar: calendar))
        XCTAssertEqual(key(slashed.date), "2026-08-05")
    }

    func testMonthOnlyAndMissingYear() throws {
        let monthOnly = try XCTUnwrap(TimelineDateParser.parse("2026年8月", now: now, calendar: calendar))
        XCTAssertEqual(key(monthOnly.date), "2026-08-01")
        XCTAssertEqual(monthOnly.precision, .month)

        let past = try XCTUnwrap(TimelineDateParser.parse("1月5日", now: now, calendar: calendar))
        XCTAssertEqual(key(past.date), "2026-01-05")

        // A month/day later than "now" belongs to last year, not the future.
        let future = try XCTUnwrap(TimelineDateParser.parse("12月31日", now: now, calendar: calendar))
        XCTAssertEqual(key(future.date), "2025-12-31")
    }

    func testEnglishDates() throws {
        let long = try XCTUnwrap(TimelineDateParser.parse("October 20, 2026", now: now, calendar: calendar))
        XCTAssertEqual(key(long.date), "2026-10-20")
        XCTAssertEqual(long.precision, .day)

        let dayFirst = try XCTUnwrap(TimelineDateParser.parse("3 Oct 2026", now: now, calendar: calendar))
        XCTAssertEqual(key(dayFirst.date), "2026-10-03")

        let monthOnly = try XCTUnwrap(TimelineDateParser.parse("Oct 2026", now: now, calendar: calendar))
        XCTAssertEqual(key(monthOnly.date), "2026-10-01")
        XCTAssertEqual(monthOnly.precision, .month)
    }

    func testRelativeDates() throws {
        let today = try XCTUnwrap(TimelineDateParser.parse("今天", now: now, calendar: calendar))
        XCTAssertEqual(today.precision, .relative)

        let threeDays = try XCTUnwrap(TimelineDateParser.parse("3天前", now: now, calendar: calendar))
        XCTAssertEqual(key(threeDays.date), "2026-10-24")

        let yesterday = try XCTUnwrap(TimelineDateParser.parse("yesterday", now: now, calendar: calendar))
        XCTAssertEqual(key(yesterday.date), "2026-10-26")

        let english = try XCTUnwrap(TimelineDateParser.parse("5 days ago", now: now, calendar: calendar))
        XCTAssertEqual(key(english.date), "2026-10-22")
    }

    func testISO8601() throws {
        let parsed = try XCTUnwrap(
            TimelineDateParser.parse("2026-10-01T08:30:00Z", now: now, calendar: calendar)
        )
        XCTAssertEqual(parsed.date.timeIntervalSince1970, 1_790_843_400, accuracy: 1)
    }

    func testInvalidInputReturnsNil() {
        XCTAssertNil(TimelineDateParser.parse("", now: now, calendar: calendar))
        XCTAssertNil(TimelineDateParser.parse("某天", now: now, calendar: calendar))
        XCTAssertNil(TimelineDateParser.parse("2026-13-40", now: now, calendar: calendar))
        XCTAssertNil(TimelineDateParser.parse("2026-02-30", now: now, calendar: calendar))
    }
}
