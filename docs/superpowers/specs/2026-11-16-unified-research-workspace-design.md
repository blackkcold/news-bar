# Unified Research Workspace — Design

**Date:** 2026-11-16
**Status:** Approved for implementation (user-approved full build)
**Branch:** `feat/unified-research-workspace`
**Target:** macOS 15, SwiftUI, Observation, Swift 5.9 concurrency

## 1. Goal

One research center that treats a **subject** (topic or event) as the long-lived
object, a **research run/report** as a versioned task, and **evidence** as a
shared, attributable resource. The reader, menu bar, notifications and the
research window all use the same local search, cache and task entry.

The window must feel like one product, not two old pages behind tabs. The
existing research and event stores remain authoritative for their own objects;
this feature adds a link/version layer and a new workspace UI.

Non-goals:

- No rewrite of the summary/translation systems.
- No new event AI step and no automatic promotion of monitoring to AI.
- No destructive migration of research or event files.
- No change to `ResearchOrigin` cases.
- No new network/background budget outside the existing RSS and search guards.

## 2. Product model

```
WorkspaceSubject (long-lived)
├── research record(s)  → run/report versions (tasks)
├── event(s)            → RSS tracking, claims, timeline
├── shared evidence     → research EvidenceItem + event NewsEventEvidence
└── local answer archive → historical Q&A, never evidence
```

- **Subject**: a topic or event the user can follow, archive, check for updates
  and research. It has one stable UUID and a set of lookup keys.
- **Research**: the existing `ResearchRecord` stays the task. Each successful
  report is archived as a `WorkspaceReportVersion`; `reportVersion` on the
  record remains the schema version and is not reused as a run counter.
- **Evidence**: research evidence and event evidence stay in their own stores.
  The detail view merges them for display, deduped by canonical URL plus quote,
  with provenance. No copy is written back into the other store.
- **Answer**: a lightweight AI answer is an answer, shown with an "unverified"
  label. It is indexed for local search but never enters evidence, claims or
  event ingestion.
- **Ordinary question**: a quick search/AI question does not create a subject
  or an event. Subject creation is explicit (new topic) or follows a real event
  or a completed research record.

## 3. UX

One window: `ResearchWorkspaceView` (1180×780, min 1040×680).

Sidebar filters, exact order:

| Filter | Rule |
|---|---|
| 全部 | `!isArchived` |
| 关注中 | `isFollowed && !isArchived` |
| 有更新 | `updateState == .hasUpdates && !isArchived` |
| 待核查 | `updateState == .needsReview && !isArchived` |
| 归档 | `isArchived` |

Counts are computed from the same predicate as the list. The list is a
two-column `NavigationSplitView` list + detail, following the existing
`ResearchCenterView` density, 11–13 pt text, SF Symbols, `.appThemeSurface()`
and the retro-editorial typography path.

Toolbar actions: `新主题`, `关注/取消关注`, `检查更新`, `开始研究/更新研究`,
`在阅读器打开` (when a URL exists), `归档/取消归档`. Header shows title,
aliases, last activity, update state and the two source metrics.

Detail has four segments (not old pages): `概览`, `时间线`, `证据`, `研究记录`.

- **概览**: event summary/claims (if any), latest research verdict/summary,
  pending updates, source metrics, next action.
- **时间线**: merged event + research timeline nodes, each labeled `事件` or
  `研究`; unknown dates render as `时间未知`, never guessed.
- **证据**: unified evidence rows with provenance, quote verification, stance,
  tier, publisher independence. Selecting a row opens the URL.
- **研究记录**: version list (V1…Vn), trigger, time, verdict, evidence count;
  current run progress; `开始研究` / `更新研究`; old versions read-only.

States: loading skeleton; empty (no subjects, no filter matches); error banner
with retry; no-RSS state for check updates; research running/queued/partial/
failed with the existing `ResearchStatusPresentation` language.

Keyboard: ⌘N new subject, ⌘F focus search, ⌘R check updates, ⌘↩ start/update
research, ⌘1–⌘5 filters, ⌘⌫ archive (with confirmation). ⌘K stays the reader
shortcut and opens the existing quick search, now with workspace sections.

## 4. Architecture

### 4.1 One long-lived service assembly

`Sources/NewsBar/Services/Research/ResearchServiceAssembly.swift`

```swift
final class ResearchServiceAssembly: Sendable {
    static let shared: ResearchServiceAssembly
    let cache: ResearchCacheStore          // ResearchCacheStore.shared
    let ledger: ResearchLedger             // ResearchLedger.shared
    let aiQuota: AIQuotaStore              // AIQuotaStore.shared
    let searchQuota: SearchQuotaStore      // SearchQuotaStore.shared
    let searchRouter: SearchRouter         // one router for all entries
    let basePageReader: PageReader         // shares cache/direct reader
    func pageReader(isScrapeEnabled: Bool) -> PageReader
}
```

Production router construction happens only here:
`SearchRouter(cache: cache, ledger: ledger, quota: searchQuota)`.
The four current sites become consumers:
`AISearchServiceFactory`, `PageSummaryEvidenceFactory`, `NewsOrchestrator`
and `ManualSearchGateway` (default argument becomes
`ResearchServiceAssembly.shared.searchRouter`). Page readers use
`pageReader(isScrapeEnabled:)` so `isScrapeEnabled` stays per-settings while
the cache and direct reader are shared.

### 4.2 Client factory and quota ownership

`Sources/NewsBar/Services/AI/AIChatClientFactory.swift`

```swift
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
```

Rules:

- `ResearchPipeline` is injected with `unmetered` (`quota == nil`); the
  pipeline's `callAI` remains the only `.research` reserve/settle path.
- AI search, page summary, selection explain and future workspace AI use
  `metered`; `AIQuotaStore` is the only budget source.
- A comment and an assertion on the research construction site state the
  invariant. No caller may wrap the research client in `AIChatQuota`.

### 4.3 Cache and ticket

- `SearchRouter.cacheKey(for:configuration:)` is the single cache key. It
  already covers query, recency, language, maxResults and provider set. AI
  search stops hand-building a key.
- AI search uses the router cache (`useCache: true`). `SearchHitCache` may stay
  as a short-lived memory layer, but it must take the router key and expose
  `clearAll()`.
- `ResearchCacheCoordinator` clears every layer and bumps the epoch once:
  `ResearchCacheStore.clearAll()` (bumps its generation), `SearchHitCache.clearAll()`,
  then returns `ResearchCacheClearReceipt(epoch, removedBytes, isComplete)`.
  In-flight writes carry the pre-clear epoch and are dropped by the store.
- `SearchAttemptTicket` stays inside `SearchRouter`, consumed before dispatch.
  `ManualSearchGateway` receives the shared router and its own ticket; it does
  not create a second router.
- Private pages: no network and no cache write; SSRF and quote validation stay
  in `PublicURLPolicy` / `ReportValidator`. UI never bypasses them.

### 4.4 Workspace domain layer

New folder `Sources/NewsBar/Services/Workspace/` and
`Sources/NewsBar/Models/ResearchWorkspace.swift`.

```swift
enum WorkspaceSubjectKind: String, Codable, Sendable { case topic, event, mixed }
enum WorkspaceUpdateState: String, Codable, Sendable { case current, hasUpdates, needsReview }
enum WorkspaceCheckOutcome: Codable, Hashable, Sendable {
    case notConfigured
    case checked(added: Int, at: Date)
    case throttled(until: Date)
    case failed(message: String, at: Date)
}
enum WorkspaceEvidenceOrigin: String, Codable, Sendable { case research, event }
enum WorkspaceEvidenceVerification: String, Codable, Sendable {
    case verifiedQuote, unverifiedQuote, snippetOnly
}
enum WorkspaceUpdateOrigin: String, Codable, Sendable { case rss, event, research }

struct WorkspaceSubject: Codable, Identifiable, Hashable, Sendable {
    let id: String                 // UUID, stable forever
    var title: String
    var aliases: [String]
    var kind: WorkspaceSubjectKind
    var createdAt: Date
    var updatedAt: Date
    var lastActivityAt: Date
    var isFollowed: Bool
    var isArchived: Bool
    var archivedAt: Date?
    var updateState: WorkspaceUpdateState
    var lastCheckedAt: Date?
    var lastCheckOutcome: WorkspaceCheckOutcome
    var pendingUpdateIDs: [String]
    var researchRecordIDs: [String]
    var eventIDs: [String]
    var lookupKeys: [String]       // "research:<id>", "event:<id>", "topic:<key>"
    var lastNotifiedAt: Date?
    var lastNotificationKind: WorkspaceNotificationKind?
    var schemaVersion: Int         // 1
}
```

`WorkspaceReportVersion`: `id = "\(recordID)#\(sequence)"`, `sequence`,
`recordID`, `subjectID`, `createdAt`, `trigger: ResearchOrigin`,
`report: BurstResearch`, `digest`. Cap at 20 per record; pruning never touches
the research record itself.

`WorkspaceUpdateCandidate`: `id` (digest of canonical URL + subject), subject,
title, url, source name, publishedAt, discoveredAt, origin (rss/event/research).

`WorkspaceEvidence`: display projection only; id is digest of canonical URL +
normalized quote; carries origin, verification, tier, independence, source
name, publishedAt.

`WorkspaceTimelineEntry`: id, occurredAt (optional), text, origin, evidenceIDs,
confidence. Merged deterministically by date, unknown dates last.

`WorkspaceSourceMetrics`:

```swift
struct WorkspaceSourceMetrics: Equatable, Sendable {
    var researchIndependentSourceCount: Int   // deduped canonical URL/syndication group, then domain
    var researchUniqueDomainCount: Int
    var notificationPublisherCount: Int       // NewsEventSourceResolver.countablePublisherCount
    var notificationEligible: Bool
    var basis: String                         // human-readable provenance, never a merged count
}
```

The UI always renders two labels: `研究独立来源 N` and `通知主体 M`. Never show a
single "N sources" number. Research metrics come from `EvidenceItem`; event
metrics come from `NewsEventSourceResolver`. Neither is recomputed from the
other store.

### 4.5 Stores and linking

`WorkspaceSubjectStore` is an actor at
`Sources/NewsBar/Services/Workspace/WorkspaceSubjectStore.swift`, writing
`~/Library/Application Support/com.newsbar.app/Research/workspace/workspace-v1.json`
and `.../report-versions/<recordID>.json`, using `PrivateFile.write(durable:)`.
`ResearchPaths` gains `workspaceDirectory` and `workspaceIndexFile` helpers.

`WorkspaceReconciler` builds subjects from `ResearchStore.index()` and
`NewsEventStore.events()` on bootstrap and on change notifications. Matching is
conservative and deterministic:

1. Join by an existing lookup key (`research:<id>`, `event:<id>`, `topic:<key>`).
2. Else join by exact normalized alias (`TopicFingerprint.normalized`).
3. Else create a new subject; `kind` is topic/event; a later exact match makes
   it `mixed`.
4. Never merge two event-backed subjects automatically; event↔research only.
5. Persist user state (follow/archive/update state). Never overwrite it from
   the source stores.

Existing record/event files are not rewritten. No `ResearchOrigin` case is
added. A record-level link, if ever needed, is optional and additive.

### 4.6 One task entry

`WorkspaceResearchLauncher` (@MainActor) is the only start/update entry for
the window, reader, popover and quick search.

```swift
struct WorkspaceResearchRequest: Sendable {
    var subjectID: String
    var depth: ResearchDepth
    var trigger: ResearchOrigin
    var forceRefresh: Bool
    var seed: ResearchSeed?
}
enum WorkspaceReuseReason: String, Sendable { case freshReport, unchangedEvidence, cacheWarm }
enum WorkspaceResearchFailure: String, Sendable {
    case subjectMissing, noAIKey, alreadyActive, unavailable, persistenceFailed
}
enum WorkspaceResearchAction: Equatable, Sendable {
    case started(recordID: String)
    case focusedRunning(recordID: String)
    case reused(recordID: String, reason: WorkspaceReuseReason)
    case failed(WorkspaceResearchFailure)
}
```

It coalesces concurrent calls per subject, resolves the latest record by
`topicKey`, reuses `ResearchRecordProvisioner.ensureRecord`, and delegates to
`ResearchCoordinator.schedule`. Reuse when the latest report is < 24 h old and
the evidence fingerprint is unchanged; `forceRefresh` bypasses reuse. Every
action reports the record so the UI can select the exact task.

### 4.7 Local-first search

`WorkspaceSearchIndex` (actor) persists `workspace/search-index-v1.json` and
indexes subjects, report text, evidence (research + event), and historical
answers. `WorkspaceSearchService` (@MainActor) exposes:

```swift
func searchLocal(_ text: String, scopes: WorkspaceSearchScope,
                 limit: Int) async -> WorkspaceSearchResponse
func searchWeb(_ text: String, language: AppLanguage,
               settings: AppSettings) async throws -> SearchBatch
```

`searchLocal` never touches the network. `searchWeb` is only called by an
explicit `在网页中查找` action and uses the shared router + gateway + ticket.
The workspace list uses the same service: a non-empty query shows grouped
`主题/报告/证据/历史问答` results; the web button is a separate action.
QuickSearch keeps `local|web|ai|archive`; local gains separate
`主题/报告/证据/历史问答` sections. An AI answer is displayed as
`AI 概览 · 未作为证据`, and only archive answers are indexed.

### 4.8 RSS-only update checks

`WorkspaceUpdateChecker` (@MainActor) uses `NewsEventRSSFetcher` and
`NewsEventTrackingBudget`, plus the existing `NewsEventStore` feed cursors.
It accepts only `.rss` sources, checks at most 8 subscribed feeds per action,
and writes a 10-minute throttle to the subject. Matching uses
`WorkspaceLeadMatcher`: normalized alias containment with a 4-character
minimum, no AI, no fuzzy merge across events. Results become
`WorkspaceUpdateCandidate`s and set `hasUpdates`; if a ready report predates
the candidate, set `needsReview`. No research starts automatically.

### 4.9 Automation and notifications

- `WorkspaceAutoDiscovery` observes `.researchRecordsChanged` and a new
  `.newsEventsChanged`. It links new records/events into subjects. It does not
  set `isFollowed`, does not enable AI and does not start research.
- `ResearchCoordinator` gains
  `setResultObservers(_ observers: [any ResearchResultObserving])` and a
  `setNotifier(_:)`. On final save it notifies observers with the new record
  and the pre-run snapshot.
- `WorkspaceResearchObserver` appends a report version, clears
  `pendingUpdateIDs` after a ready run, and never downgrades verification.
- `WorkspaceNotificationCoordinator` allows an event-progress notification at
  most once per subject per 6 h and suppresses a research-completion
  notification if an event notification for the same subject was sent in the
  last 30 min. Event progress wins; the research result is still visible in the
  workspace badge.
- Notification payloads keep `type`, `recordID`, `eventID` exactly. Add
  `subjectID` only. `NotificationClickRouter` is unchanged; `AppDelegate`
  reads `subjectID` when present and opens/selects the workspace subject.

## 5. Entry-point integration

- New `AppDelegate.openResearchWorkspace(subjectID:researchID:eventID:)`.
- `openResearchCenter(selecting:)` and `openNewsEventMonitor(eventID:)` become
  thin compatibility wrappers that open the same window and select the linked
  subject. Existing call sites and notification routes keep working.
- Dashboard/popover buttons keep their labels but open the workspace.
- Reader: ⌘K opens `QuickSearchContent` as today; local results include
  workspace sections. `ReaderResearchPanel` uses `WorkspaceResearchLauncher`
  so a selection and the window cannot create two runs.
- "在研究中心打开" on any quick-search result selects the subject/report.

## 6. Migration and compatibility

- No changes to `ResearchRecord`, `ResearchStore`, `NewsEvent` or
  `NewsEventStore` encoded shapes.
- The workspace index is separate and rebuildable. A missing/corrupt index
  triggers a full rebuild from existing stores; corrupt files are preserved
  and surfaced, never deleted.
- Old notification payloads route as before. Old research records without a
  subject are adopted on first reconcile. Old events are adopted the same way.
- Legacy `ResearchCenterView` / `EventMonitorCenterView` stay compiled during
  migration; they are no longer window roots once the workspace ships. Do not
  delete them until all entry points and notification routes are verified.
- Lightweight answers keep their own archive and never become evidence.

## 7. Failure behavior

| Failure | Behavior |
|---|---|
| Workspace index unreadable | rebuild in memory, show a non-blocking banner, keep source stores untouched |
| RSS budget exhausted | `throttled(until:)`, no request, explain in the subject header |
| No RSS sources | `notConfigured`; check button disabled with "仅支持 RSS 更新检查" |
| Search all providers fail | existing `SearchUnavailableError` surfaced; no fabricated evidence |
| AI quota exhausted | existing quota message; no partial report is marked verified |
| Research active for subject | `focusedRunning`, no second job |
| Private/blocked page | excluded before network/cache; UI shows why |
| Event notification suppressed | workspace still shows the update; no notification duplicate |

## 8. Acceptance

1. One window; sidebar has exactly 全部/关注中/有更新/待核查/归档.
2. Detail has exactly 概览/时间线/证据/研究记录; no old page is embedded as a tab.
3. New topic, follow toggle, RSS-only check updates, start/update research all
   work from the window and update the ledger.
4. Default search is local across topics/reports/evidence/answers; web search
   is explicit. ⌘K from the reader reaches the same local results.
5. One shared search router/cache/page-reader assembly; AI search and research
   share cache keys and epochs.
6. Research client is unmetered; every other AI client is metered; no double
   charge is possible by construction.
7. Research completion archives a version; a new RSS candidate marks the
   subject `待核查` and never auto-runs AI.
8. Notification payloads keep legacy IDs; one subject does not get a duplicate
   event + research alert within 30 min.
9. Existing research/event files decode and display without migration; old
   notification clicks still land on the right record/event.
10. Metrics show separate research independent sources and notification
    publisher subjects.

Verification policy: no baseline, no test execution, no independent reviews.
Run a necessary `swift build` after each stage; compile test targets only if a
source change requires it, never execute them. The main agent does one final
self-check.
