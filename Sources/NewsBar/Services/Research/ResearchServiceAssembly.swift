import Foundation

/// The one long-lived service graph for search, page reading and research
/// accounting.
///
/// Production `SearchRouter`/`PageReader` construction lives here. Tests may
/// construct isolated instances; nothing in the app should build its own router,
/// page reader or cache, because two instances mean two cache epochs and two
/// sets of provider cooldowns.
///
/// The page reader is a stateless value, so only the cache is shared between
/// readers. The router is an actor and keeps cooldown/status state, which is the
/// state that must be shared between AI search, page summary and research.
final class ResearchServiceAssembly: Sendable {
    static let shared = ResearchServiceAssembly()

    let cache: ResearchCacheStore
    let ledger: ResearchLedger
    let aiQuota: AIQuotaStore
    let searchQuota: SearchQuotaStore
    let searchRouter: SearchRouter
    let basePageReader: PageReader

    init(
        cache: ResearchCacheStore = .shared,
        ledger: ResearchLedger = .shared,
        aiQuota: AIQuotaStore = .shared,
        searchQuota: SearchQuotaStore = .shared
    ) {
        self.cache = cache
        self.ledger = ledger
        self.aiQuota = aiQuota
        self.searchQuota = searchQuota
        self.searchRouter = SearchRouter(
            cache: cache,
            ledger: ledger,
            quota: searchQuota
        )
        self.basePageReader = PageReader(cache: cache, isScrapeEnabled: true)
    }

    /// The direct reader is stateless; only the cache must be shared.
    func pageReader(isScrapeEnabled: Bool) -> PageReader {
        PageReader(cache: cache, isScrapeEnabled: isScrapeEnabled)
    }
}
