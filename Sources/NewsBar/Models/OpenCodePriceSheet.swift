import Foundation

/// One of the four documented OpenCode price lists.
///
/// Go, Go Plus and Teams share a single model catalog and differ only in the
/// monthly allowance each model is charged against; Zen is metered per request.
/// Every number here is a static plan term published by OpenCode, not an
/// account balance, so nothing is fetched at runtime.
enum OpenCodePricingPlan: String, CaseIterable, Identifiable {
    case go
    case goPlus
    case teams
    case zen

    var id: String { rawValue }
    var titleKey: String { "settings.pricing.plan.\(rawValue)" }
    var isZen: Bool { self == .zen }

    /// The provider whose generated catalog backs this plan.
    var providerID: String {
        isZen ? AIProvider.opencodeZen.rawValue : AIProvider.opencodeGo.rawValue
    }

    /// Zen's promotional models answer 403 to third-party clients, so listing
    /// them would only invite a failed request. Go's free models are callable.
    var listsFreeModels: Bool { !isZen }

    var entries: [OpenCodePriceEntry] {
        isZen ? OpenCodePriceCatalog.zen : OpenCodePriceCatalog.go
    }

    /// The documented monthly allowance for this plan, in USD. `nil` for Zen,
    /// and for Go's promotional models, which the docs mark as unlimited.
    func monthlyAllowanceUSD(for entry: OpenCodePriceEntry) -> Double? {
        guard let allowance = entry.allowance else { return nil }
        switch self {
        case .go: return allowance.go
        case .goPlus: return allowance.goPlus
        case .teams: return allowance.goTeams
        case .zen: return nil
        }
    }
}

/// What the allowance column says for one row.
enum OpenCodeAllowance: Equatable {
    /// Documented monthly allowance, in USD.
    case monthlyUSD(Double)
    /// Go's promotional models carry no cap.
    case unlimited
    /// Zen bills per request, so there is no monthly figure to show.
    case metered
}

struct OpenCodePriceRow: Identifiable, Equatable {
    let model: String
    let inputUSDPerMTok: Double
    let outputUSDPerMTok: Double
    let cacheReadUSDPerMTok: Double?
    let allowance: OpenCodeAllowance
    let isFree: Bool
    let isCurrent: Bool

    var id: String { model }
}

enum OpenCodePriceCurrency: String, CaseIterable, Identifiable {
    case usd
    case cny

    var id: String { rawValue }
    var symbol: String { self == .usd ? "$" : "¥" }

    func convert(_ usd: Double) -> Double {
        self == .usd ? usd : usd * AIPriceCatalog.usdToCny
    }
}

/// Builds the price table. Kept free of SwiftUI so the mapping, sorting and
/// formatting can be tested without rendering anything.
enum OpenCodePriceSheet {
    static func rows(
        plan: OpenCodePricingPlan,
        query: String = "",
        currentModel: String = ""
    ) -> [OpenCodePriceRow] {
        // A pinned snapshot ("model:2026-10-01") is the same model for display
        // purposes; the catalog's own resolver already knows that.
        let resolvedCurrent = OpenCodePriceCatalog
            .entry(for: plan.providerID, model: currentModel)?.model
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return plan.entries
            .filter { plan.listsFreeModels || !$0.isFree }
            .map { entry in
                OpenCodePriceRow(
                    model: entry.model,
                    inputUSDPerMTok: entry.inputUSDPerMTok,
                    outputUSDPerMTok: entry.outputUSDPerMTok,
                    cacheReadUSDPerMTok: entry.cacheReadUSDPerMTok,
                    allowance: allowance(for: entry, plan: plan),
                    isFree: entry.isFree,
                    isCurrent: entry.model == resolvedCurrent
                )
            }
            .filter { needle.isEmpty || $0.model.lowercased().contains(needle) }
            .sorted(by: order)
    }

    /// How many models the plan lists, before any search.
    static func listedCount(for plan: OpenCodePricingPlan) -> Int {
        rows(plan: plan).count
    }

    private static func allowance(
        for entry: OpenCodePriceEntry,
        plan: OpenCodePricingPlan
    ) -> OpenCodeAllowance {
        if plan.isZen { return .metered }
        guard let usd = plan.monthlyAllowanceUSD(for: entry) else { return .unlimited }
        return .monthlyUSD(usd)
    }

    /// The model in use floats to the top; everything else stays alphabetical
    /// so the same row keeps the same place between visits.
    private static func order(_ lhs: OpenCodePriceRow, _ rhs: OpenCodePriceRow) -> Bool {
        if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
    }

    // MARK: - Formatting

    static func money(_ usd: Double, currency: OpenCodePriceCurrency) -> String {
        currency.symbol + decimal(currency.convert(usd))
    }

    /// Per-million prices span three orders of magnitude ($0.006 to $50), so a
    /// fixed two decimals would round the cheap ones to nothing. Three
    /// decimals with the trailing zeros trimmed keeps every row readable.
    static func decimal(_ value: Double) -> String {
        guard value != 0 else { return "0" }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// A price the catalog does not publish reads as a dash, never as $0.
    static func price(_ usd: Double?, currency: OpenCodePriceCurrency) -> String {
        guard let usd else { return "—" }
        return money(usd, currency: currency)
    }

    static func allowanceText(
        _ allowance: OpenCodeAllowance,
        currency: OpenCodePriceCurrency,
        language: AppLanguage = L10n.currentLanguage
    ) -> String {
        switch allowance {
        case .monthlyUSD(let usd):
            return money(usd, currency: currency)
        case .unlimited:
            return L10n.string("settings.pricing.allowance.unlimited", language: language)
        case .metered:
            return L10n.string("settings.pricing.allowance.metered", language: language)
        }
    }
}
