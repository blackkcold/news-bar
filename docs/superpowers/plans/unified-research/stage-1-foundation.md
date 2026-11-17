# Stage 1 — Foundation: Assembly, Clients, Cache

> Checkbox status (2026-11-16): `[x]` means the item was delivered in code and
> covered by the compile evidence in `stage-1-report.md`. Runtime UI/notification/network
> was not executed; those behaviors remain unverified.

> Parent: `docs/superpowers/plans/2026-11-16-unified-research-workspace.md`
> Read `research-findings.md` first. Do not re-survey the repo.

## Goal

Create the single long-lived service graph, one AI client factory, one cache
key/cleanup path and one search-ticket path. No workspace UI or domain model
yet. This stage must be behavior-preserving except for the intended cache
sharing and quota correctness.

## Rulings (2026-11-16, authoritative over the steps below)

These four rulings were issued after the stage doc was written. Where a step
below disagrees, the ruling wins.

- **R1 — freshness before sharing.** One cache store is shared, but sharing must
  not make an AI answer 12 hours old. `SearchRouter.search` gains a
  source-compatible `maxAge: TimeInterval?` (a downward clamp on the store TTL)
  and `ResearchCacheStore.load` gains the matching clamp. AI search keeps its
  previous 10-minute window (`SearchHitCache.aiSearchMaxAge`), research keeps the
  existing 12-hour snapshot TTL (`maxAge == nil`), and the page overview keeps
  its previous "always fresh" policy (`useCache: false`). All three use the same
  key, file layout and `writeGeneration` epoch. No second, uncleaned cache layer
  is added; `SearchHitCache` stops being a read/write layer for AI search and is
  only cleared defensively.
- **R2 — one cleanup path.** Every research cleanup entry (`ResearchDataSection`
  / `PrivacyTab`, clear-history, full clear, `ResearchMaintenance`) goes through
  `ResearchCacheCoordinator`, so one clear bumps one epoch and an in-flight
  write cannot repopulate cleared data. The coordinator takes the cache as a
  defaulted parameter so injected/test stores still work.
- **R3 — one build.** Do not compile after every small step. All stage-1 code
  lands first, then one `swift build`. The parent plan's optional "manual launch
  by the main agent" is removed; no app, test, baseline or API run here.
- **R4 — one client factory, not one behavior.** `AIChatClientFactory` covers the
  research/triage, AI search, evidence-assessment, selection (划词) and page
  overview HTTP clients. Each call keeps its current timeout, thinking,
  DeepSeek-thinking, user-agent and preflight/capacity semantics. Independent
  summary/system-one clients are out of scope. `ResearchPipeline` keeps its
  unmetered client; every other origin keeps its `AIQuotaStore` callback.

## Files

Create:

- `Sources/NewsBar/Services/Research/ResearchServiceAssembly.swift`
- `Sources/NewsBar/Services/AI/AIChatClientFactory.swift`
- `Sources/NewsBar/Services/Research/ResearchCacheCoordinator.swift`

Modify:

- `Sources/NewsBar/Services/AISearch/AISearchServiceFactory.swift:43-46,148-165`
- `Sources/NewsBar/Services/PageSummary/PageSummaryEvidenceProvider.swift:241-250`
- `Sources/NewsBar/Services/NewsOrchestrator.swift:126,1423`
- `Sources/NewsBar/Services/Search/ManualSearchGateway.swift:9-45`
- `Sources/NewsBar/Services/AISearch/SearchHitCache.swift`
- `Sources/NewsBar/Services/Search/SearchRouter.swift` (comment/access only if needed)

## Interfaces

Produces:

```swift
final class ResearchServiceAssembly: Sendable {
    static let shared: ResearchServiceAssembly
    let cache: ResearchCacheStore
    let ledger: ResearchLedger
    let aiQuota: AIQuotaStore
    let searchQuota: SearchQuotaStore
    let searchRouter: SearchRouter
    let basePageReader: PageReader
    func pageReader(isScrapeEnabled: Bool) -> PageReader
}

enum AIChatClientFactory {
    static func unmetered(
        connection: ResolvedAIConnection, apiKey: String, model: String,
        disableDeepSeekThinking: Bool = false, thinking: AIThinkingLevel? = nil,
        timeout: TimeInterval = 60
    ) -> HTTPAIChatClient

    static func metered(
        origin: AIQuotaOrigin, policy: AIQuotaPolicy, price: ModelPrice?,
        connection: ResolvedAIConnection, apiKey: String, model: String,
        thinking: AIThinkingLevel? = nil, timeout: TimeInterval = 60,
        quota: AIChatQuota? = nil
    ) -> HTTPAIChatClient
}

struct ResearchCacheClearReceipt: Sendable, Equatable {
    let epoch: Int
    let removedBytes: Int64
    let isComplete: Bool
}

enum ResearchCacheCoordinator {
    static func clearAll() async -> ResearchCacheClearReceipt
    static func enforceLimits(maxBytes: Int64, protecting: Set<String>) async -> ResearchCacheStats
}
```

Consumes: existing `ResearchCacheStore`, `SearchRouter`, `PageReader`,
`SearchQuotaStore`, `ResearchLedger`, `AIQuotaStore`, `AIChatQuota.tracked`.

## Tasks

### 1.1 Build the assembly

- [x] Create `ResearchServiceAssembly` with exactly the stored properties above.
  Initialize `cache = .shared`, `ledger = .shared`, `aiQuota = .shared`,
  `searchQuota = .shared`.
- [x] Construct the only production router:
  `SearchRouter(cache: cache, ledger: ledger, quota: searchQuota)`.
- [x] Construct `basePageReader = PageReader(cache: cache, isScrapeEnabled: true)`.
- [x] Implement `pageReader(isScrapeEnabled:)` as
  `PageReader(cache: cache, isScrapeEnabled: isScrapeEnabled)`. The direct
  reader is stateless; only the cache must be shared.
- [x] Comment: "Production SearchRouter/PageReader construction lives here.
  Tests may construct isolated instances."

### 1.2 Replace the four router and three page-reader sites

- [x] `AISearchServiceFactory`: replace the local `SearchRouter(quota: .shared)`
  and `PageReader(...)` with `ResearchServiceAssembly.shared.searchRouter` and
  `.pageReader(isScrapeEnabled: !firecrawlKey.isEmpty)`.
- [x] `PageSummaryEvidenceFactory`: same replacement; keep the local
  `SearchRouterConfiguration` built from settings/keys.
- [x] `NewsOrchestrator`: delete the `researchSearchRouter` stored property;
  use `ResearchServiceAssembly.shared.searchRouter` in `executeResearch`,
  `searchProviderStatuses` and `clearSearchAuthBlock`. Replace the page reader
  at `executeResearch` with
  `ResearchServiceAssembly.shared.pageReader(isScrapeEnabled: ...)`.
- [x] `ManualSearchGateway.init`: default argument becomes
  `router: SearchRouter = ResearchServiceAssembly.shared.searchRouter`.
- [x] `ResearchPipeline` construction in `executeResearch`: inject
  `AIChatClientFactory.unmetered(...)`; do not pass a `quota:` argument.
- [x] Build checkpoint: deferred to the single end-of-stage build (R3).

### 1.3 Add the client factory and fix quota ownership

- [x] Implement `AIChatClientFactory.unmetered` as `HTTPAIChatClient(...,
  quota: nil)` with the same defaults as `HTTPAIChatClient.init`.
- [x] Implement `AIChatClientFactory.metered` as `HTTPAIChatClient(...,
  quota: quota ?? .tracked(origin: origin, policy: policy, price: price))`.
- [x] Replace the custom `AIChatQuota` block in `AISearchServiceFactory` with
  `AIChatClientFactory.metered(origin: .aiSearch, policy: policy, price: price,
  quota: ...)`. Keep the preflight/assessment reservation closures unchanged;
  they are not part of the per-dispatch client quota.
- [x] Replace the PageSummary evidence client with `.metered(origin:
  .pageSummary, ...)`.
- [x] Audit `SelectionExplainModel` and `PageSummaryService`: they must keep a
  non-nil `AIChatQuota`. Do not change their prompt or validation logic.
- [x] Add a comment at the research pipeline construction: "ResearchPipeline
  owns `.research` reserve/settle; this client must stay unmetered."
- [x] Build checkpoint: deferred to the single end-of-stage build (R3).

### 1.4 Unify the cache key and cleanup

- [x] In `AISearchServiceFactory`, delete the hand-built key and the
  `SearchHitCache` read/write. Call the router with `useCache: true`,
  `maxAge: SearchHitCache.aiSearchMaxAge` (the 10-minute window it used before,
  R1) and pass the existing `ticket` unchanged.
- [x] Add `maxAge: TimeInterval?` to `ResearchCacheStore.load` and
  `SearchRouter.search`: it only shortens the effective TTL, never lengthens it,
  and reads the same file under the same epoch. `nil` keeps 12 h for research.
- [x] Add `SearchHitCache.clearAll()` that clears `entries` and `order`.
- [x] Implement `ResearchCacheCoordinator.clearAll()` in this order:
  1. Capture `let before = await cache.totalBytes()`.
  2. `await cache.clearAll()` (this bumps `writeGeneration`).
  3. `await SearchHitCache.shared.clearAll()`.
  4. Read `let epoch = await cache.writeEpoch()`, `let after = await
     cache.totalBytes()`, `let empty = await cache.isEmpty()`.
  5. Return `(epoch, max(0, before - after), empty)`. Do not bump the epoch a
     second time in the coordinator; one clear, one generation.
- [x] Implement `enforceLimits` as a thin call to
  `cache.enforceLimits(now:maxBytes:protecting:)`.
- [x] Do not change `ResearchCacheStore` TTLs or file layout.
- [x] Build checkpoint: deferred to the single end-of-stage build (R3).

### 1.5 Ticket and manual search

- [x] Confirm `SearchRouter` still consumes `SearchAttemptTicket` before
  `provider.search`; only cached hits bypass it. Do not move the consume point.
- [x] `ManualSearchGateway.search` uses the shared router and creates exactly
  one `SearchAttemptTicket(limit: 6)` per call. It must not create a second
  router or a `SearchQuotaStore`.
- [x] `QuickSearchContent` continues to hold one `ManualSearchGateway` for its
  lifetime. No view body may construct a router.
- [x] Add a short comment to `ManualSearchGateway`: shared router, shared
  quota/ledger, per-call ticket.
- [x] Build checkpoint: deferred to the single end-of-stage build (R3).

## Acceptance

- `grep -R` shows production `SearchRouter(` and `PageReader(` constructions
  only in `ResearchServiceAssembly` and test files.
- AI search and research hit the same cache file for an identical query and
  provider set; AI search still rejects anything older than 10 minutes (R1).
- Every cleanup entry (settings clear cache/all, clear-history, maintenance)
  runs through `ResearchCacheCoordinator`; one clear, one epoch (R2).
- `ResearchPipeline` receives `quota == nil`; AI search/page summary receive a
  metered client.
- `SearchHitCache` is cleared by the cache coordinator.
- Manual search uses the shared router/quota and a per-call ticket.
- Existing summaries, prompts and validators are unchanged.
- Private/blocked pages still bypass network and cache; `PublicURLPolicy` and
  `ReportValidator` are untouched. No UI code may pre-approve a URL.
- `swift build` passes.

## Handoff

Later stages import `ResearchServiceAssembly.shared` and
`AIChatClientFactory`. They must not add another router/page-reader/client
construction. Report the exact `swift build` result in `progress.md`.
