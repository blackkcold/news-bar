import Foundation

struct TimelineNode: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(date)\n\(title)" }
    /// AI-produced date label, e.g. "2026-08-05", "8月3日", or a relative label.
    let date: String
    let title: String
    let detail: String
}

/// Whether web search ran (and how it ended) for a burst research pass.
enum BurstSearchStatus: String, Codable, Sendable {
    case none
    case searching
    case succeeded
    case failed
}

struct BurstResearch: Codable, Hashable, Sendable {
    var summary: String = ""
    var overview: String = ""
    /// Empty when the AI lacked grounded info (e.g. pure-AI fallback) — UI hides it.
    var timeline: [TimelineNode] = []
    /// Source URLs the research is grounded on (search mode only).
    var sources: [String] = []
    /// Self-healing contract: true when AI wants page content scraped for accuracy.
    var needsRefetch: Bool = false
    /// URLs the AI wants scraped when `needsRefetch` is true.
    var refetchURLs: [String] = []
    /// How web search ended in this pass (for UI diagnostics & logging).
    var searchStatus: BurstSearchStatus = .none
}

struct WebSearchResult: Codable, Hashable, Sendable {
    let url: String
    let title: String
    let description: String
    /// Search-provider snippet; the only content available when scraping is off.
    var snippet: String = ""

    init(url: String, title: String, description: String, snippet: String = "") {
        self.url = url
        self.title = title
        self.description = description
        self.snippet = snippet
    }
}

/// Extensible for future Bing/DDG providers; only Firecrawl (keyless) is shipped.
enum WebSearchProvider: String, CaseIterable, Codable, Sendable {
    case firecrawl
}

