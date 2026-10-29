import Foundation

/// Local, conservative request guards per provider. Vendor limits change and
/// the keyless tiers do not publish their caps, so these are deliberately
/// lower than the documented ceilings: they exist to stop a research pass from
/// burning a free allowance before the provider has to answer 429.
struct SearchRateLimit: Sendable, Equatable {
    var perMinute: Int?
    var perHour: Int?
    var perDay: Int?
    var perMonth: Int?

    /// The window that governs a `402` (allowance exhausted) block. Daily
    /// allowances reset at midnight UTC; credit allowances reset monthly.
    func resetDate(after date: Date, calendar: Calendar) -> Date {
        if perDay != nil, perMonth == nil {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
                ?? date.addingTimeInterval(24 * 3600)
        }
        let components = calendar.dateComponents([.year, .month], from: date)
        let monthStart = calendar.date(from: components) ?? date
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
            ?? date.addingTimeInterval(30 * 24 * 3600)
    }
}

enum SearchRateLimits {
    /// `keyed` means the request will carry a credential, which selects the
    /// provider's larger allowance.
    static func limit(for provider: SearchProviderID, keyed: Bool) -> SearchRateLimit {
        switch provider {
        case .firecrawl:
            // Free plan: 10 /search per minute. Keyless is capped per IP per
            // day by request count and credits; the exact numbers are not
            // published, so the local guard stays well below a plausible cap.
            return keyed
                ? SearchRateLimit(perMinute: 10, perDay: 30, perMonth: 1_000)
                : SearchRateLimit(perMinute: 6, perDay: 40)
        case .tavily:
            // Free: 1,000 credits / month. Keyless allowance is unpublished.
            return keyed
                ? SearchRateLimit(perMinute: 60, perMonth: 1_000)
                : SearchRateLimit(perMinute: 20, perDay: 100)
        case .tinyfish:
            // Free: 30 requests / minute, 500 / hour (12,000 / day).
            return SearchRateLimit(perMinute: 30, perHour: 500, perDay: 1_000)
        case .exa:
            // Starter: $10 credits / month, 10 QPS.
            return SearchRateLimit(perMinute: 30, perMonth: 500)
        case .parallel:
            // Free: 5,000 requests / month, 600 / minute.
            return SearchRateLimit(perMinute: 60, perMonth: 5_000)
        case .brave:
            return SearchRateLimit(perMinute: 30, perMonth: 2_000)
        }
    }

}

/// Settings-facing usage. Counts are local dispatches, not vendor-reported
/// usage, so they can be lower than the provider's dashboard.
struct SearchQuotaSnapshot: Sendable, Equatable {
    var usedToday: Int
    var dailyLimit: Int?
    var usedThisMonth: Int
    var monthlyLimit: Int?
}

/// Persisted per-provider request counters. This is a guardrail, not billing:
/// it never stores queries, keys or responses, and a corrupt file resets the
/// counters rather than bricking search.
actor SearchQuotaStore {
    private struct Window: Codable, Sendable, Equatable {
        var minuteStart: Date
        var minuteCount: Int
        var hourStart: Date
        var hourCount: Int
        var dayStart: Date
        var dayCount: Int
        var monthStart: Date
        var monthCount: Int

        static func empty(at date: Date, calendar: Calendar) -> Window {
            Window(
                minuteStart: Self.minuteStart(date),
                minuteCount: 0,
                hourStart: Self.hourStart(date),
                hourCount: 0,
                dayStart: calendar.startOfDay(for: date),
                dayCount: 0,
                monthStart: Self.monthStart(date, calendar: calendar),
                monthCount: 0
            )
        }

        mutating func roll(to date: Date, calendar: Calendar) {
            let minute = Self.minuteStart(date)
            if minute != minuteStart {
                minuteStart = minute
                minuteCount = 0
            }
            let hour = Self.hourStart(date)
            if hour != hourStart {
                hourStart = hour
                hourCount = 0
            }
            let day = calendar.startOfDay(for: date)
            if day != dayStart {
                dayStart = day
                dayCount = 0
            }
            let month = Self.monthStart(date, calendar: calendar)
            if month != monthStart {
                monthStart = month
                monthCount = 0
            }
        }

        private static func minuteStart(_ date: Date) -> Date {
            Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        }

        private static func hourStart(_ date: Date) -> Date {
            Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        }

        private static func monthStart(_ date: Date, calendar: Calendar) -> Date {
            var components = calendar.dateComponents([.year, .month], from: date)
            components.day = 1
            components.hour = 0
            components.minute = 0
            components.second = 0
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        }
    }

    private struct FileState: Codable {
        var version: Int
        var providers: [String: Window]
    }

    // v1 was only produced by pre-release builds whose counters could be
    // inflated by test fixtures; v2 starts counting from zero so a stale file
    // cannot park a provider for a month.
    private static let currentVersion = 2

    /// One shared store for the app so two routers cannot double-spend the
    /// same local allowance. Tests inject their own or pass nil.
    static let shared = SearchQuotaStore()

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var windows: [SearchProviderID: Window] = [:]
    private var loaded = false

    init(
        fileURL: URL? = ResearchPaths.searchQuotaFile,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar? = nil
    ) {
        self.fileURL = fileURL
        self.now = now
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        self.calendar = calendar ?? utc
    }

    /// `false` means a local window is already full; nothing should be sent.
    func consume(for provider: SearchProviderID, keyed: Bool) -> Bool {
        let date = now()
        loadIfNeeded()
        var window = windows[provider] ?? .empty(at: date, calendar: calendar)
        window.roll(to: date, calendar: calendar)
        let limit = SearchRateLimits.limit(for: provider, keyed: keyed)
        if let perMinute = limit.perMinute, window.minuteCount >= perMinute { return false }
        if let perHour = limit.perHour, window.hourCount >= perHour { return false }
        if let perDay = limit.perDay, window.dayCount >= perDay { return false }
        if let perMonth = limit.perMonth, window.monthCount >= perMonth { return false }
        window.minuteCount += 1
        window.hourCount += 1
        window.dayCount += 1
        window.monthCount += 1
        windows[provider] = window
        persist()
        return true
    }

    func snapshot(
        for provider: SearchProviderID,
        keyed: Bool,
        at date: Date? = nil
    ) -> SearchQuotaSnapshot {
        let current = date ?? now()
        loadIfNeeded()
        var window = windows[provider] ?? .empty(at: current, calendar: calendar)
        window.roll(to: current, calendar: calendar)
        let limit = SearchRateLimits.limit(for: provider, keyed: keyed)
        return SearchQuotaSnapshot(
            usedToday: window.dayCount,
            dailyLimit: limit.perDay,
            usedThisMonth: window.monthCount,
            monthlyLimit: limit.perMonth
        )
    }

    /// Used when a `402` proves the vendor allowance is gone. The local
    /// counters jump to the limit so the provider is skipped until the window
    /// rolls over, even if the vendor's counter and ours disagree.
    func exhaust(for provider: SearchProviderID, keyed: Bool) {
        let date = now()
        loadIfNeeded()
        var window = windows[provider] ?? .empty(at: date, calendar: calendar)
        window.roll(to: date, calendar: calendar)
        let limit = SearchRateLimits.limit(for: provider, keyed: keyed)
        if let perDay = limit.perDay { window.dayCount = max(window.dayCount, perDay) }
        if let perMonth = limit.perMonth { window.monthCount = max(window.monthCount, perMonth) }
        if let perHour = limit.perHour { window.hourCount = max(window.hourCount, perHour) }
        if let perMinute = limit.perMinute { window.minuteCount = max(window.minuteCount, perMinute) }
        windows[provider] = window
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(FileState.self, from: data),
              state.version == Self.currentVersion else {
            return
        }
        windows = Dictionary(
            uniqueKeysWithValues: state.providers.compactMap { raw, window in
                guard let provider = SearchProviderID(rawValue: raw) else { return nil }
                return (provider, window)
            }
        )
    }

    private func persist() {
        guard let fileURL else { return }
        let state = FileState(
            version: Self.currentVersion,
            providers: Dictionary(uniqueKeysWithValues: windows.map { ($0.key.rawValue, $0.value) })
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        // Quota counters are a guardrail; a failed write must not fail a search.
        try? PrivateFile.write(data, to: fileURL, durable: false)
    }
}
