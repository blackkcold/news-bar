# Unified Research Workspace — Implementation Plan

> **For agentic workers:** This is the plan index. Implement stage by stage in
> order. Each stage has its own file under `docs/superpowers/plans/unified-research/`.
> Do not start a stage before its dependency is accepted. Steps use checkbox
> (`- [ ]`) syntax for tracking.

**Goal:** Replace the separate research center and event monitor with one
subject-centric workspace where research is a versioned task and evidence is
shared, without migrating or breaking the existing stores.

**Architecture:** A long-lived service assembly owns one search router/cache/
page-reader graph and one client factory. A new link/version layer joins
existing `ResearchRecord` and `NewsEvent` objects into `WorkspaceSubject`s.
A single SwiftUI workspace window and one task launcher serve every entry
point; RSS-only checks and notification coordination run on top.

**Tech Stack:** Swift 5.9, SwiftUI, Observation, actors, macOS 15. No new
dependencies.

**Spec:** `docs/superpowers/specs/2026-11-16-unified-research-workspace-design.md`
**Research facts:** `docs/superpowers/plans/unified-research/research-findings.md`

## Global Constraints

- Platform: macOS 15, `swift-tools-version:5.9`; do not use Swift 6-only APIs.
- No new package dependency, no app/network run during implementation.
- Do not change encoded shapes of `ResearchRecord`, `ResearchStore`,
  `NewsEvent` or `NewsEventStore`. The workspace index is separate.
- `ResearchOrigin` stays `burst|keyword|interest|manual`; never add an event
  case. New links are optional or live in the workspace index.
- `ResearchPipeline` receives a client with `quota == nil`; it is the only
  `.research` reserve/settle path. Every other AI client is metered through
  `AIQuotaStore`.
- One production `SearchRouter` construction
  (`ResearchServiceAssembly.shared`). Tests may construct their own.
- Search ticket is consumed inside `SearchRouter` before HTTP dispatch.
- Cache key must include query, recency, language, maxResults and the
  dispatchable provider set. Cleanup clears every layer and preserves the
  epoch race guard.
- Private pages never go to the network or cache; SSRF and citation checks
  stay in the existing validators.
- Preserve notification keys `type`, `recordID`, `eventID`; adding `subjectID`
  is allowed. Preserve old event/record click destinations.
- UI follows the existing theme: `.appThemeSurface()`,
  `.adaptiveColorScheme()`, `AppTheme.retroEditorial` typography, SF Symbols.
- No baseline run, no test execution, no independent review gate. Necessary
  `swift build` only. The main agent performs one final self-check.

## Review Focus (main agent self-check only)

These are the failure modes no stage test will execute; verify them by reading
the diff:

1. A second research run starts for the same subject from a different entry
   point (reader, notification, window).
2. An AI search or page-summary call is double-charged because it received a
   metered client on top of the pipeline's own reservation.
3. A cache clear leaves one layer (memory or disk) serving pre-clear data, or
   an in-flight write repopulates the cache after the clear.
4. An event progress notification and a research completion notification both
   fire for one subject within the coordination window.
5. A legacy notification payload (`type=research` or `type=newsEvent`) lands on
   the wrong object or is dropped after the window merge.
6. Research independent-source count and notification publisher count are
   accidentally flattened into one number.
7. A quick-search/AI answer is displayed as verified evidence or ingested into
   an event.
8. An RSS-only check bypasses `NewsEventTrackingBudget` or the shared cursors.

## Stage Map

| Stage | File | Depends on | Delivers |
|---|---|---|---|
| 1 | `stage-1-foundation.md` | — | service assembly, client factory, shared cache/keys, ticket wiring |
| 2 | `stage-2-domain.md` | Stage 1 | subject/version/evidence models, store, reconciler, launcher, local search |
| 3 | `stage-3-workspace.md` | Stage 2 | one window UI, reader ⌘K integration, legacy entry mapping |
| 4 | `stage-4-automation.md` | Stages 1–3 | RSS checks, auto discovery, notification coordination, lifecycle |

Stage 3 must not start until Stage 2's store and launcher compile and the main
agent accepts the domain interfaces. Stage 4 must not start until the workspace
window can open a subject, run research and show a version.

## Frozen Cross-Stage Interfaces

These names are used by later stages. Do not rename them without updating
every stage file:

- `ResearchServiceAssembly.shared`, `cache`, `searchRouter`,
  `pageReader(isScrapeEnabled:)`
- `AIChatClientFactory.unmetered(...)`, `.metered(...)`
- `ResearchCacheCoordinator.clearAll() -> ResearchCacheClearReceipt`
- `WorkspaceSubject`, `WorkspaceReportVersion`, `WorkspaceUpdateCandidate`,
  `WorkspaceEvidence`, `WorkspaceTimelineEntry`, `WorkspaceSourceMetrics`,
  `WorkspaceDetail`
- `WorkspacePersisting`, `WorkspaceSubjectStore.shared`
- `WorkspaceReconciler.reconcile(research:events:existing:now:)`
- `WorkspaceResearchLauncher.start(_:) -> WorkspaceResearchAction`
- `WorkspaceSearchService.searchLocal(...)`, `.searchWeb(...)`
- `WorkspaceUpdateChecker.check(subjectID:sources:now:)`
- `WorkspaceNotificationCoordinator.claim(subjectID:kind:at:)`
- `ResearchResultObserving.researchDidFinalize(_:previous:)`

## Verification Policy

- One `swift build` per stage, after all of the stage's code changes are in
  place. Do not rebuild after each small step.
- Do not run `swift test`; do not run the app or business APIs.
- If a test target must compile because of a source change, use
  `swift build --build-tests` and do not execute the test binary.
- If `swift build` fails for an unrelated pre-existing reason, record the exact
  error in `progress.md` and continue only when the error is clearly unrelated.
- No TDD gate, no independent reviewer dispatch. The main agent checks the
  final diff once.

## Final Acceptance

- One window, one sidebar with 全部/关注中/有更新/待核查/归档.
- Four detail segments: 概览/时间线/证据/研究记录.
- New topic, follow, RSS-only check, start/update research, archive all work.
- Local-first search covers topics/reports/evidence/answers; web search is an
  explicit action; reader ⌘K reaches the same results.
- Existing research/event records open unchanged; legacy notification clicks
  still land on the right object.
- Source metrics stay split; answers never become evidence; no auto AI upgrade
  from event discovery.
- `swift build` passes; `progress.md` is updated with the actual command and
  result.
