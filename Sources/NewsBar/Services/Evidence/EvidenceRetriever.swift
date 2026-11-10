import Foundation

struct QueryOutcome: Equatable, Sendable {
    let query: EvidenceQuery
    let hitCount: Int
    let failed: Bool
}

struct EvidencePageCandidate: Equatable, Sendable {
    let hit: SearchHit
    let discoveredBy: EvidenceQuery.Role
}

struct RetrievalResult: Equatable, Sendable {
    var candidates: [EvidencePageCandidate] = []
    var outcomes: [QueryOutcome] = []
    var foundCount: Int = 0
    var uniqueCount: Int = 0
    var attemptsUsed: Int = 0
    /// True only when every query failed. A successful query with zero hits is
    /// "no results", not "search unavailable".
    var searchUnavailable: Bool = false
    var failureDetail: String?

    static let empty = RetrievalResult()
}

/// Runs a `EvidenceQueryPlan` against the search router under one shared attempt
/// budget. The ticket is supplied by the run, not created per query: three
/// variants must not each receive a fresh six-attempt allowance.
enum EvidenceRetriever {
    typealias SearchHandler = @Sendable (
        _ query: SearchQuery,
        _ ticket: SearchAttemptTicket
    ) async throws -> [SearchHit]

    /// Per-query ceilings. Three queries × two attempts fills the run's
    /// six-attempt ticket exactly.
    static let maxAttemptsPerQuery = 2
    static let maxProviderAttemptsPerQuery = 2

    static func retrieve(
        plan: EvidenceQueryPlan,
        search: SearchHandler,
        ticket: SearchAttemptTicket,
        candidateCap: Int,
        language: AppLanguage
    ) async -> RetrievalResult {
        var result = RetrievalResult()
        let startUsed = ticket.used
        let cap = max(1, candidateCap)
        var scores: [String: Int] = [:]
        var pool: [String: EvidencePageCandidate] = [:]

        for query in plan.queries {
            if Task.isCancelled { break }
            do {
                let hits = try await search(
                    SearchQuery(
                        text: query.text,
                        recency: query.recency,
                        language: language.bcp47,
                        maxResults: cap
                    ),
                    ticket
                )
                result.outcomes.append(
                    QueryOutcome(query: query, hitCount: hits.count, failed: false)
                )
                result.foundCount += hits.count

                for hit in hits {
                    let key = hit.canonicalURL
                    let score = min(max(1, hit.providerRank), 99) + query.role.rankBonus
                    if let current = scores[key], current <= score { continue }
                    scores[key] = score
                    pool[key] = EvidencePageCandidate(hit: hit, discoveredBy: query.role)
                }
            } catch is CancellationError {
                break
            } catch {
                result.outcomes.append(
                    QueryOutcome(query: query, hitCount: 0, failed: true)
                )
                if result.failureDetail == nil {
                    result.failureDetail = error.localizedDescription
                }
            }
        }

        result.uniqueCount = pool.count
        let ordered = pool.values.sorted { lhs, rhs in
            let left = scores[lhs.hit.canonicalURL] ?? 0
            let right = scores[rhs.hit.canonicalURL] ?? 0
            if left != right { return left < right }
            return lhs.hit.canonicalURL < rhs.hit.canonicalURL
        }
        result.candidates = Array(ordered.prefix(cap))
        result.attemptsUsed = max(0, ticket.used - startUsed)
        result.searchUnavailable = !result.outcomes.isEmpty
            && result.outcomes.allSatisfy(\.failed)
        return result
    }
}
