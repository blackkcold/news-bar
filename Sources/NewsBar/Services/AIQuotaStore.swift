import Foundation
import os

/// The single, app-wide authority for AI usage.
///
/// One file, one lock, one fail-closed policy: an unreadable record refuses
/// every reservation until the user explicitly resets today's usage. The
/// per-generation counters in `AISummaryService` stay in memory and no longer
/// decide anything; the old persistent budget files are read once for migration
/// and then ignored.
final class AIQuotaStore: Sendable {
    static let shared = AIQuotaStore()

    static let currentVersion = 1

    enum Availability: String, Sendable, Equatable {
        case loading
        case available
        case corrupt
        case ioUnavailable
        case unsupportedVersion

        var isUsable: Bool { self == .available }
    }

    struct Snapshot: Sendable, Equatable {
        var day: Int = 0
        var count: Int = 0
        var costMicros: Int64 = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var unpricedCalls: Int = 0
        var origins: [String: Int] = [:]
        var availability: Availability = .loading

        var isUsable: Bool { availability.isUsable }

        func calls(_ origin: AIQuotaOrigin) -> Int {
            origins[origin.rawValue] ?? 0
        }
    }

    /// A reservation belongs to exactly one open request in this store. Its
    /// identifier is deliberately opaque to callers.
    struct Reservation: Sendable, Hashable {
        fileprivate let id: UUID
        fileprivate let day: Int
        fileprivate let costMicros: Int64
    }

    /// Every added field must decode with a default. A missing key must never
    /// turn an existing record into a corrupt one, because the store fails
    /// closed and would pause all AI usage.
    private struct Record: Codable, Sendable {
        var version = AIQuotaStore.currentVersion
        var day: Int
        var count = 0
        var costMicros: Int64 = 0
        var inputTokens = 0
        var outputTokens = 0
        var unpricedCalls = 0
        var origins: [String: Int] = [:]

        var isValid: Bool {
            version <= AIQuotaStore.currentVersion
                && day >= 0
                && count >= 0
                && costMicros >= 0
                && inputTokens >= 0
                && outputTokens >= 0
                && unpricedCalls >= 0
                && origins.values.allSatisfy { $0 >= 0 }
        }

        enum CodingKeys: String, CodingKey {
            case version, day, count, costMicros, inputTokens, outputTokens, unpricedCalls, origins
        }

        init(day: Int) {
            self.day = day
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version)
                ?? AIQuotaStore.currentVersion
            day = try container.decode(Int.self, forKey: .day)
            count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
            costMicros = try container.decodeIfPresent(Int64.self, forKey: .costMicros) ?? 0
            inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
            outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            unpricedCalls = try container.decodeIfPresent(Int.self, forKey: .unpricedCalls) ?? 0
            origins = try container.decodeIfPresent([String: Int].self, forKey: .origins) ?? [:]
        }
    }

    private struct State: Sendable {
        var record: Record?
        var availability: Availability = .loading
        var openReservations: [UUID: Reservation] = [:]
    }

    private let fileURL: URL
    private let calendar: Calendar
    private let lock: OSAllocatedUnfairLock<State>

    static var defaultFileURL: URL {
        if TestIsolation.isActive {
            return TestIsolation.directory("Quota").appendingPathComponent("quota.json")
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.newsbar.app/AIQuota/quota.json")
    }

    private static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    init(fileURL: URL = AIQuotaStore.defaultFileURL, calendar: Calendar? = nil) {
        self.fileURL = fileURL
        self.calendar = calendar ?? AIQuotaStore.defaultCalendar
        let loaded = AIQuotaStore.load(fileURL: fileURL)
        lock = OSAllocatedUnfairLock(initialState: State(record: loaded.0, availability: loaded.1))
    }

    // MARK: - Reading

    func snapshot(at date: Date = Date()) -> Snapshot {
        lock.withLock { state in
            let today = AIQuotaStore.dayKey(for: date, calendar: calendar)
            guard state.availability.isUsable, let record = state.record else {
                return Snapshot(day: today, availability: state.availability)
            }
            guard record.day == today else {
                return Snapshot(day: today, availability: .available)
            }
            return Snapshot(
                day: record.day,
                count: record.count,
                costMicros: record.costMicros,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens,
                unpricedCalls: record.unpricedCalls,
                origins: record.origins,
                availability: .available
            )
        }
    }

    // MARK: - Reserving

    /// Reserve one call before dispatch. Never refunded on failure: the request
    /// may already have reached the provider.
    ///
    /// Retained for existing callers and tests. Production paths use
    /// `reserveTracked` so a late settlement cannot consume another request's
    /// ceiling.
    @available(*, deprecated, message: "Use reserveTracked and settle(_:usage:price:)")
    @discardableResult
    func reserve(
        _ origin: AIQuotaOrigin,
        policy: AIQuotaPolicy,
        reservedCostMicros: Int64 = 0,
        at date: Date = Date()
    ) -> Bool {
        reserveInternal(
            origin, policy: policy, reservedCostMicros: reservedCostMicros, at: date, tracked: false
        ) != nil
    }

    /// Reserve a request whose later settlement must be tied to this exact
    /// amount and calendar day. A reset or rollover invalidates old handles.
    func reserveTracked(
        _ origin: AIQuotaOrigin,
        policy: AIQuotaPolicy,
        reservedCostMicros: Int64 = 0,
        at date: Date = Date()
    ) -> Reservation? {
        reserveInternal(
            origin, policy: policy, reservedCostMicros: reservedCostMicros, at: date, tracked: true
        )
    }

    private func reserveInternal(
        _ origin: AIQuotaOrigin,
        policy: AIQuotaPolicy,
        reservedCostMicros: Int64,
        at date: Date,
        tracked: Bool
    ) -> Reservation? {
        lock.withLock { state in
            guard state.availability.isUsable else { return nil }
            let today = AIQuotaStore.dayKey(for: date, calendar: calendar)
            // A backward clock adjustment must not reopen yesterday's budget.
            guard (state.record?.day ?? today) <= today else { return nil }
            var record = AIQuotaStore.rolling(state.record, to: today)
            let reserved = max(0, reservedCostMicros)
            let (nextCost, costOverflow) = record.costMicros.addingReportingOverflow(reserved)
            let (nextCount, countOverflow) = record.count.addingReportingOverflow(1)
            let (nextOriginCount, originOverflow) = (record.origins[origin.rawValue] ?? 0).addingReportingOverflow(1)
            guard !costOverflow, !countOverflow, !originOverflow,
                  !policy.blocks(count: record.count, costMicros: nextCost) else {
                return nil
            }
            record.count = nextCount
            record.origins[origin.rawValue] = nextOriginCount
            record.costMicros = nextCost
            let reservation = Reservation(id: UUID(), day: today, costMicros: reserved)
            let rolledOver = state.record.map { $0.day != today } ?? false

            do {
                try write(record)
                state.record = record
                state.availability = .available
                if rolledOver { state.openReservations.removeAll() }
                if tracked { state.openReservations[reservation.id] = reservation }
                return reservation
            } catch {
                state.availability = AIQuotaStore.availability(for: error)
                return nil
            }
        }
    }

    /// A stale, duplicated, foreign, or reset reservation never changes the
    /// current total. Consume the identity before writing so even a post-rename
    /// failure cannot be replayed against another request's balance.
    @discardableResult
    func settle(
        _ reservation: Reservation,
        actualCostMicros: Int64,
        inputTokens: Int,
        outputTokens: Int,
        priced: Bool,
        at date: Date = Date()
    ) -> Bool {
        lock.withLock { state in
            guard state.availability.isUsable,
                  state.openReservations[reservation.id] == reservation else { return false }
            state.openReservations.removeValue(forKey: reservation.id)
            let today = AIQuotaStore.dayKey(for: date, calendar: calendar)
            guard today == reservation.day, var record = state.record, record.day == reservation.day else {
                return false
            }
            guard record.costMicros >= reservation.costMicros else {
                state.availability = .corrupt
                return false
            }
            let (nextCost, costOverflow) = (record.costMicros - reservation.costMicros)
                .addingReportingOverflow(max(0, actualCostMicros))
            let (nextInput, inputOverflow) = record.inputTokens.addingReportingOverflow(max(0, inputTokens))
            let (nextOutput, outputOverflow) = record.outputTokens.addingReportingOverflow(max(0, outputTokens))
            let (nextUnpriced, unpricedOverflow) = record.unpricedCalls.addingReportingOverflow(priced ? 0 : 1)
            guard !costOverflow, !inputOverflow, !outputOverflow, !unpricedOverflow else {
                state.availability = .ioUnavailable
                return false
            }
            record.costMicros = nextCost
            record.inputTokens = nextInput
            record.outputTokens = nextOutput
            record.unpricedCalls = nextUnpriced
            do {
                try write(record)
                state.record = record
                return true
            } catch {
                state.availability = AIQuotaStore.availability(for: error)
                return false
            }
        }
    }

    @discardableResult
    func settle(
        _ reservation: Reservation, usage: AIUsage?, price: ModelPrice?, at date: Date = Date()
    ) -> Bool {
        let actual: Int64
        let priced: Bool
        if let reported = usage?.reportedCost {
            actual = reported.cnyMicros
            priced = true
        } else if let price, let usage {
            actual = AICostEstimator.costMicros(usage: usage, price: price)
            priced = true
        } else {
            actual = reservation.costMicros
            priced = false
        }
        return settle(
            reservation, actualCostMicros: actual,
            inputTokens: usage?.inputTokens ?? 0, outputTokens: usage?.outputTokens ?? 0,
            priced: priced, at: date
        )
    }

    /// Settle a dispatched call against its reservation. The estimate is
    /// replaced by the measured cost; an unpriced call stays at the estimate
    /// and is counted so the UI can say the total is incomplete.
    @discardableResult
    func settle(
        reservedCostMicros: Int64,
        actualCostMicros: Int64,
        inputTokens: Int,
        outputTokens: Int,
        priced: Bool,
        at date: Date = Date()
    ) -> Bool {
        lock.withLock { state in
            guard state.availability.isUsable else { return false }
            let today = AIQuotaStore.dayKey(for: date, calendar: calendar)
            guard (state.record?.day ?? today) <= today else { return false }
            let rolledOver = state.record.map { $0.day != today } ?? false
            var record = AIQuotaStore.rolling(state.record, to: today)
            let delta = max(0, actualCostMicros) - max(0, reservedCostMicros)
            // Never let a legacy (identity-less) settlement push the pool below
            // an in-flight tracked reservation: that would make the tracked
            // settle fail its invariant and lock the whole ledger as corrupt.
            let protectedTotal = state.openReservations.values.reduce(Int64(0)) { partial, reservation in
                let (next, overflow) = partial.addingReportingOverflow(reservation.costMicros)
                return overflow ? Int64.max : next
            }
            let (adjustedCost, costOverflow) = record.costMicros.addingReportingOverflow(delta)
            let (nextInput, inputOverflow) = record.inputTokens.addingReportingOverflow(max(0, inputTokens))
            let (nextOutput, outputOverflow) = record.outputTokens.addingReportingOverflow(max(0, outputTokens))
            let (nextUnpriced, unpricedOverflow) = record.unpricedCalls.addingReportingOverflow(priced ? 0 : 1)
            guard !costOverflow, !inputOverflow, !outputOverflow, !unpricedOverflow else {
                state.availability = .ioUnavailable
                return false
            }
            record.costMicros = max(protectedTotal, max(0, adjustedCost))
            record.inputTokens = nextInput
            record.outputTokens = nextOutput
            record.unpricedCalls = nextUnpriced

            do {
                try write(record)
                state.record = record
                state.availability = .available
                if rolledOver { state.openReservations.removeAll() }
                return true
            } catch {
                state.availability = AIQuotaStore.availability(for: error)
                return false
            }
        }
    }

    // MARK: - Migration

    /// Carries today's already-spent calls into the new ledger exactly once.
    /// Summary and research were separate books, so their counts add; within
    /// the summary book the UserDefaults counter and the durable budget counted
    /// the same attempts, so the caller passes the larger of the two.
    /// A non-empty ledger makes this a no-op, so a retry cannot double count.
    @discardableResult
    func seedLegacyUsage(
        summaryCount: Int,
        researchCount: Int,
        at date: Date = Date()
    ) -> Bool {
        let summary = max(0, summaryCount)
        let research = max(0, researchCount)
        guard summary > 0 || research > 0 else { return true }

        return lock.withLock { state in
            guard state.availability.isUsable else { return false }
            let today = AIQuotaStore.dayKey(for: date, calendar: calendar)
            guard (state.record?.day ?? today) <= today else { return false }
            var record = AIQuotaStore.rolling(state.record, to: today)
            guard record.count == 0 else { return true }
            record.count = summary + research
            if summary > 0 {
                record.origins[AIQuotaOrigin.summary.rawValue] = summary
            }
            if research > 0 {
                record.origins[AIQuotaOrigin.research.rawValue] = research
            }

            do {
                try write(record)
                state.record = record
                state.openReservations.removeAll()
                state.availability = .available
                return true
            } catch {
                state.availability = AIQuotaStore.availability(for: error)
                return false
            }
        }
    }

    // MARK: - Recovery

    /// Explicit recovery path: archive the unreadable file first, then start a
    /// clean day. Never called automatically.
    @discardableResult
    func resetToday(at date: Date = Date()) -> Bool {
        lock.withLock { state in
            guard state.availability != .unsupportedVersion else { return false }
            let record = Record(day: AIQuotaStore.dayKey(for: date, calendar: calendar))
            do {
                try archiveExistingFile()
                try write(record)
                state.record = record
                state.openReservations.removeAll()
                state.availability = .available
                return true
            } catch {
                state.availability = .ioUnavailable
                return false
            }
        }
    }

    // MARK: - Persistence

    private func write(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        try PrivateFile.write(data, to: fileURL, durable: true)
    }

    private func archiveExistingFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let target = fileURL.deletingLastPathComponent()
            .appendingPathComponent("quota.archive-\(stamp).json")
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: fileURL, to: target)
    }

    private static func load(fileURL: URL) -> (Record?, Availability) {
        _ = PrivateFile.tightenExistingFile(fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return (nil, .available)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return (nil, .ioUnavailable)
        }

        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let storedVersion = (object?["version"] as? Int) ?? currentVersion
        if storedVersion > currentVersion {
            return (nil, .unsupportedVersion)
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.isValid else {
            return (nil, .corrupt)
        }
        return (record, .available)
    }

    private static func rolling(_ existing: Record?, to day: Int) -> Record {
        guard let existing, existing.day == day else { return Record(day: day) }
        return existing
    }

    private static func availability(for error: Error) -> Availability {
        if case PrivateFileError.permissionMismatch = error {
            return .corrupt
        }
        return .ioUnavailable
    }

    static func dayKey(for date: Date, calendar: Calendar? = nil) -> Int {
        let calendar = calendar ?? defaultCalendar
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10_000
            + (components.month ?? 0) * 100
            + (components.day ?? 0)
    }

    /// Settle a dispatched call using measured usage. An unpriced call keeps
    /// its reservation and is counted so the UI can say the total is incomplete.
    func settle(
        reservedCostMicros: Int64,
        usage: AIUsage?,
        price: ModelPrice?,
        at date: Date = Date()
    ) {
        let actual: Int64
        let priced: Bool
        if let reported = usage?.reportedCost {
            // The provider knows whether this was a balance charge, a Go
            // allowance, a free call or a BYOK estimate. Never replace that
            // with the local table.
            actual = reported.cnyMicros
            priced = true
        } else if let price, let usage {
            actual = AICostEstimator.costMicros(usage: usage, price: price)
            priced = true
        } else {
            actual = max(0, reservedCostMicros)
            priced = false
        }
        _ = settle(
            reservedCostMicros: reservedCostMicros,
            actualCostMicros: actual,
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0,
            priced: priced,
            at: date
        )
    }
}
