# Stage 4 — RSS Checks, Discovery, Notification Coordination

> Checkbox status (2026-11-16): `[x]` means the item was delivered in code and
> covered by the compile evidence in `stage-4-report.md`. Runtime UI/notification/network
> was not executed; those behaviors remain unverified.

> Depends on Stages 1–3. Read the design §4.8–§4.9 first.
> Do not add a second scheduler, a second window or a second research launcher.

## Rulings (Stage 4, recorded before code)

These amend the task list below where the original plan is now outdated. They
are authoritative for the implementation.

- **R1 — Do not re-implement the version layer.** `ResearchResultObserving`,
  `WorkspaceReportVersionObserver` and the coordinator hook already exist from
  Stage 2 and are wired. Stage 4 only appends a state/link observer. It must not
  redefine the protocol, append a second version, replace the built-in observer,
  or undo the archive-failure guard (a failed archive keeps the old report) or
  the "pending updates newer than run start" protection. The cache coordinator
  is already connected; do not add a second clear path.
- **R2 — RSS checks share the event tracker's budget instance.** `NewsEventTrackingBudget`
  contains the single-flight slot. Constructing another budget against the same
  store still lets two requests pass concurrently, so the checker must go
  through the controller/tracker that owns the one budget. A thin broker on
  `NewsEventController` exposes one feed check; it preserves conditional
  requests, shared cursors, failure backoff, and commits the cursor only after
  evidence is durably stored. Do not write a second fetch loop.
- **R3 — Check conservatively.** Only RSS sources enabled in
  `settings.activeSources` are eligible; disabled feeds are never fetched. One
  click checks at most one feed by default (8 is a ceiling, not a target). A
  recent successful shared check may be reused instead of spending budget again.
  A 304 is a successful check. The result carries actual coverage, budget used /
  limit, and the next eligible time. Budget, missing-source, partial, failure and
  retry times are shown honestly in the UI. Failure backoff is never bypassed.
- **R4 — Discovery is not notification-driven.** A followed, non-archived topic
  collects matching RSS leads during the existing news refresh when a feed
  actually changed. No new timer, no new network request, no new subject from a
  lead. Archived subjects stop collecting. Unfollowing stops collection.
- **R5 — Full reconcile supplies evidence URLs.** New event/research links pass
  `evidenceURLsByRecordID` plus the reconciler's explicit record/event IDs.
  New event evidence newer than the linked report's `generatedAt` marks the
  subject `needsReview`; it never launches AI. Event subjects still never merge
  by title when the subject is the same but the event time differs.
- **R6 — One launcher for every research trigger.** Legacy automatic, keyword
  and manual start paths all go through `WorkspaceResearchLauncher`. The master
  switch, triage, hourly start gate, `ResearchAutoAdmission`, queue limit and
  `isAllowed` remain in force. The request gains `notify`, `recordID`,
  `allowReuse` and `allowsIncremental` so manual runs keep their original
  notification intent and automatic runs follow the user's research-notification
  switch; the launcher must not hard-code `notify: true`.
- **R7 — No blanket 6-hour notification suppression.** Event progress and
  research completion are coordinated only when they are the same update/version
  for one subject. Event progress wins; a short delay lets it claim first. The
  30-minute window is a same-update dedupe window, not the only key. Claiming is
  serialized on the main actor; the event semantic key is claimed only after the
  workspace allows delivery. A workspace read failure fails open for unrelated
  notifications. Archived subjects suppress new notifications with an explicit
  explanation while keeping old evidence; unarchiving resumes them.
- **R8 — Lifecycle is idempotent.** `AppDelegate` injects the real checker and
  starts/stops automation with generation guards and a 2-second coalescing
  window. `researchWorkspaceChanged` never triggers a full reconcile by itself.
  Repeated identical input does not write. No timer or network request starts on
  launch.
- **R9 — Compatibility and copy.** Notification payloads keep `type`,
  `recordID`, `eventID`; `subjectID` is additive. `NotificationClickRouter`
  stays unchanged. Legacy clicks resolve the subject first and fall back to the
  record/event so they never open a blank window. The event-monitor entry opens
  the unified workspace. README/docs describe the new UX and state clearly that
  monitoring collects leads only and never starts AI by itself; a user-initiated
  research run is the explicit exception.

## Goal

Make the workspace live: manual RSS-only update checks, automatic subject
linking, report-version archiving, and cross-type notification coordination.
No automatic AI escalation, no new polling loop, no change to existing event
tracking semantics.

## Files

Create `Sources/NewsBar/Services/Workspace/`:

- `WorkspaceUpdateChecker.swift`
- `WorkspaceAutoDiscovery.swift`
- `WorkspaceResearchObserver.swift`
- `WorkspaceNotificationCoordinator.swift`
- `WorkspaceAutomationService.swift`

Modify:

- `Sources/NewsBar/Services/Research/ResearchCoordinator.swift:62-135,370-425`
- `Sources/NewsBar/Services/Events/NewsEventController.swift:330-370,800-830`
- `Sources/NewsBar/Services/Research/ResearchHistoryClearer.swift:40-55`
- `Sources/NewsBar/Views/Settings/ResearchDataSection.swift:300-325`
- `Sources/NewsBar/AppDelegate.swift` (start/stop automation, notifier, notification subject routing)
- `Sources/NewsBar/Models/ResearchWorkspace.swift` (only if a missing optional field is required; update the stage-2 doc too)

## Interfaces

```swift
struct WorkspaceUpdateCheckResult: Sendable, Equatable {
    var subject: WorkspaceSubject
    var added: [WorkspaceUpdateCandidate]
    var outcome: WorkspaceCheckOutcome
}

@MainActor
protocol WorkspaceUpdateChecking: AnyObject {
    func check(subjectID: String, sources: [NewsSource], now: Date) async
        -> WorkspaceUpdateCheckResult
}

@MainActor
final class WorkspaceUpdateChecker: WorkspaceUpdateChecking {
    static let shared: WorkspaceUpdateChecker
    init(fetcher: any NewsEventRSSFetching = NewsEventRSSFetcher(),
         budget: any NewsEventTrackingBudgeting =
            NewsEventTrackingBudget(store: NewsEventStore.shared),
         store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
         feedStore: any NewsEventPersisting = NewsEventStore.shared,
         matcher: WorkspaceLeadMatcher = WorkspaceLeadMatcher(),
         maxFeedsPerCheck: Int = 8,
         throttle: TimeInterval = 10 * 60)
    func check(subjectID: String, sources: [NewsSource], now: Date) async
        -> WorkspaceUpdateCheckResult
}

@MainActor
protocol ResearchResultObserving: AnyObject {
    func researchDidFinalize(_ record: ResearchRecord, previous: ResearchRecord) async
}

@MainActor
final class WorkspaceResearchObserver: ResearchResultObserving {
    static let shared: WorkspaceResearchObserver
    init(store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
         researchStore: any ResearchPersisting = ResearchStore.shared)
}

@MainActor
final class WorkspaceNotificationCoordinator {
    static let shared: WorkspaceNotificationCoordinator
    init(store: any WorkspacePersisting = WorkspaceSubjectStore.shared)
    func subjectID(forRecordID id: String) async -> String?
    func subjectID(forEventID id: String) async -> String?
    func claimResearch(recordID: String, at: Date) async -> Bool
    func claimEvent(eventID: String, at: Date) async -> Bool
    func reset()
}

@MainActor
final class WorkspaceAutoDiscovery {
    static let shared: WorkspaceAutoDiscovery
    init(store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
         researchStore: any ResearchPersisting = ResearchStore.shared,
         eventStore: any NewsEventPersisting = NewsEventStore.shared,
         reconciler: WorkspaceReconciler = WorkspaceReconciler())
    func fullReconcile(now: Date) async -> WorkspaceReconcileResult
    func ingestResearch(recordID: String, now: Date) async -> String?
    func ingestEvents(now: Date) async -> Set<String>
    func applyUpdateCandidates(_ candidates: [WorkspaceUpdateCandidate],
                               subjectID: String, now: Date) async
}

@MainActor
final class WorkspaceAutomationService {
    static let shared: WorkspaceAutomationService
    func start(orchestrator: NewsOrchestrator, settings: AppSettings)
    func stop()
}
```

Add to `WorkspacePersisting` (stage 2 file; keep the signature here):

```swift
func subject(containingResearchID id: String) async -> WorkspaceSubject?
func subject(containingEventID id: String) async -> WorkspaceSubject?
```

## Tasks

### 4.1 RSS-only update checker

- [x] `check` loads the subject; missing -> `.failed("主题不存在")` with
  `.notConfigured` outcome only for an unknown subject? Use `.failed` for a
  missing subject and `.notConfigured` for a real subject with no RSS sources.
- [x] Throttle: if `lastCheckedAt` is within `throttle`, return
  `.throttled(until: lastCheckedAt + throttle)` without a request.
- [x] Filter `sources` with `guard case .rss = source`; take at most
  `maxFeedsPerCheck`; dedupe by `source.id`. Never call a search provider.
- [x] For each source: `budget.acquire(now:)`; on false return
  `.throttled(until:)`; `defer { Task { await budget.release() } }` or release
  explicitly before return. Use `feedStore.feedCursor(for:)` and save the
  returned cursor for both `.modified` and `.notModified`.
- [x] Convert `NewsEventEvidence` to `WorkspaceUpdateCandidate` with origin
  `.rss`; match with `WorkspaceLeadMatcher.matches(title:summary:aliases:)`
  against the subject title/aliases. No AI, no fuzzy edit distance.
- [x] Dedupe candidates by id; save with `store.saveUpdates`; set
  `lastCheckedAt`, `lastCheckOutcome`, `updateState = .hasUpdates`. If a ready
  report's `report.generatedAt` is older than a candidate's published/discovered
  date, set `.needsReview` and add the candidate IDs to `pendingUpdateIDs`.
- [x] Return `.checked(added:)` even when zero matches; a successful 304 is a
  successful check. Return `.failed(message:at:)` on fetcher/store error, with
  the message already sanitized for UI.
- [x] Build checkpoint: `swift build`.

### 4.2 Auto discovery without AI escalation

- [x] Add `Notification.Name.newsEventsChanged` (in `NewsEventController.swift`).
  Post it after `events = Self.ordered(...)` in `ingestSerialized` and in the
  tracking result path, with `userInfo["eventIDs"] = changedIDs.sorted()`.
  Do not post on read-only reloads.
- [x] `fullReconcile`: load research index + events, call
  `WorkspaceReconciler`, save all subjects, return the result. Preserve all
  user state. Never create a research record and never call an AI client.
- [x] `ingestResearch(recordID:)`: resolve the record; reconcile; link it to a
  subject by exact topic key/alias; set `lastActivityAt`; do not set
  `isFollowed`; return the subject ID.
- [x] `ingestEvents(now:)`: load events, reconcile, link by event ID/alias; set
  `lastActivityAt`; do not enable event monitoring or research.
- [x] `applyUpdateCandidates`: append candidates, dedupe, update state as in
  4.1. Used by event deltas to mark a linked report `待核查`.
- [x] Event delta rule: if an event's new evidence is newer than the linked
  report's `generatedAt`, set `.needsReview`; never auto-run research.
- [x] Build checkpoint: `swift build`.

### 4.3 Report versions and research completion

- [x] Add `setResultObservers(_ observers: [any ResearchResultObserving])` and
  `setNotifier(_ notifier: @escaping @MainActor (ResearchRecord) -> Void)` to
  `ResearchCoordinator`. Keep the existing defaults so current call sites work.
- [x] In the final-save path, capture `let previous = current` before any status
  mutation, then after `store.save(current)`:
  `for observer in resultObservers { await observer.researchDidFinalize(current, previous: previous) }`
  before the existing `eventResultIngestor`/notifier calls. The order is
  intentional: the version exists before the event ingests research evidence,
  and the research notifier runs after event progress has had a chance to
  claim the subject.
- [x] `WorkspaceResearchObserver.researchDidFinalize`:
  - resolve/link the subject;
  - if `record.report != nil`, append a `WorkspaceReportVersion` with
    `sequence = (await store.versions(recordID:).last?.sequence ?? 0) + 1`,
    `digest` from summary + evidence canonical URLs + generatedAt; skip an
    identical tail digest;
  - on `.ready`, clear `pendingUpdateIDs` and set `updateState = .current`;
  - on `.partial/.failed`, keep `needsReview` and do not append an empty report;
  - never call `NewsEventController.ingest` here; the coordinator already does.
- [x] Backfill: during `fullReconcile`, for each linked record with a report and
  no stored versions, append the current report as sequence 1 with digest and
  `trigger = record.run.origin`. This makes existing records visible as V1
  without changing the record file.
- [x] Register the observer in `WorkspaceAutomationService.start`.
- [x] Build checkpoint: `swift build`.

### 4.4 Notification coordination

- [x] `WorkspaceNotificationCoordinator.claimResearch(recordID:at:)`:
  resolve subject; if missing allow; deny if the last notification is
  `.eventProgress` within 30 minutes, or `.researchCompleted` within 10
  minutes; otherwise save `lastNotifiedAt=at`, `lastNotificationKind=
  .researchCompleted` and allow.
- [x] `claimEvent(eventID:at:)`: resolve subject; deny if the same kind was
  sent within 6 hours; otherwise save and allow. Event progress always wins
  over research completion.
- [x] `NewsEventController.sendIfAllowed`: before
  `NotificationService.sendNewsEventAlert`, resolve
  `let subjectID = await WorkspaceNotificationCoordinator.shared
  .subjectID(forEventID: event.id)` and call
  `await WorkspaceNotificationCoordinator.shared.claimEvent(eventID: event.id,
  at: now)`. If false, set `event.notificationMessage` to a suppression note,
  persist it, and do not send. If true, pass `subjectID` to
  `sendNewsEventAlert(_:subjectID:)`.
- [x] Research notifier wrapper in `WorkspaceAutomationService.start`:
  `coordinator.setNotifier { record in
     Task { @MainActor in
       guard await WorkspaceNotificationCoordinator.shared.claimResearch(
         recordID: record.id, at: Date()) else { return }
       let subjectID = await WorkspaceNotificationCoordinator.shared
         .subjectID(forRecordID: record.id)
       NotificationService.sendResearchNotification(record: record,
         subjectID: subjectID)
     }
   }`
- [x] Add optional `subjectID` parameters with `nil` defaults to
  `NotificationService.sendNewsEventAlert(_:subjectID:)` and
  `sendResearchNotification(record:subjectID:)`. The claim already persists
  `lastNotifiedAt`, so no extra note method is needed.
- [x] Keep `type`, `recordID`, `eventID` exactly as today. Add `subjectID` to
  both `NotificationService` payloads. Do not change `NotificationClickRouter`.
- [x] In `AppDelegate`, read `userInfo["subjectID"]` when handling a
  notification and pass it to `openResearchWorkspace(subjectID:...)` in
  addition to the existing record/event route. If absent, resolve from the
  record/event as today.
- [x] Build checkpoint: `swift build`.

### 4.5 Cache cleanup and lifecycle

- [x] Replace `ResearchCacheStore.shared.clearAll()` in
  `ResearchDataSection.swift:304,313` with
  `await ResearchCacheCoordinator.clearAll()`; show the returned receipt
  (removed bytes + completeness) in the existing confirmation.
- [x] `ResearchHistoryClearer`: inject or call the coordinator for its cache
  step so history clear also drops the memory layer and preserves the epoch
  guard. Keep its staged intent state machine and receipts unchanged otherwise.
- [x] `WorkspaceAutomationService.start(orchestrator:settings:)`:
  - call `fullReconcile` once;
  - after reconcile/ingest, call `await orchestrator.refreshResearchSummary()`
    so the popover badge stays in sync;
  - set coordinator observers/notifier once;  - observe `.researchRecordsChanged`, `.newsEventsChanged`,
    `.researchWorkspaceChanged` with a 2-second coalescing task;
  - on `.researchRecordsChanged` with `recordID`, call
    `ingestResearch(recordID:)`; without one, schedule a full reconcile;
  - on `.newsEventsChanged`, call `ingestEvents(now:)`;
  - never start a timer or a network request on launch.
- [x] `stop()` removes observers/tasks and is safe to call twice. Call it from
  app termination if the app has a clean shutdown hook; otherwise leave it
  idempotent.
- [x] In `AppDelegate.applicationDidFinishLaunching`, after
  `settings = AppSettings()`, start the service with a guard:
  `Task { @MainActor in guard let orchestrator else { return };
  WorkspaceAutomationService.shared.start(orchestrator: orchestrator, settings: settings) }`.
  Do not start it before settings exists.
- [x] In `AppDelegate.openResearchWorkspace`, pass
  `updateChecker: WorkspaceUpdateChecker.shared` so the check button is live.
  Stage 3's `nil` default remains for previews/tests.
- [x] Build checkpoint: `swift build`.

### 4.6 Final integration pass

- [x] Grep for production `SearchRouter(`, `PageReader(`, `HTTPAIChatClient(`,
  `ResearchCacheStore()`, `ManualSearchGateway()`; every construction must be
  the assembly/factory or a test. Document any intentional exception.
- [x] Grep for `openResearchCenter`, `openNewsEventMonitor`; every call opens
  the workspace. Old views remain compiled but unreferenced by AppDelegate.
- [x] Verify notification payloads still contain `type`, `recordID`/`eventID`;
  `subjectID` is additive.
- [x] Verify `ResearchOrigin` still has exactly four cases and no store schema
  file changed.
- [x] Verify the four detail segments and five sidebar filters match the
  design; verify metrics labels are separate.
- [x] Run `swift build`. Record the exact result in `progress.md`.
- [x] Do not run tests, the app or business APIs. Do not commit/push.

## Acceptance

- Manual `检查更新` performs only RSS conditional requests, respects the
  rolling-hour budget and shared cursors, and never calls AI.
- A new RSS item marks the subject `有更新`; if a ready report is older, it also
  marks `待核查`.
- Auto discovery links new events/research without following, researching or
  enabling AI.
- Every successful research run appends exactly one version; duplicate
  finalizes do not duplicate a version.
- A ready research run clears `待核查`; a failed/partial run keeps it.
- Event-progress and research-completion notifications do not duplicate for
  one subject within 30 minutes; event wins.
- Legacy notification clicks still land on the correct record/event and now
  open the workspace.
- All cache-clear paths use the coordinator and report completeness.
- `swift build` passes.

## Handoff

This is the last stage. Update `progress.md` with each stage's build result and
the final self-check notes. Do not claim manual UX validation that was not
performed.
