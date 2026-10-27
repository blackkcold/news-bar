import Foundation

/// Parses the date labels the model produces into sortable dates. It is
/// deliberately conservative: an unparseable label yields `nil`, and the
/// validator then keeps the node but lowers its confidence.
enum TimelineDateParser {
    struct Parsed: Equatable, Sendable {
        let date: Date
        let precision: DatePrecision
    }

    private static let englishMonths: [String: Int] = [
        "jan": 1, "january": 1,
        "feb": 2, "february": 2,
        "mar": 3, "march": 3,
        "apr": 4, "april": 4,
        "may": 5,
        "jun": 6, "june": 6,
        "jul": 7, "july": 7,
        "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10,
        "nov": 11, "november": 11,
        "dec": 12, "december": 12,
    ]

    static func parse(
        _ raw: String,
        now: Date = Date(),
        calendar: Calendar = defaultCalendar
    ) -> Parsed? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for prefix in ["约", "大约", "大概", "circa ", "~"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }

        if let iso = parseISO8601(text) {
            return Parsed(date: iso, precision: .day)
        }

        if let full = firstMatch(
            #"(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?"#,
            in: text
        ), let year = Int(full[0]), let month = Int(full[1]), let day = Int(full[2]) {
            guard let date = makeDate(year: year, month: month, day: day, calendar: calendar) else {
                // A full date was present but impossible (e.g. 2026-02-30).
                // Do not fall through and reinterpret it as a month.
                return nil
            }
            return Parsed(date: date, precision: .day)
        }

        if let yearMonth = firstMatch(#"(\d{4})\s*[-/.年]\s*(\d{1,2})\s*月?"#, in: text),
           let year = Int(yearMonth[0]), let month = Int(yearMonth[1]) {
            guard let date = makeDate(year: year, month: month, day: 1, calendar: calendar) else {
                return nil
            }
            return Parsed(date: date, precision: .month)
        }

        if let monthDay = firstMatch(#"(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?"#, in: text),
           let month = Int(monthDay[0]), let day = Int(monthDay[1]) {
            let currentYear = calendar.component(.year, from: now)
            if let date = makeDate(year: currentYear, month: month, day: day, calendar: calendar) {
                let adjusted = date > calendar.date(byAdding: .day, value: 1, to: now) ?? date
                    ? calendar.date(byAdding: .year, value: -1, to: date) ?? date
                    : date
                return Parsed(date: adjusted, precision: .day)
            }
        }

        let lowered = text.lowercased()
        if let parsed = parseEnglish(lowered, now: now, calendar: calendar) {
            return parsed
        }
        if let parsed = parseRelative(lowered, now: now, calendar: calendar) {
            return parsed
        }
        return nil
    }

    static func dayKey(_ date: Date, calendar: Calendar = defaultCalendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    // MARK: - English

    private static func parseEnglish(
        _ text: String,
        now: Date,
        calendar: Calendar
    ) -> Parsed? {
        let monthPattern = englishMonths.keys
            .sorted { $0.count > $1.count }
            .joined(separator: "|")

        // October 27, 2026 / Oct 27 2026
        if let parts = firstMatch("(\(monthPattern))\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})", in: text),
           let month = englishMonths[parts[0]], let day = Int(parts[1]), let year = Int(parts[2]),
           let date = makeDate(year: year, month: month, day: day, calendar: calendar) {
            return Parsed(date: date, precision: .day)
        }
        // 27 October 2026
        if let parts = firstMatch("(\\d{1,2})(?:st|nd|rd|th)?\\s+(\(monthPattern))\\.?,?\\s+(\\d{4})", in: text),
           let day = Int(parts[0]), let month = englishMonths[parts[1]], let year = Int(parts[2]),
           let date = makeDate(year: year, month: month, day: day, calendar: calendar) {
            return Parsed(date: date, precision: .day)
        }
        // October 2026
        if let parts = firstMatch("(\(monthPattern))\\.?,?\\s+(\\d{4})", in: text),
           let month = englishMonths[parts[0]], let year = Int(parts[1]),
           let date = makeDate(year: year, month: month, day: 1, calendar: calendar) {
            return Parsed(date: date, precision: .month)
        }
        return nil
    }

    // MARK: - Relative

    private static func parseRelative(
        _ text: String,
        now: Date,
        calendar: Calendar
    ) -> Parsed? {
        if text.contains("今天") || text.contains("今日") || text.contains("刚刚")
            || text.contains("today") || text.contains("just now") || text.contains("this morning") {
            return Parsed(date: now, precision: .relative)
        }
        if text.contains("昨天") || text.contains("昨日") || text.contains("yesterday") {
            return Parsed(date: now.addingTimeInterval(-86_400), precision: .relative)
        }
        if text.contains("前天") {
            return Parsed(date: now.addingTimeInterval(-2 * 86_400), precision: .relative)
        }

        let rules: [(String, TimeInterval)] = [
            (#"(\d+)\s*天前"#, 86_400),
            (#"(\d+)\s*(?:个)?小时前"#, 3_600),
            (#"(\d+)\s*(?:个)?星期前"#, 7 * 86_400),
            (#"(\d+)\s*(?:个)?周前"#, 7 * 86_400),
            (#"(\d+)\s*(?:个)?月前"#, 30 * 86_400),
            (#"(\d+)\s*年前"#, 365 * 86_400),
            (#"(\d+)\s*days?\s+ago"#, 86_400),
            (#"(\d+)\s*hours?\s+ago"#, 3_600),
            (#"(\d+)\s*weeks?\s+ago"#, 7 * 86_400),
            (#"(\d+)\s*months?\s+ago"#, 30 * 86_400),
            (#"(\d+)\s*years?\s+ago"#, 365 * 86_400),
        ]
        for (pattern, unit) in rules {
            if let parts = firstMatch(pattern, in: text), let amount = Double(parts[0]), amount > 0 {
                return Parsed(date: now.addingTimeInterval(-amount * unit), precision: .relative)
            }
        }

        if text.contains("上个月") || text.contains("last month") {
            return Parsed(
                date: calendar.date(byAdding: .month, value: -1, to: now) ?? now,
                precision: .relative
            )
        }
        if text.contains("去年") || text.contains("last year") {
            return Parsed(
                date: calendar.date(byAdding: .year, value: -1, to: now) ?? now,
                precision: .relative
            )
        }
        return nil
    }

    // MARK: - Helpers

    private static func parseISO8601(_ text: String) -> Date? {
        guard text.contains("T") || text.contains(":") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func makeDate(
        year: Int,
        month: Int,
        day: Int,
        calendar: Calendar
    ) -> Date? {
        guard (1990...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return date
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let groupRange = Range(match.range(at: index), in: text) else { return nil }
            groups.append(String(text[groupRange]))
        }
        return groups
    }
}
