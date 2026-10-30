import Foundation

/// The rule that decides whether `.auto` may answer from model knowledge.
///
/// The planner model classifies the passage, but its `needsLookup` flag is only
/// a suggestion: Settings promises that news, figures and uncertain claims go
/// online. A model that answers "no lookup needed" for a product launch must
/// not be able to switch that promise off, so the kind decides here, not the
/// flag.
enum SelectionLookupPolicy {
    /// Passages that are time-sensitive even when they read like a term.
    private static let freshnessCues = [
        "今年", "本月", "上周", "本周", "刚刚",
        "发布", "推出", "上市", "发售", "首销",
        "涨价", "降价", "停供", "停产", "更新",
    ]

    /// A `nil` plan means the classification never produced one. That is not a
    /// "no": the planner's own contract says a failed parse means look it up,
    /// and a missing answer is worse than an extra search.
    static func shouldLookUp(_ plan: SelectionPlan?, in text: String) -> Bool {
        guard let plan else { return true }
        switch plan.kind {
        case .event, .number, .comparison:
            return true
        case .term, .howto:
            if plan.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return hasFreshnessCue(in: text)
        }
    }

    /// `2026 年`, `2026年` and the release vocabulary that dates a passage.
    static func hasFreshnessCue(in text: String) -> Bool {
        if text.range(of: #"20\d\d\s*年"#, options: .regularExpression) != nil {
            return true
        }
        return freshnessCues.contains { text.contains($0) }
    }
}
