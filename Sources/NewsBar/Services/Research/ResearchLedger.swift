import Foundation
import os

enum LedgerKind: String, Codable, Sendable, CaseIterable {
    case ai, search, task
}

struct LedgerCounts: Codable, Hashable, Sendable, Equatable {
    var burst = 0
    var keyword = 0
    var manual = 0

    subscript(origin: ResearchOrigin) -> Int {
        get {
            switch origin {
            case .burst: return burst
            case .keyword: return keyword
            case .manual: return manual
            }
        }
        set {
            switch origin {
            case .burst: burst = newValue
            case .keyword: keyword = newValue
            case .manual: manual = newValue
            }
        }
    }

    var total: Int { burst + keyword + manual }

    mutating func increment(_ origin: ResearchOrigin) {
        self[origin] += 1
    }
}

struct LedgerSnapshot: Sendable, Equatable {
    let day: Int
    let ai: LedgerCounts
    let search: LedgerCounts
    let tasks: LedgerCounts
    let isCorrupt: Bool

    static let empty = LedgerSnapshot(
        day: 0, ai: LedgerCounts(), search: LedgerCounts(), tasks: LedgerCounts(), isCorrupt: false
    )

    var totalAI: Int { ai.total }
    var totalSearch: Int { search.total }
    var totalTasks: Int { tasks.total }
}

/// One shared AI ledger with three origin columns. Reserve before dispatch and
/// never refund a possibly-sent request. A corrupt ledger fails closed: every
/// reservation is refused until the user explicitly resets today's usage.
final class ResearchLedger: Sendable {
    static let shared = ResearchLedger()
    private struct Record: Codable, Sendable {
        var day: Int
        var ai = LedgerCounts()
        var search = LedgerCounts()
        var tasks = LedgerCounts()

        var isValid: Bool {
            day >= 0 && ai.burst >= 0 && ai.keyword >= 0 && ai.manual >= 0
                && search.burst >= 0 && search.keyword >= 0 && search.manual >= 0
                && tasks.burst >= 0 && tasks.keyword >= 0 && tasks.manual >= 0
        }
    }

    private struct State: Sendable {
        var record: Record?
        var corrupt = false
    }

    private let fileURL: URL
    private let calendar: Calendar
    private let lock: OSAllocatedUnfairLock<State>

    init(fileURL: URL = ResearchPaths.ledgerFile, calendar: Calendar? = nil) {
        self.fileURL = fileURL
        self.calendar = calendar ?? Self.defaultCalendar

        var state = State()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL),
               let record = try? JSONDecoder().decode(Record.self, from: data),
               record.isValid {
                state.record = record
            } else {
                state.corrupt = true
            }
        }
        lock = OSAllocatedUnfairLock(initialState: state)
    }

    /// Search calls are counted but not capped by the daily ledger; each task's
    /// own HTTP hard limit is enforced by the pipeline. AI and task reservations
    /// respect the shared daily cap.
    func reserve(
        _ kind: LedgerKind,
        origin: ResearchOrigin,
        cap: Int,
        at date: Date = Date()
    ) -> Bool {
        lock.withLock { state in
            guard !state.corrupt else { return false }
            let today = Self.dayKey(for: date, calendar: calendar)
            var record = state.record?.day == today ? state.record! : Record(day: today)

            switch kind {
            case .ai:
                guard cap > 0, record.ai.total < cap else { return false }
                record.ai.increment(origin)
            case .task:
                guard cap > 0, record.tasks.total < cap else { return false }
                record.tasks.increment(origin)
            case .search:
                record.search.increment(origin)
            }

            do {
                try write(record)
                state.record = record
                return true
            } catch {
                state.corrupt = true
                return false
            }
        }
    }

    /// One-time carry-over of the legacy burst-research counter into today's
    /// `ai.burst` column. No-op when today already has burst usage, so a partial
    /// migration retried on the next launch cannot double count.
    @discardableResult
    func seedLegacyBurstCalls(_ count: Int, at date: Date = Date()) -> Bool {
        guard count > 0 else { return true }
        return lock.withLock { state in
            guard !state.corrupt else { return false }
            let today = Self.dayKey(for: date, calendar: calendar)
            var record = state.record?.day == today ? state.record! : Record(day: today)
            guard record.ai.burst == 0 else { return true }
            record.ai.burst = count
            do {
                try write(record)
                state.record = record
                return true
            } catch {
                state.corrupt = true
                return false
            }
        }
    }

    /// Search attempts are counted in one write per task/query. They are never
    /// capped by the daily ledger; the per-task HTTP ceiling lives in the pipeline.
    @discardableResult
    func recordSearchCalls(
        _ count: Int,
        origin: ResearchOrigin,
        at date: Date = Date()
    ) -> Bool {
        guard count > 0 else { return true }
        return lock.withLock { state in
            guard !state.corrupt else { return false }
            let today = Self.dayKey(for: date, calendar: calendar)
            var record = state.record?.day == today ? state.record! : Record(day: today)
            record.search[origin] += count
            do {
                try write(record)
                state.record = record
                return true
            } catch {
                state.corrupt = true
                return false
            }
        }
    }

    func snapshot(at date: Date = Date()) -> LedgerSnapshot {
        lock.withLock { state in
            let today = Self.dayKey(for: date, calendar: calendar)
            guard !state.corrupt else {
                return LedgerSnapshot(
                    day: today,
                    ai: LedgerCounts(),
                    search: LedgerCounts(),
                    tasks: LedgerCounts(),
                    isCorrupt: true
                )
            }
            guard let record = state.record, record.day == today else {
                return LedgerSnapshot(
                    day: today,
                    ai: LedgerCounts(),
                    search: LedgerCounts(),
                    tasks: LedgerCounts(),
                    isCorrupt: false
                )
            }
            return LedgerSnapshot(
                day: record.day,
                ai: record.ai,
                search: record.search,
                tasks: record.tasks,
                isCorrupt: false
            )
        }
    }

    func used(_ kind: LedgerKind, at date: Date = Date()) -> Int {
        let snapshot = snapshot(at: date)
        guard !snapshot.isCorrupt else { return Int.max }
        switch kind {
        case .ai: return snapshot.totalAI
        case .search: return snapshot.totalSearch
        case .task: return snapshot.totalTasks
        }
    }

    /// Explicit recovery path for a corrupt ledger. Only this clears the
    /// fail-closed state; a normal reservation never self-heals.
    @discardableResult
    func resetToday(at date: Date = Date()) -> Bool {
        lock.withLock { state in
            let record = Record(day: Self.dayKey(for: date, calendar: calendar))
            do {
                try write(record)
                state.record = record
                state.corrupt = false
                return true
            } catch {
                state.corrupt = true
                return false
            }
        }
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10_000 + (components.month ?? 0) * 100 + (components.day ?? 0)
    }

    /// Day keys are Gregorian `YYYYMMDD` in the user's timezone, independent of
    /// a system calendar preference (Buddhist, Japanese, etc.).
    private static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func write(_ record: Record) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
