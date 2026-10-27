import Foundation

enum SearchProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case tavily
    case firecrawl
    case brave

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tavily: return "Tavily"
        case .firecrawl: return "Firecrawl"
        case .brave: return "Brave"
        }
    }

    /// Fixed product order: Tavily → Firecrawl → Brave. Users cannot reorder it;
    /// the only variation is which providers are enabled and keyed.
    static let failoverOrder: [SearchProviderID] = [.tavily, .firecrawl, .brave]

    /// Firecrawl has a keyless free tier; the other two require a key.
    var requiresAPIKey: Bool { self != .firecrawl }
}

enum SearchRecency: String, Codable, Sendable, CaseIterable {
    case day = "24h"
    case week = "7d"
    case month = "30d"
    case quarter = "90d"
    case year = "1y"
    case all = "all"

    var days: Int? {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        case .all: return nil
        }
    }

    /// Firecrawl's `tbs` time filter. Quarter has no exact token, so it widens
    /// to the month bucket rather than silently dropping the window.
    var firecrawlTBS: String? {
        switch self {
        case .day: return "qdr:d"
        case .week: return "qdr:w"
        case .month, .quarter: return "qdr:m"
        case .year: return "qdr:y"
        case .all: return nil
        }
    }

    /// Brave's `freshness` filter. Quarter widens to the month bucket.
    var braveFreshness: String? {
        switch self {
        case .day: return "pd"
        case .week: return "pw"
        case .month, .quarter: return "pm"
        case .year: return "py"
        case .all: return nil
        }
    }
}

/// User-facing default window. `auto` is resolved from the seed's publish date
/// by the pipeline; the other cases map onto concrete search windows.
enum ResearchDefaultRecency: String, Codable, Sendable, CaseIterable {
    case auto
    case week = "7d"
    case month = "30d"
    case quarter = "90d"
    case year = "1y"
    case all

    var explicit: SearchRecency? {
        switch self {
        case .auto: return nil
        case .week: return .week
        case .month: return .month
        case .quarter: return .quarter
        case .year: return .year
        case .all: return .all
        }
    }
}

struct SearchQuery: Sendable, Equatable {
    let text: String
    let recency: SearchRecency
    let language: String?
    let maxResults: Int

    init(text: String, recency: SearchRecency = .month, language: String? = nil, maxResults: Int = 6) {
        self.text = text
        self.recency = recency
        self.language = language
        self.maxResults = max(1, maxResults)
    }
}

struct SearchHit: Codable, Hashable, Sendable {
    let url: String
    let title: String
    let snippet: String
    let publishedAt: Date?
    /// Tavily's `raw_content`. Empty for the other providers.
    let inlineContent: String?
    let provider: SearchProviderID
    /// 1-based rank inside the provider's own result list.
    let providerRank: Int

    init(
        url: String,
        title: String,
        snippet: String,
        publishedAt: Date? = nil,
        inlineContent: String? = nil,
        provider: SearchProviderID,
        providerRank: Int
    ) {
        self.url = url
        self.title = title
        self.snippet = snippet
        self.publishedAt = publishedAt
        self.inlineContent = inlineContent
        self.provider = provider
        self.providerRank = providerRank
    }

    var canonicalURL: String { ContentIdentity.canonicalURL(url) }

    var domain: String {
        guard let host = URL(string: url)?.host else { return "" }
        return SourceTierCatalog.registrableDomain(host)
    }
}

struct SearchBatch: Sendable, Equatable {
    var hits: [SearchHit]
    /// Providers that actually answered (cache hits keep their original value).
    var providers: [SearchProviderID]
    /// HTTP attempts including retries and failovers.
    var attempts: Int
    var failovers: Int
    var fetchedAt: Date

    static let empty = SearchBatch(hits: [], providers: [], attempts: 0, failovers: 0, fetchedAt: .distantPast)
}

enum SearchProviderError: Error, Equatable, LocalizedError {
    case missingKey
    case unauthorized
    case quotaExhausted
    case server(Int)
    case timeout
    case transport(String)
    case malformedResponse
    case emptyQuery

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Search provider API key is missing"
        case .unauthorized: return "Search provider rejected the API key"
        case .quotaExhausted: return "Search provider quota exhausted"
        case .server(let status): return "Search provider returned HTTP \(status)"
        case .timeout: return "Search request timed out"
        case .transport(let detail): return "Search transport failed: \(detail)"
        case .malformedResponse: return "Search response could not be decoded"
        case .emptyQuery: return "Search query is empty"
        }
    }

    var isQuotaFailure: Bool {
        switch self {
        case .quotaExhausted: return true
        default: return false
        }
    }
}

/// All providers failed. The pipeline degrades to an AI-only partial report
/// instead of failing the whole task.
struct SearchUnavailableError: Error, LocalizedError, Equatable {
    let reasons: [String]

    var errorDescription: String? {
        reasons.isEmpty ? "All search providers are unavailable" : reasons.joined(separator: "; ")
    }
}

enum SearchResultRanking {
    /// Deterministic ordering: better source tier first, then provider order,
    /// then provider rank. Aggregators and social sources sink to the bottom.
    static func ranked(_ hits: [SearchHit]) -> [SearchHit] {
        hits.sorted { lhs, rhs in
            let lhsTier = SourceTierCatalog.info(for: lhs.url).tier.rawValue
            let rhsTier = SourceTierCatalog.info(for: rhs.url).tier.rawValue
            if lhsTier != rhsTier { return lhsTier < rhsTier }

            let lhsProvider = SearchProviderID.failoverOrder.firstIndex(of: lhs.provider) ?? 99
            let rhsProvider = SearchProviderID.failoverOrder.firstIndex(of: rhs.provider) ?? 99
            if lhsProvider != rhsProvider { return lhsProvider < rhsProvider }
            if lhs.providerRank != rhs.providerRank { return lhs.providerRank < rhs.providerRank }
            return lhs.canonicalURL < rhs.canonicalURL
        }
    }

    /// Canonical-URL de-duplication plus at most two hits per registrable domain,
    /// so one prolific publisher cannot fill every reading slot.
    static func deduplicated(_ hits: [SearchHit], maxPerDomain: Int = 2) -> [SearchHit] {
        var seenURLs: Set<String> = []
        var domainCounts: [String: Int] = [:]
        var output: [SearchHit] = []

        for hit in ranked(hits) {
            let canonical = hit.canonicalURL
            guard !canonical.isEmpty, !seenURLs.contains(canonical) else { continue }
            let domain = hit.domain.isEmpty ? canonical : hit.domain
            let count = domainCounts[domain, default: 0]
            guard count < maxPerDomain else { continue }
            seenURLs.insert(canonical)
            domainCounts[domain] = count + 1
            output.append(hit)
        }
        return output
    }
}
