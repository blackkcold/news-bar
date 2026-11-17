# Unified Research Workspace — Code Findings

> Read this before any stage. It records the facts the design depends on.
> Do not re-run a full repository survey. Re-read only the file a task names.

## Workspace

- Repo root: `NewsBar` SwiftPM package, `swift-tools-version:5.9`, macOS 15.
- Branch: `feat/unified-research-workspace`.
- No new dependencies. Keep SwiftUI + Observation + actors.
- UI theme: `.appThemeSurface()`, `.adaptiveColorScheme()`, `AppTheme.retroEditorial`
  via `settings.appTheme`; follow the existing Research Center typography.

## Search and retrieval construction points

`SearchRouter` is constructed in four production places:

1. `Sources/NewsBar/Services/AISearch/AISearchServiceFactory.swift:43`
2. `Sources/NewsBar/Services/PageSummary/PageSummaryEvidenceProvider.swift:241`
3. `Sources/NewsBar/Services/NewsOrchestrator.swift:126` (`researchSearchRouter`)
4. `Sources/NewsBar/Services/Search/ManualSearchGateway.swift:9` (default argument)

`PageReader` is constructed in three places:

1. `AISearchServiceFactory.swift:45`
2. `PageSummaryEvidenceProvider.swift:243`
3. `NewsOrchestrator.swift:1423`

Each construction creates a new `ResearchCacheStore()` unless one is injected.
Consequence: search/page cache epochs and TTL are not shared between AI search,
page summary and research. `ResearchCacheStore.shared` exists but is not used
at those sites.

`SearchRouter.cacheKey(for:configuration:)` already includes normalized query,
recency, language, maxResults and the sorted dispatchable provider set. The AI
search path duplicates that key by hand in `AISearchServiceFactory` and then
uses `SearchHitCache` with `useCache: false` on the router. This is the cache
split to remove.

`SearchAttemptTicket` is consumed inside `SearchRouter` immediately before
`provider.search` (`SearchRouter.swift:168`), so cached hits and disabled
providers are free. `ManualSearchGateway` always creates its own ticket
(`limit: 6`) and its own default router; it has no `SearchQuotaStore`/ledger
unless a caller injects one.

## Quota and client injection

- `AIQuotaStore` (`Sources/NewsBar/Services/AIQuotaStore.swift`) is the global
  authoritative daily budget. `reserveTracked` returns a `Reservation`; only
  that handle can settle. `AIChatQuota.tracked(origin:policy:price:store:)`
  builds the production reserve/settle pair.
- `ResearchPipeline.callAI` (`ResearchPipeline.swift:142-197`) reserves and
  settles `.research` itself. Therefore the `HTTPAIChatClient` injected into
  `ResearchPipeline` MUST have `quota: nil`. Giving it a quota double-charges.
- `AISearchServiceFactory`, `PageSummaryEvidenceFactory` and other AI entry
  points create `HTTPAIChatClient` with a `quota:` closure; those are metered.
- `HTTPAIChatClient.init` accepts `quota: AIChatQuota? = nil`
  (`AIChatClient.swift:165`); `AIChatClienting` only needs `complete`, `stream`,
  `price`.

## Research domain

- `ResearchRecord` (`Models/ResearchRecord.swift`): `id`, `topicKey`,
  `ResearchOrigin` (`burst|keyword|interest|manual`), `topic`, `aliases`,
  `seed`, `status`, `report: BurstResearch?`, `run`, `reportVersion` (schema
  1/2, NOT a run counter), `isPinned`, `isRead`, `lastSeenAt`, `updatedAt`.
- `ResearchStore` (`Services/Research/ResearchStore.swift`) is an actor with a
  file-per-record store plus index projection. Do not migrate its files for
  this feature. `ResearchPaths` is the canonical path helper.
- `ResearchCoordinator` (`Services/Research/ResearchCoordinator.swift`) is
  `@MainActor`, serializes runs per record, owns status transitions, saves the
  final record, then calls `eventResultIngestor` and `notifier`. It has no
  result-observer hook today.
- `ResearchPipeline` writes a new `BurstResearch`; completion overwrites the
  previous successful report. There is no report-version archive.
- `ResearchRecordProvisioner.ensureRecord(for:origin:store:now:)` serializes
  creation per exact `topicKey`; manual records stay exact-only.
- `ResearchCenterModel` (`Views/Research/ResearchCenterModel.swift`) owns list,
  selection, read/pin/delete/retry. It listens to `.researchRecordsChanged`.
- Existing filters are origin-based (`all|unread|burst|keyword|interest|manual|
  failed|pinned`), not the requested lifecycle filters.

## Events

- `NewsEvent` (`Models/NewsEvent.swift`) has `evidence`, `claims`, `timeline`,
  `sourceGroups`, `countablePublisherCount`, `lifecycle`, `trackingStatus`,
  `lastNotifiedAt`, `notificationEligibility`. It has no user follow/archive
  flag and no AI/search step.
- `NewsEventStore` persists events and feed cursors (`feedCursor(for:)`,
  `saveFeedCursor`). `NewsEventRSSFetcher.refresh(source:cursor:now:)` only
  accepts `.rss` and returns conditional-refresh evidence.
- `NewsEventTracker.tick` uses `NewsEventTrackingBudget` with a single-flight
  rolling-hour limit. Any manual RSS check must use the same budget and the
  same feed cursors or it will bypass the guard.
- `NewsEventController` is `@MainActor @Observable`; `ingest(researchRecord:)`
  injects research evidence only after a ready record. It sends event alerts
  directly at `NewsEventController.swift:827`.
- `NewsEventInputAdapter.fromResearchRecord` maps report evidence/timeline into
  event evidence. Do not change this to accept draft/unverified answers.
- `NewsEventSourceResolver` produces `sourceGroups` and
  `countablePublisherCount`; reuse it for notification metrics. Do not derive a
  notification count from research evidence.

## Evidence and verification

- `EvidenceItem` (`Models/ResearchEvidence.swift`): `canonicalURL`, `domain`,
  `quote`, `quoteVerified`, `stance`, `tier`, `syndicationGroup`, `fetchedAt`.
- `EvidenceIdentity` is the single authority for quote identity; `ReportValidator`
  recomputes tiers and verification. Do not duplicate its rules in UI code.
- `AISearchArchiveEntry` stores lightweight AI answers. They are not verified
  research evidence and must stay in a separate answer scope.

## UI entry points

- `AppDelegate.openResearchCenter(selecting:)` (`AppDelegate.swift:1023`)
  creates `ResearchCenterView`.
- `AppDelegate.openNewsEventMonitor(eventID:)` (`AppDelegate.swift:1076`)
  creates `EventMonitorCenterView`.
- Reader: `NewsReaderView.swift:1228` owns `QuickSearchModel`;
  `:1311` hosts `ReaderResearchPanel`; `:1697` binds ⌘K to
  `toggleAuxiliarySearch()`. `QuickSearchContent` owns
  `@State private var webGateway = ManualSearchGateway()`.
- QuickSearch local results are `news | readerHistory | archive`; there is no
  topic/report/evidence scope.
- Notifications: `NotificationService.sendResearchNotification` uses
  `type=research`, `recordID`, `title`; `sendNewsEventAlert` uses
  `type=newsEvent`, `eventID`. `NotificationClickRouter` routes both. Preserve
  these keys exactly; adding `subjectID` is safe because the router ignores
  unknown keys.
- `NewsOrchestrator.executeResearch` builds `ResearchPipeline` with the shared
  `researchSearchRouter` and `researchCacheStore`, but the AI search and page
  summary factories build their own.

## User decisions already made

- Build the full feature, not a prototype or two old pages behind tabs.
- Each stage's design lands before its implementation.
- No baseline run, no test execution, no independent review gates.
- Verification is a necessary `swift build` after changes; test targets may be
  compiled only if needed, never executed.
- The main agent performs one final self-check.
- No destructive migration: keep existing research and event store formats.
- `ResearchOrigin` stays a strict enum; new links use optional fields or a
  separate link index, never a new case that old builds cannot decode.
- Public-source metrics keep two labels: research independent sources and
  notification publisher subjects. Never flatten them into one count.
- Lightweight AI answers stay; they never become verified evidence or events.
