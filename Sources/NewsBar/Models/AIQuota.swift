import Foundation

/// How AI usage is limited. The two modes are mutually exclusive: Settings
/// exposes either a call count or a money budget, never both.
enum AILimitMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case count
    case cost

    var id: String { rawValue }
}

/// Immutable limit handed to the service layer, so the gate never reads
/// mutable UI state mid-flight.
struct AIQuotaPolicy: Sendable, Equatable {
    var mode: AILimitMode
    /// `nil` means unlimited.
    var countCap: Int?
    /// `nil` means unlimited, in micros of the display currency (1e-6).
    var costCapMicros: Int64?

    init(
        mode: AILimitMode = .count,
        countCap: Int? = nil,
        costCapMicros: Int64? = nil
    ) {
        self.mode = mode
        self.countCap = countCap
        self.costCapMicros = costCapMicros
    }

    static let unlimited = AIQuotaPolicy(mode: .count, countCap: nil, costCapMicros: nil)

    /// True when one more call would exceed the active limit.
    func blocks(count: Int, costMicros: Int64) -> Bool {
        switch mode {
        case .count:
            guard let countCap else { return false }
            return count >= max(0, countCap)
        case .cost:
            guard let costCapMicros else { return false }
            return costMicros >= max(0, costCapMicros)
        }
    }
}

/// Why a call was made. Used only for the usage breakdown in Settings.
enum AIQuotaOrigin: String, Codable, Sendable, CaseIterable {
    case summary
    case research
    case triage
}
