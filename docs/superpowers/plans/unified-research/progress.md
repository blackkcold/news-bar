# Unified Research Workspace — Progress Ledger

**Branch:** `feat/unified-research-workspace`
**Worktree:** `/Users/11169285/.local/share/opencode/worktree/2c2cb18db9ec202ac5ec607efad1feaa54f77c57/unified-research-workspace`
**Spec:** `docs/superpowers/specs/2026-11-16-unified-research-workspace-design.md`
**Plan index:** `docs/superpowers/plans/2026-11-16-unified-research-workspace.md`

## Current state

| Item | State |
|---|---|
| Design + stage plans | Documentation landed; product code unchanged |
| Stage 1 foundation | Code landed; `swift build` passed twice (exit 0). See `stage-1-report.md`. No tests run. |
| Stage 2 domain | Code landed; final `swift build` exit 0. See `stage-2-report.md`. No tests run. |
| Stage 3 workspace UI | Code landed; final `swift build` exit 0. See `stage-3-report.md`. No tests run. |
| Stage 4 automation | Code landed; final `swift build` exit 0. See `stage-4-report.md`. No tests run. |
| Final self-check | Code/build self-check done; runtime UI/notification/network not run. See `completion-report.md`. |

This ledger records only what is actually true. Do not mark a stage complete
until its code exists and its build checkpoint has run.

## Stage dependencies

```
Stage 1 (assembly/clients/cache)
   └── Stage 2 (subjects/versions/launcher/search)
          └── Stage 3 (one window + reader ⌘K)
                 └── Stage 4 (RSS check/discovery/notifications)
```

- Do not start Stage 2 before Stage 1 compiles.
- Do not start Stage 3 before Stage 2's store and launcher compile.
- Do not start Stage 4 before the window can open a subject, run research and
  show a version.
- Within a stage, tasks are ordered; build checkpoints are mandatory.

## Execution policy (user-approved)

The user approved full development and does not want another confirmation gate.
Implementers should start the next task when the previous build checkpoint
passes. Do not ask for plan approval again.

- **No baseline run.** Do not spend time measuring the old behavior.
- **No test execution.** Do not run `swift test`, the app, or business APIs.
- **No independent review gate.** Subagents implement; the main agent does one
  final self-check. Do not dispatch reviewers or wait for stage approval.
- **Verification:** a necessary `swift build` after each stage. If a test target
  must compile, use `swift build --build-tests` and do not execute it.
- **No commit/push/release** by implementers unless the main agent explicitly
  asks. No installs, no app launch, no network calls for implementation.
- **No destructive migration.** Existing research/event files are read and
  displayed as-is. The workspace index is separate and rebuildable.

## Locked decisions

- One window, one launcher, one search assembly, one client factory.
- `ResearchOrigin` stays `burst|keyword|interest|manual`; no new case.
- Research client is unmetered; the pipeline owns `.research` reserve/settle.
- Every other AI client is metered through `AIQuotaStore`.
- One production `SearchRouter`; cache key includes query/recency/language/
  maxResults/provider set; cache clear bumps epoch and clears all layers.
- A lightweight AI answer is never evidence and never creates an event.
- A normal question does not create a subject.
- Public-source metrics keep `研究独立来源` and `通知主体` separate.
- Event discovery never auto-enables AI research or monitoring.
- Notifications keep legacy `type`/`recordID`/`eventID`; `subjectID` is additive.
- Old `ResearchCenterView`/`EventMonitorCenterView` stay compiled during this
  work but are no longer window roots.

## Stage 1 rulings (2026-11-16, before code)

Recorded before implementation, per the user's instruction that each stage's
rulings land first. They amend `stage-1-foundation.md`, whose Rulings section is
authoritative.

- **R1 freshness before sharing.** One cache store/key/epoch, but AI search
  keeps a 10-minute acceptance window through `maxAge`; research keeps 12 h;
  the page overview stays always-fresh. No second uncleaned cache layer.
- **R2 one cleanup path.** Settings clear (cache/all), clear-history and
  maintenance all call `ResearchCacheCoordinator`; one clear bumps one epoch and
  cannot be repopulated by an in-flight write.
- **R3 one build.** All stage-1 edits land, then exactly one `swift build`. No
  per-step compiles, no app/test/baseline/API run.
- **R4 one factory, N behaviors.** `AIChatClientFactory` covers research/triage,
  AI search, assessment, selection and page overview; per-entry timeout,
  thinking, DeepSeek and preflight semantics are preserved. Research stays
  unmetered because `ResearchPipeline` owns the `.research` reserve/settle.
- **R5 search state.** One shared router means a session 403 is still
  "this pass only"; a cached auth rejection must not survive a key/provider
  change.

## Stage 3 rulings (2026-11-16, before code)

Recorded before implementation so the UX decisions cannot drift while coding.
`stage-3-workspace.md` `## Rulings (Stage 3)` is authoritative; this is the
ledger summary.

- **R1** one integrated subject canvas; five filters unchanged; 1180×780 /
  minimum 1040×680 with sidebar 220 + list 300 + detail ≥480; toolbar overflow
  instead of truncation; existing retro-editorial/light/dark typography, no
  giant empty or marketing-coloured cards.
- **R2** latest and historical reports stay fully readable (summary, overview,
  claims, verdict, conflicts, missing, limitations, verbatim quotes, citations),
  copy Markdown and cancel active run retained; origins are meta only; evidence
  merges without losing provenance; 研究独立来源 and 通知主体 never merge.
- **R3** segment, per-segment scroll and chosen version survive tab switches and
  background refreshes; record deep links open that record/version, event links
  open the subject.
- **R4** 200 ms debounced local search first; explicit web button only; web hits
  are unverified leads, never evidence; archived Q&A replays the full answer.
- **R5** every entry opens `openResearchWorkspace`; dashboard duplicate centre
  entry removed visually with callbacks kept; settings event action maps to the
  unified workspace; old views compiled but not roots.
- **R6** one launcher for all manual research after consent; in-flight dedupe is
  the launcher map, not a disabled button; no second `startManualResearch`.
- **R7** new topic stores optional `seedURL` on `WorkspaceSubject` (no change to
  Record/Event encoded shape), never starts AI, never invents a Weibo URL.
- **R8** RSS first check enabled when sources exist; nil stage-4 checker shown as
  pending with a live injection point; hasUpdates also prompts update; missing
  key/consent gives guidance instead of empty records; depth menu is real.
- **R9** revision guards for search and detail; one index build + coalesced
  updates, no per-key rebuild; no notification→saveAll loop; heavy work off main.
- **R10** explicit empty/error/private/busy/read-only states; arrow keys cannot
  steal text cursors; ⌘N/⌘F/⌘1–5/Escape and archive confirm/undo; stable IDs,
  accessibility labels, Reduce Motion; no automatic Liquid Glass.

## Stage 4 rulings (2026-11-16, before code)

Recorded before implementation. `stage-4-automation.md` `## Rulings (Stage 4)`
is authoritative; this is the ledger summary.

- **R1** Stage 2 already owns versions: no protocol redefinition, no second
  append, no replacement of the built-in observer. Archive failure still keeps
  the old report; updates newer than run start stay pending. Cache cleanup is
  already wired and is not duplicated.
- **R2** RSS checks go through the event tracker's single budget/single-flight
  slot, not a new `NewsEventTrackingBudget`. Conditional requests, shared
  cursors, failure backoff and "commit cursor only after durable evidence" are
  preserved. One feed per click by default; a recent shared check may be reused.
- **R3** Only enabled RSS sources are checked; 304 is success; coverage, budget,
  next eligible time, partial coverage and retry times are surfaced honestly.
- **R4** Followed, non-archived topics collect matching leads during the normal
  RSS refresh. No timer, no extra network, no automatic subject creation;
  archive/unfollow stop collection.
- **R5** Full reconcile passes `evidenceURLsByRecordID` and explicit IDs. New
  event evidence newer than the report marks `needsReview`; no auto AI. Event
  subjects are not merged by title across different times.
- **R6** Every research trigger goes through `WorkspaceResearchLauncher` while
  keeping the master switch, triage, hourly gate, admission, queue limit and
  `isAllowed`. `notify`/`recordID`/`allowReuse`/`allowsIncremental` keep manual
  and automatic intent distinct; no hard-coded `notify: true`.
- **R7** No blanket 6-hour same-kind suppression. Coordinate only the same
  subject/update/report version; event wins; claims are serialized; event keys
  are claimed only after workspace delivery is allowed; workspace read failure
  fails open; archived subjects suppress with an explanation and keep evidence.
- **R8** Idempotent automation start/stop, 2-second coalescing, generation
  guards, no reconcile from `researchWorkspaceChanged`, no launch-time network.
- **R9** Legacy notification keys/routes stay; `subjectID` is additive. Legacy
  clicks resolve the subject and fall back to record/event. The event-monitor
  entry opens the workspace; docs state monitoring never starts AI by itself.

## Stage 3 final rulings U1–U3 (2026-11-16, before code)

- **U1** session-only presentation cache keyed by canonical subject ID: segment,
  selected version, depth, per-segment scroll anchor; A→B→A restores; background
  refresh does not reset tab/scroll; new versions never steal a historical
  version; explicit "view latest" only; retired IDs migrate their state; only
  the current subject's panes mount.
- **U2** evidence search results carry canonical URL + quote hint through
  AppDelegate/model to the evidence pane, scroll to the real matching row and
  highlight briefly; no match -> explicit notice; report -> specific record;
  answer -> archive replay only; read-only still read/search, writes disabled.
- **U3** whole header `ViewThatFits` (wide one row / narrow title full width +
  actions second row); no title squeeze or horizontal button overflow; metadata
  truncates with help; body 13/12 pt; `updateSubject` atomic writes, real checker,
  first-click/partial-coverage/budget copy preserved; themes/a11y unchanged; no
  Liquid Glass.

## Stage completion template

When a stage finishes, append one block:

```
### Stage N — [name]
- Build: `swift build` -> [passed/failed; exact error if failed]
- Files: <created/modified paths>
- Notes: <deviations from the stage doc; none is a valid value>
- Open issues: <only real blockers; do not list future work as done>
```

## Stage log

### Stage 1 — Foundation (assembly, clients, cache)

- Build: `swift build` -> **passed**, exit 0, `Build complete! (40.07s)`; after one
  semantic fix (`maxAge` must not delete a still-valid 12 h snapshot) a final
  incremental build -> **passed**, exit 0, `Build complete! (7.27s)`. Log:
  `.build/unified-research-stage1-build.log`. Zero errors; the ~958 warnings are
  pre-existing Swift 6 / actor-isolation warnings, none in the three new files.
- Files:
  - created `Sources/NewsBar/Services/Research/ResearchServiceAssembly.swift`,
    `Sources/NewsBar/Services/AI/AIChatClientFactory.swift`,
    `Sources/NewsBar/Services/Research/ResearchCacheCoordinator.swift`
  - modified `AISearch/AISearchServiceFactory.swift`,
    `AISearch/SearchHitCache.swift`, `NewsOrchestrator.swift`,
    `PageSummary/PageSummaryEvidenceProvider.swift`,
    `PageSummary/PageSummaryService.swift`,
    `Research/ResearchCacheStore.swift`, `Research/ResearchHistoryClearer.swift`,
    `Research/ResearchMaintenance.swift`, `Search/ManualSearchGateway.swift`,
    `Search/SearchRouter.swift`, `Views/Dashboard/SelectionExplainModel.swift`,
    `Views/Settings/ResearchDataSection.swift`
  - docs: `stage-1-report.md` (new), this ledger, `stage-1-foundation.md`,
    parent plan
- Notes (deviations): two `swift build` runs instead of one, explained above (the
  second was required to verify the `maxAge` fix; no per-task compiles). Factory
  and coordinator signatures are supersets of the frozen ones via defaulted
  parameters (`disableDeepSeekThinking`, `protectingSince`, `now`, `cache`).
  Page overview keeps `useCache: false` rather than gaining a shorter `maxAge`;
  that preserves its original freshness policy exactly.
- Open issues: none blocking. Watch item: one shared router means a 429 cooldown
  seen by AI search also pauses research for that provider (intended by the
  single-graph design; revisit only if UX demands per-entry cooldowns).

### Stage 2 — Domain (subjects, versions, launcher, local search)

- Build: final `swift build` -> **passed**, exit 0, `.build/unified-research-stage2-build.log`;
  one compile failure (compactMap tuple signature) was fixed, then successful
  builds after semantic fixes. No tests/app/network run.
- Files:
  - created `Sources/NewsBar/Models/ResearchWorkspace.swift`,
    `Sources/NewsBar/Services/Research/ResearchIncremental.swift`, and
    `Sources/NewsBar/Services/Workspace/`:
    `WorkspaceSubjectStore.swift`, `WorkspaceReconciler.swift`,
    `WorkspaceLeadMatcher.swift`, `WorkspaceDetailBuilder.swift`,
    `WorkspaceResearchLauncher.swift`, `WorkspaceSearchIndex.swift`,
    `WorkspaceSearchService.swift`, `WorkspaceReportVersionObserver.swift`
  - modified `Services/Research/ResearchStore.swift` (workspace paths only),
    `ResearchCoordinator.swift` (version hook/observers), `ResearchPipeline.swift`
    (incremental context), `ResearchHistoryClearer.swift` (workspace clear),
    `NewsOrchestrator.swift` (depth + incremental pickup),
    `Services/Search/PageReader.swift` (provider-free page request + cache read)
  - docs: `stage-2-domain.md` rulings/interfaces, this ledger,
    `stage-2-report.md`
- Notes: `appendVersion` owns sequence and digest dedupe; unsupported workspace
  index is read-only; corrupt index/version files are isolated, never deleted.
  Incremental context is process-local and expires after 10 minutes. Version
  observer is built into the coordinator and cannot be removed by stage 4.
  Hand-off fixes: a false `researchWillOverwrite` now keeps the previous report
  and marks the run failed; `forceRefresh` bypasses incremental context; reuse
  is capped by recency (max 24 h); topic-only records no longer invent a
  `https://s.weibo.com` seed.
- Open issues: stage 3 must call `ensureBaselineVersion`/load versions before
  detail display if it does not call `WorkspaceSearchService.reloadIndex()`;
  stage 4 must supply `evidenceURLsByRecordID` for report-evidence URL joins.

### Stage 3 — Workspace UI and entry points

- Build: final `swift build` -> **passed**, exit 0, `Build complete! (8.35s)`;
  first attempt failed with five `?? (await ...)` autoclosure errors plus one in
  `AppDelegate`, all fixed; two verification builds after semantic fixes also
  passed. Log: `.build/unified-research-stage3-build.log`. No tests/app/network.
- Files:
  - created `Sources/NewsBar/Views/Workspace/` (13):
    `ResearchWorkspaceModel.swift`, `ResearchWorkspaceView.swift`,
    `WorkspaceSidebar.swift`, `WorkspaceSubjectList.swift`,
    `WorkspaceSubjectRow.swift`, `WorkspaceDetailView.swift`,
    `WorkspaceOverviewPane.swift`, `WorkspaceTimelinePane.swift`,
    `WorkspaceEvidencePane.swift`, `WorkspaceResearchPane.swift`,
    `WorkspaceReportBody.swift`, `WorkspaceNewSubjectSheet.swift`,
    `WorkspaceActionNotice.swift`
  - modified `AppDelegate.swift`, `Models/ResearchWorkspace.swift`,
    `Services/Workspace/WorkspaceResearchLauncher.swift`,
    `Services/Workspace/WorkspaceSubjectStore.swift`,
    `Services/Events/NewsEventStore.swift`,
    `Views/Dashboard/{QuickSearchModel,QuickSearchContent,ReaderAuxiliaryRail,
    NewsReaderView,DashboardWindow,DashboardNewsroomBar}.swift`,
    `Views/MenuBar/BottomBar.swift`,
    `Views/Research/ResearchCenterView.swift` (legacy comment),
    `Views/EventMonitor/EventMonitorCenterView.swift` (legacy comment),
    `Models/Localized.swift`
  - docs: `stage-3-workspace.md` Rulings, this ledger, `stage-3-report.md`
- Notes: one workspace window is now the only root; dashboard/popover/settings/
  reader/burst/event/notification entries resolve into it. Dashboard and bottom
  bar lose the duplicate visible event entry while callbacks remain. The reader
  ⌘K gains four workspace result kinds with a 200 ms local-only fetch; the
  reader research panel keeps one online-check action. New-topic `seedURL` is
  additive optional metadata on `WorkspaceSubject`; old Record/Event encodings
  are untouched. RSS checker stays nil with an explicit pending state until
  stage 4 injects it.
- Open issues: no runtime UI verification (no app launch); first live run should
  check split-view compression at 1040 pt, retro segmented-control contrast and
  long-report scrolling. `WorkspaceSearchService` still rebuilds its index on
  the main actor, but only once/after coalesced store changes.
- Final same-stage acceptance U1–U3:
  - U1 added session-only `WorkspacePresentationStore` keyed by canonical
    subject ID (segment/version/depth/scroll anchor), canonical ID migration,
    per-subject scroll anchors with macOS 15 `scrollPosition(id:)`, and explicit
    `查看最新`; background refresh and new versions no longer steal the current
    tab/version/scroll. Only the current subject's panes mount.
  - U2 added `WorkspaceEvidenceFocus` through model + AppDelegate; evidence
    results scroll to and briefly highlight the real matching row (canonical URL
    then quote), with explicit notices for missing evidence/subject; report
    results open their record, answers only replay; read-only still read/search.
  - U3 rewrote the whole header as `ViewThatFits` (wide one-row with capped
    title block, narrow full-width title + second-row actions); metadata
    truncates with help. Follow/archive remain `updateSubject`; real checker,
    first-click, coverage and budget copy retained.
  - Build for this follow-up: `swift build --build-tests` -> **exit 0**
    (`43.08s`; warning-only cleanup `9.88s`; final layout/location cleanup `10.32s`; final depth cleanup `15.05s`; redirect merge `9.66s`).
    Log: `.build/unified-research-final-build.log`. Test targets were compiled,
    never executed. UI is not runtime-verified.


### Stage 4 — RSS checks, discovery, notification coordination

- Build: final `swift build` -> **passed**, exit 0, `Build complete! (9.41s)`
  after F1–F3, then `Build complete! (0.19s)` confirmation; an earlier attempt
  failed on one optional-record token unwrap, fixed. Log:
  `.build/unified-research-final-automation-build.log`. No tests/app/network.
- Files:
  - created `Sources/NewsBar/Services/Workspace/`:
    `WorkspaceUpdateChecker.swift`, `WorkspaceAutoDiscovery.swift`,
    `WorkspaceResearchObserver.swift`, `WorkspaceNotificationCoordinator.swift`,
    `WorkspaceAutomationService.swift`
  - modified `Services/Events/NewsEventTracker.swift`,
    `NewsEventController.swift`, `NotificationService.swift`,
    `NewsOrchestrator.swift`, `Workspace/WorkspaceResearchLauncher.swift`,
    `Models/ResearchWorkspace.swift`, `Workspace/WorkspaceSubjectStore.swift`,
    `Views/Workspace/ResearchWorkspaceModel.swift`,
    `WorkspaceOverviewPane.swift`, `WorkspaceDetailView.swift`,
    `WorkspaceSidebar.swift`, `AppDelegate.swift`, `Models/Localized.swift`,
    `README.md`, `README.zh-CN.md`, `docs/research-center*.md`
  - docs: `stage-4-automation.md` Rulings, this ledger, `stage-4-report.md`
- Notes: RSS checks go through the controller/tracker broker and therefore share
  the one `NewsEventTrackingBudget`/single-flight slot; no second budget or
  fetch loop. One feed per click by default, recent shared checks reuse, 304 is
  success, and the cursor commits only after leads and event evidence are
  durable. Followed non-archived topics collect leads from changed RSS feeds
  during normal refresh. Full reconcile supplies report evidence URLs; event
  evidence newer than a ready report marks `needsReview` without AI. The
  built-in version observer was not replaced or duplicated. Automatic/keyword/
  manual research now share `WorkspaceResearchLauncher` while keeping admission,
  queue, hourly gate and `isAllowed`; automatic notifications follow
  `burstPushEnabled`, manual keep notify. Notification coordination is serialized
  and no longer blanket-suppresses six hours; event wins the same update,
  archived subjects suppress with a reason, and event semantic keys are claimed
  only after workspace authorization.
- Follow-up F1–F3: shared-check reuse now matches the same source's already
  persisted event evidence and saves current-subject leads without HTTP;
  candidate identity is subject+canonicalURL across web/RSS/checker, with store
  normalization/earliest-discovered preservation; only real 304/modified claims
  checked source coverage. The tracker holds the budget slot from fetch through
  controller evidence+cursor ack, returns pending to concurrent callers, and
  tick excludes pending sources; ack/cancel/failure release and stale pending
  expires. Research evidence carries a report-version causal token; event notices
  record it and suppress only the same report's research completion (manual or
  automatic), not unrelated progress by time.
- Open issues: no runtime UI/notification verification; manual RSS checks now
  also ingest event evidence (intentional shared-cursor protection) and can
  therefore produce event notifications per existing policy; large-library
  full-reconcile cost and concurrent store-snapshot races are not load-tested.

## Final-domain fixes (same Stage 2, before delivery)

F1–F5 are recorded in `stage-2-domain.md` R17–R21 and implemented in the same
tree. No new stage, no baseline, no runtime test.

- F1 store writes: durable write first, then memory/epoch/notification; failed
  version/state writes do not poison caches; clear propagates deletion errors.
- F2 atomic `updateSubject` + revision-protected snapshot merge; feature call
  sites migrated.
- F3 force refresh bypasses search hit cache as well as page cache.
- F4 search index revision/coalesced reload + archive notification; stale
  rebuild cannot commit after clear.
- F5 reuse signature includes endpoint identity/effective model; fingerprint
  excludes self-derived research event evidence and counts only pre-run external
  input.
- F6 canonical subject integration: explicit `research:<recordID>:` event
  evidence merges research/event subjects, persists `subject:<retiredID>`
  redirects, resolves old `subject(id:)`, preserves archive/follow/check state,
  and refuses URL-only event-to-event merges. `changedIDs` diffs the initial
  snapshot.
- Build: `swift build` -> **passed**, exit 0, `.build/unified-research-final-domain-build.log`.
- New shared APIs: `WorkspacePersisting.updateSubject(id:mutation:)`,
  `WorkspaceSearchService.markDirty()`, `WorkspaceSearchIndex.beginRebuild()`/
  `rebuild(...generation:)`/`reset()`, `ResearchReuseSignature.endpointIdentity`/
  `providerIdentity`.

## Final self-check (main agent, once)

> Status: code/build self-check completed. `[x]` means the item is wired in code
> and covered by the final `swift build --build-tests` (EXIT=0) or a static grep;
> it does **not** mean runtime UI/notification/network was executed.

- [x] Final build: `swift build --build-tests` -> `Build complete! (9.66s)`,
  EXIT=0. App and test targets compiled; the test binary was never executed.
- [x] One window; five sidebar filters; four detail segments — code wired
  (`ResearchWorkspaceView`, `WorkspaceFilter`, `WorkspaceSegment`); UI not launched.
- [x] New topic, follow, RSS-only check, start/update research, archive — code
  wired (`ResearchWorkspaceModel`, `WorkspaceNewSubjectSheet`,
  `WorkspaceUpdateChecker`); not click-tested.
- [x] Reader ⌘K returns workspace topic/report/evidence/answer results; web
  search is explicit only — code wired (`QuickSearchContent`,
  `WorkspaceSearchService`); not runtime-searched.
- [x] Existing records/events and legacy notification clicks resolve without
  migration — code wired (`openResearchWorkspace` wrappers,
  `NotificationClickRouter` unchanged); not click-tested.
- [x] No second router/launcher/client construction — static grep/self-check.
- [x] Metrics labels remain separate; answers are never evidence — code/static
  check.
- [x] No test/baseline/review claim is made without evidence.
- [ ] Runtime verification (app launch, UI click, exact scroll/theme,
  notification delivery, real network/AI) — **Not Run** by user instruction.
