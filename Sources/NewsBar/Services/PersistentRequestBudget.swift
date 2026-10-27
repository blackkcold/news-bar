import Foundation
import os

/// Reserve before dispatch and never refund a possibly-sent request. The small
/// ledger is deliberately separate from personal-data clearing and news caches.
final class PersistentRequestBudget: Sendable {
    private struct Record: Codable, Sendable {
        var day: Int
        var count: Int
    }
    private struct State: Sendable {
        var record: Record?
        var corrupt = false
    }
    private let fileURL: URL
    private let lock: OSAllocatedUnfairLock<State>

    init(fileURL: URL) {
        self.fileURL = fileURL
        var state = State()
        _ = PrivateFile.tightenExistingFile(fileURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL), let record = try? JSONDecoder().decode(Record.self, from: data), record.count >= 0 {
                state.record = record
            } else { state.corrupt = true }
        }
        lock = OSAllocatedUnfairLock(initialState: state)
    }

    private func day(_ date: Date) -> Int { Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0 }

    func used(at date: Date = Date()) -> Int {
        lock.withLock { state in
            if state.corrupt { return Int.max }
            return state.record?.day == day(date) ? state.record?.count ?? 0 : 0
        }
    }

    func reserve(cap: Int, baseline: Int = 0, at date: Date = Date()) -> Bool {
        lock.withLock { state in
            guard !state.corrupt, cap > 0 else { return false }
            var record = state.record?.day == day(date) ? state.record! : Record(day: day(date), count: 0)
            record.count = max(record.count, max(0, baseline))
            guard record.count < cap else { return false }
            record.count += 1
            do {
                let data = try JSONEncoder().encode(record)
                try PrivateFile.write(data, to: fileURL, durable: false)
                state.record = record
                return true
            } catch {
                state.corrupt = true
                return false
            }
        }
    }
}
