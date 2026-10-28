import Foundation
import os

/// Counts live research executions across the coordinator. Resetting today's
/// usage while a task is spending it would make the cap meaningless, so the
/// ledger refuses that reset at the execution layer too, not only in the UI.
enum ResearchActivity {
    private static let active = OSAllocatedUnfairLock(initialState: 0)

    static func begin() {
        active.withLock { $0 += 1 }
    }

    static func end() {
        active.withLock { $0 = max(0, $0 - 1) }
    }

    static var isActive: Bool {
        active.withLock { $0 > 0 }
    }
}

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

/// Why the ledger can or cannot be used. `loading` exists so the settings UI
/// never paints a fake "0" before the file has been read.
enum LedgerAvailability: String, Sendable, Equatable {
    case loading
    case available
    case corrupt
    case ioUnavailable
    case unsupportedVersion

    var isUsable: Bool { self == .available }
}

struct LedgerSnapshot: Sendable, Equatable {
    let day: Int
    let ai: LedgerCounts
    let search: LedgerCounts
    let tasks: LedgerCounts
    let availability: LedgerAvailability

    static let empty = LedgerSnapshot(
        day: 0,
        ai: LedgerCounts(),
        search: LedgerCounts(),
        tasks: LedgerCounts(),
        availability: .loading
    )

    /// Kept for existing callers; new code should inspect `availability`.
    var isCorrupt: Bool { availability == .corrupt }

    var totalAI: Int { ai.total }
    var totalSearch: Int { search.total }
    var totalTasks: Int { tasks.total }
}

/// One shared AI ledger with three origin columns. Reserve before dispatch and
/// never refund a possibly-sent request. An unusable ledger fails closed: every
/// reservation is refused until the user explicitly resets today's usage.
final class ResearchLedger: Sendable {
    static let shared = ResearchLedger()
    /// v1 stored only the three daily counters. v2 adds provider cooldowns and
    /// still reads v1 files, upgrading them on the next write.
    static let currentVersion = 2

    private struct Record: Codable, Sendable {
        var version = ResearchLedger.currentVersion
        var day: Int
        var ai = LedgerCounts()
        var search = LedgerCounts()
        var tasks = LedgerCounts()
        /// Provider id → the instant its quota block expires. Survives a
        /// relaunch so a restart cannot immediately re-spend a limited quota.
        var providerCooldowns: [String: Date] = [:]

        var isValid: Bool {
            version == ResearchLedger.currentVersion
                && day >= 0
                && ai.burst >= 0 && ai.keyword >= 0 && ai.manual >= 0
                && search.burst >= 0 && search.keyword >= 0 && search.manual >= 0
                && tasks.burst >= 0 && tasks.keyword >= 0 && tasks.manual >= 0
        }

        enum CodingKeys: String, CodingKey {
            case version, day, ai, search, tasks, providerCooldowns
        }

        init(day: Int) {
            self.day = day
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Files written before the version field are the current version.
            let stored = try container.decodeIfPresent(Int.self, forKey: .version)
                ?? ResearchLedger.currentVersion
            version = stored
            day = try container.decode(Int.self, forKey: .day)
            ai = try container.decode(LedgerCounts.self, forKey: .ai)
            search = try container.decode(LedgerCounts.self, forKey: .search)
            tasks = try container.decode(LedgerCounts.self, forKey: .tasks)
            providerCooldowns = try container.decodeIfPresent(
                [String: Date].self,
                forKey: .providerCooldowns
            ) ?? [:]
            // A readable v1 file is upgraded in memory; the next write states v2.
            if stored < ResearchLedger.currentVersion {
                version = ResearchLedger.currentVersion
            }
        }
    }

    private struct State: Sendable {
        var record: Record?
        var availability: LedgerAvailability = .loading
    }

    private let fileURL: URL
    private let calendar: Calendar
    private let lock: OSAllocatedUnfairLock<State>

    init(fileURL: URL = ResearchPaths.ledgerFile, calendar: Calendar? = nil) {
        self.fileURL = fileURL
        self.calendar = calendar ?? Self.defaultCalendar
        lock = OSAllocatedUnfairLock(initialState: State())
        load()
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
            guard state.availability.isUsable else { return false }
            let today = Self.dayKey(for: date, calendar: calendar)
            var record = Self.rolling(state.record, to: today)

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
                state.availability = .available
                return true
            } catch {
                state.availability = Self.availability(for: error)
                return false
            }
        }
    }

    /// Records a provider quota block. The later of the stored and new instants
    /// wins, so a retried failure can never shorten an existing cooldown.
    @discardableResult
    func recordProviderCooldown(
        _ provider: SearchProviderID,
        until: Date,
        at date: Date = Date()
    ) -> Bool {
        lock.withLock { state in
            guard state.availability.isUsable else { return false }
            let today = Self.dayKey(for: date, calendar: calendar)
            var record = Self.rolling(state.record, to: today)
            record.providerCooldowns = Self.pruned(record.providerCooldowns, at: date)
            let existing = record.providerCooldowns[provider.rawValue]
            if existing.map({ $0 >= until }) != true {
                record.providerCooldowns[provider.rawValue] = until
            }
            do {
                try write(record)
                state.record = record
                state.availability = .available
                return true
            } catch {
                state.availability = Self.availability(for: error)
                return false
            }
        }
    }

    /// `nil` when the provider is free to use. An unreadable ledger is not
    /// treated as a cooldown: search already refuses on its own when unusable.
    func providerCooldown(_ provider: SearchProviderID, at date: Date = Date()) -> Date? {
        lock.withLock { state in
            guard state.availability.isUsable, let record = state.record else { return nil }
            guard let until = record.providerCooldowns[provider.rawValue], until > date else { return nil }
            return until
        }
    }

    /// Day rollover resets counters but must not discard a quota block that is
    /// still in force.
    private static func rolling(_ existing: Record?, to day: Int) -> Record {
        guard let existing else { return Record(day: day) }
        var record = existing.day == day ? existing : Record(day: day)
        record.providerCooldowns = pruned(existing.providerCooldowns, at: Date())
        return record
    }

    private static func pruned(_ cooldowns: [String: Date], at date: Date) -> [String: Date] {
        cooldowns.filter { $0.value > date }
    }

    /// One-time carry-over of the legacy burst-research counter into today's
    /// `ai.burst` column. No-op when today already has burst usage, so a partial
    /// migration retried on the next launch cannot double count.
    @discardableResult
    func seedLegacyBurstCalls(_ count: Int, at date: Date = Date()) -> Bool {
        guard count > 0 else { return true }
        return lock.withLock { state in
            guard state.availability.isUsable else { return false }
            let today = Self.dayKey(for: date, calendar: calendar)
            var record = Self.rolling(state.record, to: today)
            guard record.ai.burst == 0 else { return true }
            record.ai.burst = count
            do {
                try write(record)
                state.record = record
                state.availability = .available
                return true
            } catch {
                state.availability = Self.availability(for: error)
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
            guard state.availability.isUsable else { return false }
            let today = Self.dayKey(for: date, calendar: calendar)
            var record = Self.rolling(state.record, to: today)
            record.search[origin] += count
            do {
                try write(record)
                state.record = record
                state.availability = .available
                return true
            } catch {
                state.availability = Self.availability(for: error)
                return false
            }
        }
    }

    func snapshot(at date: Date = Date()) -> LedgerSnapshot {
        lock.withLock { state in
            let today = Self.dayKey(for: date, calendar: calendar)
            guard state.availability.isUsable, let record = state.record else {
                return LedgerSnapshot(
                    day: today,
                    ai: LedgerCounts(),
                    search: LedgerCounts(),
                    tasks: LedgerCounts(),
                    availability: state.availability
                )
            }
            guard record.day == today else {
                return LedgerSnapshot(
                    day: today,
                    ai: LedgerCounts(),
                    search: LedgerCounts(),
                    tasks: LedgerCounts(),
                    availability: .available
                )
            }
            return LedgerSnapshot(
                day: record.day,
                ai: record.ai,
                search: record.search,
                tasks: record.tasks,
                availability: .available
            )
        }
    }

    /// `nil` means "unknown", never zero and never `Int.max`.
    func used(_ kind: LedgerKind, at date: Date = Date()) -> Int? {
        let snapshot = snapshot(at: date)
        guard snapshot.availability.isUsable else { return nil }
        switch kind {
        case .ai: return snapshot.totalAI
        case .search: return snapshot.totalSearch
        case .task: return snapshot.totalTasks
        }
    }

    /// Explicit recovery path. A corrupt or unreadable file is archived first
    /// with owner-only permissions, so a failed reset never silently discards
    /// the only copy. A future-version file is never reset from here.
    @discardableResult
    func resetToday(at date: Date = Date()) -> Bool {
        guard !ResearchActivity.isActive else { return false }
        return lock.withLock { state in
            guard state.availability != .unsupportedVersion else { return false }
            let record = Record(day: Self.dayKey(for: date, calendar: calendar))
            do {
                try archiveExistingFile()
                try write(record)
                state.record = record
                state.availability = .available
                return true
            } catch {
                if case .unsupportedVersion = state.availability {
                    return false
                }
                state.availability = Self.availability(for: error)
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

    // MARK: - File

    private func load() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            lock.withLock { $0.availability = .available }
            return
        }
        _ = PrivateFile.tightenExistingFile(fileURL)
        guard let data = try? Data(contentsOf: fileURL) else {
            lock.withLock { $0.availability = .ioUnavailable }
            return
        }
        guard let version = Self.probeVersion(data) else {
            lock.withLock { $0.availability = .corrupt }
            return
        }
        guard version <= Self.currentVersion else {
            lock.withLock { $0.availability = .unsupportedVersion }
            return
        }
        do {
            let record = try JSONDecoder().decode(Record.self, from: data)
            lock.withLock { state in
                guard record.isValid else {
                    state.availability = .corrupt
                    return
                }
                state.record = record
                state.availability = .available
            }
        } catch {
            lock.withLock { $0.availability = .corrupt }
        }
    }

    private static func probeVersion(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let version = object["version"] as? Int { return version }
        // A missing version is v1 only when the rest of the shape is present.
        return object["day"] != nil ? currentVersion : nil
    }

    private func write(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        try PrivateFile.write(data, to: fileURL, durable: true)
    }

    private func archiveExistingFile() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let archive = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(fileURL.lastPathComponent).corrupt-\(stamp)-\(UUID().uuidString.prefix(8))"
            )
        if manager.fileExists(atPath: archive.path) {
            try manager.removeItem(at: archive)
        }
        try manager.moveItem(at: fileURL, to: archive)
        _ = PrivateFile.tightenExistingFile(archive)
    }

    private static func availability(for error: Error) -> LedgerAvailability {
        if let error = error as? PrivateFileError {
            switch error {
            case .permissionMismatch, .invalidPath:
                return .ioUnavailable
            case .openFailed, .writeFailed, .syncFailed, .renameFailed:
                return .ioUnavailable
            }
        }
        return .ioUnavailable
    }
}
