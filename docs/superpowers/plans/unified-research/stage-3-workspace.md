# Stage 3 — Workspace UI and Entry Points

> Checkbox status (2026-11-16): `[x]` means the item was delivered in code and
> covered by the compile evidence in `stage-3-report.md`. Runtime UI/notification/network
> was not executed; those behaviors remain unverified.

> Depends on Stage 2. Read the design §3 and §5 first.
> This stage replaces the two window roots with one workspace. Do not embed
> `ResearchCenterView` or `EventMonitorCenterView` as tabs.

## Goal

Ship the single subject-centric window, all four detail segments, the new
topic/follow/check/start actions, and the reader ⌘K integration. Keep the old
views compiled for rollback, but no longer use them as window roots.

## Files

Create `Sources/NewsBar/Views/Workspace/`:

- `ResearchWorkspaceModel.swift`
- `ResearchWorkspaceView.swift`
- `WorkspaceSidebar.swift`
- `WorkspaceSubjectList.swift`
- `WorkspaceSubjectRow.swift`
- `WorkspaceDetailView.swift`
- `WorkspaceOverviewPane.swift`
- `WorkspaceTimelinePane.swift`
- `WorkspaceEvidencePane.swift`
- `WorkspaceResearchPane.swift`
- `WorkspaceNewSubjectSheet.swift`
- `WorkspaceActionNotice.swift`

Modify:

- `Sources/NewsBar/AppDelegate.swift:40-55,340-400,990-1110`
- `Sources/NewsBar/Views/Dashboard/QuickSearchModel.swift`
- `Sources/NewsBar/Views/Dashboard/QuickSearchContent.swift:90-210,400-420,500-590`
- `Sources/NewsBar/Views/Dashboard/ReaderAuxiliaryRail.swift:6-25,135-165`
- `Sources/NewsBar/Views/Dashboard/NewsReaderView.swift:1157-1185,1340-1370`
- `Sources/NewsBar/Models/Localized.swift` (zh + en keys)

## Interfaces

```swift
enum WorkspaceFilter: String, CaseIterable, Identifiable, Sendable {
    case all, following, updated, review, archived
    var titleKey: String { get }
    var symbol: String { get }
    func matches(_ subject: WorkspaceSubject) -> Bool
}

enum WorkspaceSort: String, CaseIterable, Identifiable, Sendable {
    case activity, created, title
}

@MainActor
@Observable
final class ResearchWorkspaceModel {
    var subjects: [WorkspaceSubject]
    var selectedSubjectID: String?
    var detail: WorkspaceDetail?
    var filter: WorkspaceFilter
    var sort: WorkspaceSort
    var searchText: String
    var searchResults: [WorkspaceSearchResult]
    var webResults: [SearchHit]
    var isSearchingWeb: Bool
    var isLoading: Bool
    var isCheckingUpdates: Bool
    var isStartingResearch: Bool
    var errorMessage: String?
    var actionNotice: WorkspaceActionNotice?

    init(orchestrator: NewsOrchestrator, settings: AppSettings,
         store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
         coordinator: ResearchCoordinator = .shared,
         eventController: NewsEventController? = nil,
         updateChecker: (any WorkspaceUpdateChecking)? = nil,
         launcher: WorkspaceResearchLauncher? = nil,
         search: WorkspaceSearchService? = nil)

    var visibleSubjects: [WorkspaceSubject] { get }
    func count(for filter: WorkspaceFilter) -> Int
    func load() async
    func refresh() async
    func select(_ id: String?) async
    func searchAll() async
    func searchWeb() async
    func openSearchResult(_ result: WorkspaceSearchResult) async
    func createSubject(title: String, aliases: [String], seedURL: String?) async -> String?
    func toggleFollow(id: String) async
    func setArchived(id: String, archived: Bool) async
    func checkUpdates(id: String) async
    func startResearch(id: String, forceRefresh: Bool) async
    func openRecord(id: String) async
    func openEvent(id: String) async
    func handleNotification(subjectID: String?, recordID: String?, eventID: String?) async
}
```

`WorkspaceActionNotice`: id, message, tone (info/error), subjectID, auto-dismiss.

`workspace.detail.segment` values: `overview|timeline|evidence|research` stored as
`@State` in the detail view, not the model.

## Rulings (Stage 3, recorded before code)

These are the product/UX decisions for this stage. They amend the task list
below; where they conflict, these rulings win.

- **R1 one subject canvas.** The sidebar filters and the subject list/detail are
  one integrated surface, not tabs over old pages. The five filters stay exactly
  `全部/关注中/有更新/待核查/归档`. Window 1180×780, minimum 1040×680; at the
  minimum width the sidebar is 220, the list 300 and the detail keeps ≥480
  without horizontal overflow. Toolbar actions that do not fit collapse into an
  overflow menu. Keep the existing retro-editorial and other themes, light/dark,
  the existing typography/density, precise SF Symbols and spacing. No oversized
  empty cards and no marketing-colour cards.
- **R2 reports stay readable.** The workspace report is not a summary card.
  Latest and historical versions both show the full summary, overview, claims,
  verdict, conflicts, missing items, limitations, verbatim quote evidence and
  traceable citations. Copy-as-Markdown and cancel-active-run stay available.
  Legacy `origin/burst/keyword` labels become meta text, never a second primary
  list. Event and research evidence share one display surface without losing
  provenance. Research-source and notification-publisher counts stay separate.
- **R3 state survives.** Switching detail segments, background refreshes and
  switching subjects keep the current selection, each segment's scroll offset
  and the chosen historical version. A deep-linked record opens that exact
  record (and its versions); a deep-linked event opens its subject.
- **R4 search is local by default.** Typing never touches the network. Local
  search covers subjects, report text, evidence and archived Q&A after a 200 ms
  debounce; the explicit `在网页中查找` button is the only web call. A web hit
  can be added to the current subject as an unverified lead or create a new
  subject; it is never report evidence. Archived answers replay their full
  document, not a URL or a placeholder.
- **R5 one entry.** Every entry opens `openResearchWorkspace`. The dashboard's
  two side-by-side centre buttons lose their visible duplicate while the
  callbacks stay source-compatible. The settings "打开事件工作台" action maps to
  the unified workspace and, where possible, the latest event subject. The
  research chip stays meaningful and points at unread research. Old views stay
  compiled but are no longer window roots.
- **R6 one research path.** Every manual research action goes through
  `WorkspaceResearchLauncher` after `ResearchConsent`. No UI/notification path
  calls `orchestrator.startManualResearch`. Dedupe is the launcher's shared
  in-flight map, not a disabled button.
- **R7 new topics are cheap.** The new-topic sheet takes title, optional aliases
  and an optional seed URL, creates a followed subject and never starts AI. The
  seed URL is persisted on `WorkspaceSubject` as compatible optional metadata
  (the old Record/Event encoded shapes are untouched) and becomes the real seed
  when research starts; no fabricated Weibo home URL.
- **R8 RSS check honesty.** With RSS sources configured the first check is
  clickable even when `lastCheckOutcome` is the default `.notConfigured`. A nil
  stage-4 checker is shown as "待配置" while the injection point stays live.
  Start/update/view states are derived from the record and `hasUpdates` also
  prompts an update (not only `needsReview`). Missing AI key/consent is an
  actionable guidance notice, never repeated failed empty records. The depth
  menu changes the real `request.depth`; force re-research is a full run.
- **R9 search and selection discipline.** Search input uses a 200 ms
  cancellation/debounce plus a revision guard so late results cannot overwrite a
  newer query; async detail loads also use a revision guard. The index is built
  once and refreshed on coalesced store notifications, never per keystroke and
  never by a full disk scan. A store notification → refresh → `saveAll` →
  notification loop is avoided by writing only when reconcile changed something
  and by ignoring self-writes. Heavy work stays off the main actor where the
  existing services already allow it.
- **R10 explicit states and keyboard.** Loading, no subjects, empty filter, no
  search result, private/blocked URL, error, busy and read-only store each have
  a visible state; an unsupported schema shows a read-only banner. Arrow keys
  never steal the search/form text cursor. ⌘N/⌘F/⌘1–5/Escape and archive with
  confirmation/undo work. `ForEach` uses stable IDs, rows expose one
  accessibility label, motion respects Reduce Motion. Liquid Glass is not added
  automatically.

## Final UX rulings U1–U3 (same-stage acceptance, before code)

These close the remaining continuous-reading and location gaps found in the
main agent's final self-check. They do not reopen earlier rulings.

- **U1 per-subject presentation state.** Session-only presentation state is
  cached by canonical subject ID: segment, selected report version, research
  depth, and a stable scroll anchor per segment. Switching subject A → B → A
  restores A's tab, version and scroll; background refreshes keep the current
  tab and position. A newly appended report version never replaces a historical
  version the user is reading; only an explicit `查看最新` (or a new deep link
  to a record) switches. State is never written to global memory. Redirected
  (retired) subject IDs migrate their presentation state to the canonical ID.
  Only the current subject's panes are mounted; no all-subject content mounting.
- **U2 search result location.** Evidence search results carry a canonical URL
  and quote hint through the model/AppDelegate to the evidence pane. After
  opening the subject and segment, the pane scrolls to the matching real
  evidence row and highlights it briefly; matching uses canonical URL first and
  the stored quote/snippet second, never an arbitrary first row. A missing or
  expired source shows an explicit notice instead of an empty pane. Report
  results open their specific record; answer results only replay the archive.
  Read-only workspaces can still read and search; mutating actions stay disabled.
- **U3 narrow header.** At 1040 pt the whole header (title block + actions) uses
  `ViewThatFits`: wide = one row with the text block keeping priority; narrow =
  title/meta full width and actions on a second row. Buttons never overflow
  horizontally and the title is never squeezed to a few characters. Secondary
  metadata truncates with help instead of expanding the row. Body text stays
  13/12 pt. Follow/archive keep the atomic `updateSubject` path; the real RSS
  checker, first-click availability, partial-coverage and budget copy stay.
  Existing paper/modern themes are unchanged; every icon action keeps an
  accessibility label; no Liquid Glass or new visual language.

## Tasks

### 3.1 Model and filters

- [x] Implement `WorkspaceFilter.matches` exactly:
  `all = !isArchived`, `following = isFollowed && !isArchived`,
  `updated = updateState == .hasUpdates && !isArchived`,
  `review = updateState == .needsReview && !isArchived`,
  `archived = isArchived`.
- [x] `load()` calls `store.bootstrap()`, refreshes the reconciler input from
  `ResearchStore.index()` and `NewsEventStore.events()`, saves reconciled
  subjects, then selects the remembered ID or the first visible subject.
- [x] Observe `.researchWorkspaceChanged`, `.researchRecordsChanged` and
  `.newsEventsChanged`; refresh counts and the selected detail. Coalesce with
  one pending task, no polling.
- [x] `select` loads `WorkspaceDetailBuilder` with the subject's latest event,
  latest research record, versions and updates. Marking read may use the
  existing record API, never a workspace write.
- [x] `createSubject` trims, rejects empty, calls
  `store.createSubject(title:aliases:isFollowed:now:)`, selects the result and
  returns the ID. It does not start research.
- [x] `searchAll` calls `WorkspaceSearchService.searchLocal` with `.all` and
  stores `searchResults`; `searchWeb` calls `searchWeb` with `settings` and
  stores `webResults`; both cancel the previous task. `openSearchResult` maps
  `.subject` to select, `.report` to select + open record, `.evidence` to select
  + evidence tab hint, `.answer` to the archive replay callback.
- [x] `toggleFollow` and `setArchived` save the subject and post the change.
- [x] `checkUpdates` builds `[NewsSource]` from
  `settings.rssSources.map { .rss(name: $0.name, url: $0.url) }` and calls the
  injected `WorkspaceUpdateChecking`. Empty sources -> `.notConfigured`. If the
  checker is nil, set `lastCheckOutcome = .notConfigured` and show the
  "仅支持 RSS 更新检查" hint; never fake a successful check.
- [x] `startResearch` calls `launcher.start` with the current depth/trigger and
  handles every `WorkspaceResearchAction`: select the record on `.started`/
  `.focusedRunning`/`.reused`, show an error notice on `.failed`.
- [x] Build checkpoint: `swift build`.

### 3.2 Window shell, sidebar, list

- [x] `ResearchWorkspaceView` is a `NavigationSplitView` with sidebar 220–260,
  list 300–360, detail filling the rest. Root frame `minWidth: 1040,
  minHeight: 680`; window default 1180×780. Apply `.adaptiveColorScheme()` and
  `.appThemeSurface()`.
- [x] Sidebar: product title/subtitle, five filter buttons with live counts,
  storage footer, and a `+` new-topic button. Use the existing
  `ResearchCenterView` selected-pill styling and retro paper background.
- [x] List: search field (`⌘F`), sort menu, one `WorkspaceSubjectRow` per
  subject. Row shows title, aliases (max 1), last activity, status dot for
  `待核查/有更新/研究中`, follow pin, and the two metric chips only in detail
  (not in the row).
- [x] Search behavior: empty query shows the filtered subject list. A non-empty
  query calls `WorkspaceSearchService.searchLocal(scopes: .all)` after a 200 ms
  debounce and replaces the list with four sections: `主题/报告/证据/历史问答`.
  Selecting a result opens the subject/report/evidence or archive replay. A
  footer button `在网页中查找` calls `searchWeb` explicitly and shows hits in a
  `网页结果` section; no network call happens while typing.
- [x] `searchAll` must not filter only subject titles; it must cover report
  text, evidence titles/quotes and archive Q&A. `openSearchResult` maps a
  subject/report/evidence result to the subject and, when present, the record;
  an answer result opens the archive replay only.
- [x] Empty states: no subjects -> "新建主题开始"; filter empty -> "此分类暂无
  主题"; search empty -> "没有匹配的主题".
- [x] Keyboard: ⌘1–⌘5 filters, ⌘N sheet, ⌘F focus, ↑/↓ selection, ⌘⌫ archive
  with confirmation.
- [x] Build checkpoint: `swift build`.

### 3.3 Header and 概览

- [x] `WorkspaceDetailView` owns a segmented picker with exactly
  `概览/时间线/证据/研究记录` (`.pickerStyle(.segmented)`).
- [x] Header: title, alias chips, kind badge (`主题/事件`), last activity,
  follow toggle, `检查更新`, primary `开始研究/更新研究/查看研究`, overflow
  `归档/取消归档` and `在阅读器打开`.
- [x] Primary action state:
  - no record -> `开始研究`;
  - active -> `研究中` + progress, disabled start;
  - ready and `updateState == .needsReview` -> `更新研究` with accent badge;
  - ready and current -> `查看研究` plus a secondary `重新研究`.
- [x] `检查更新` disabled when `lastCheckOutcome == .notConfigured`; tooltip
  "仅支持 RSS 更新检查"; while checking show a small `ProgressView`.
- [x] Overview: event summary/claims when an event exists; latest report
  summary/verdict when research exists; pending updates list with source/time;
  metrics row with `研究独立来源 N` and `通知主体 M` as two separate chips. Each
  chip has a tooltip explaining its basis; never merge the two numbers.
- [x] Never show a single combined source count. Never label an AI answer as
  evidence.
- [x] Build checkpoint: `swift build`.

### 3.4 时间线 and 证据

- [x] Timeline uses `WorkspaceTimelineEntry`, newest first, with provenance
  badge `事件`/`研究` and optional confidence. Unknown dates are grouped at the
  bottom as `时间未知`; no invented date.
- [x] Evidence rows show title, source, published date, origin badge, quote
  verification badge (`引文已核`/`引文未核`/`摘要来源`), stance and tier when
  present. `sharedWithEvent` renders a small link icon with tooltip.
- [x] Empty evidence: "这项研究还没有可引用的证据" + link to the report.
- [x] Evidence row click opens the URL through
  `ReaderNavigationPolicy.allowedURL`; a blocked URL is not opened and shows a
  notice.
- [x] Build checkpoint: `swift build`.

### 3.5 研究记录

- [x] Show current run state: `ResearchStatusPresentation` label, phase,
  queries/pages/AI counts, last error, cancel button while active.
- [x] Version list newest first: `Vn`, created date, trigger, verdict,
  evidence count. Selecting a version expands its summary and sources read-only.
- [x] Footer: `开始研究`/`更新研究` with depth menu (quick/standard/deep) and
  the reuse hint ("将复用 2 小时前的报告") when the launcher would reuse.
- [x] Deleting a version is not offered; deleting the record remains in the
  legacy model only. Do not add destructive actions here.
- [x] Build checkpoint: `swift build`.

### 3.6 New topic sheet

- [x] `WorkspaceNewSubjectSheet`: title (required), optional aliases
  (comma/newline separated, max 8), optional seed URL. Validate URL with
  `ReaderNavigationPolicy.allowedURL` when present.
- [x] Show an inline hint: "创建主题不会自动开始 AI 研究；检查更新仅使用 RSS".
- [x] On save, create the subject, select it and dismiss. No research is
  started, no event is created.
- [x] Build checkpoint: `swift build`.

### 3.7 AppDelegate: one window and compatibility

- [x] Add `researchWorkspaceWindow` and `researchWorkspaceModel`. Remove neither
  old window property yet; just stop using it as the primary root.
- [x] Add `openResearchWorkspace(subjectID:researchID:eventID:)`:
  - reuse the live window and call `model.handleNotification(...)`;
  - if no subject is given but a record/event ID is, resolve via
    `WorkspaceSubjectStore` and, if still missing, run a full reconcile before
    opening; a legacy payload must never open an empty window;
  - otherwise build the model with `orchestrator`, `settings`, shared stores,
    event controller `NewsEventController.shared(settings:)`;
  - set title `research.workspace.windowTitle`, min size 1040×680;
  - `.environment(settings)`, `.id(settings.appLanguage)`.
- [x] `openResearchCenter(selecting:)` resolves the record -> subject and calls
  `openResearchWorkspace(subjectID:researchID:)`.
- [x] `openNewsEventMonitor(eventID:)` resolves the event -> subject and calls
  `openResearchWorkspace(subjectID:eventID:)`.
- [x] `openBurstWindow(title:)` keeps its behavior but opens the workspace. It
  resolves the existing record; if none, it creates a followed subject and
  calls `WorkspaceResearchLauncher.start` with the title as seed instead of
  calling `startManualResearch` directly.
- [x] `.researchRequested` handler: build a `ResearchSeed` from the posted
  `NewsItem`, create/reuse a followed subject via
  `WorkspaceSubjectStore.createSubject`, then call the same launcher. Do not
  call `orchestrator.startManualResearch` from the UI/notification path; that
  is a second task entry and would defeat dedupe.
- [x] Update window-close observers and `applicationWillTerminate`/dock
  presence checks to include the workspace window. Keep dashboard logic alive.
- [x] Do not delete `ResearchCenterView`/`EventMonitorCenterView`; leave a
  `// Legacy root; no longer opened by AppDelegate.` comment.
- [x] Build checkpoint: `swift build`.

### 3.8 Reader ⌘K integration

- [x] Add `case workspace(WorkspaceSearchResult)` to `QuickSearchResult` and
  `workspaceResults: [WorkspaceSearchResult]` to `QuickSearchModel`.
- [x] `searchLocal` accepts `workspaceResults` and appends them after news/
  history/archive, deduped by result id. It stays synchronous; the view fetches
  workspace results asynchronously.
- [x] `QuickSearchContent`: add `onOpenWorkspaceResult:
  (WorkspaceSearchResult) -> Void`; render a `主题/报告/证据/历史问答` section
  with a small header and no more than 8 rows. The existing sections remain.
- [x] Add a `在研究中心打开` context action on workspace rows. Opening a report
  selects its subject and version; opening an answer only opens the archive
  replay, never evidence and never creates a subject.
- [x] A quick-search question or AI answer must not create a subject or event.
  Only the explicit `新主题` action, a real RSS event, or a started research
  task creates/links one.
- [x] `ReaderAuxiliaryRail` passes the closure through.
  `NewsReaderView` gains `onOpenWorkspaceResult` and routes it to the dashboard/
  AppDelegate callback. Do not change the ⌘K shortcut binding at `:1697`.
- [x] In `QuickSearchContent`, fetch workspace results with a cancellable
  `.task(id: model.query)` after 200 ms; cancel on disappear. Do not query the
  network.
- [x] Build checkpoint: `swift build`.

### 3.9 Strings and accessibility

- [x] Add zh/en keys for: `research.workspace.windowTitle`,
  `workspace.sidebar.{all,following,updated,review,archived}`,
  `workspace.action.{newTopic,follow,unfollow,checkUpdates,startResearch,
  updateResearch,viewResearch,archive,unarchive,openInReader}`,
  `workspace.detail.{overview,timeline,evidence,research}`,
  `workspace.metrics.{researchSources,notificationSubjects}`,
  `workspace.check.rssOnly`, `workspace.review.hint`,
  `workspace.empty.{noSubjects,filter,search}`,
  `workspace.new.{title,aliases,seedURL,hint}`.
- [x] Every icon button has `.accessibilityLabel`; segmented picker has a
  label; rows expose title/status as one accessibility element.
- [x] Respect `accessibilityReduceMotion` for selection/notice animations.
- [x] Build checkpoint: `swift build`.

## Acceptance

- One window opens from the popover, dashboard, research chip, burst request,
  event request and both notification types.
- Sidebar shows exactly five filters with correct counts.
- Detail shows exactly four segments and no legacy view.
- New topic, follow, archive, start/update research and open-in-reader work.
- Reader ⌘K shows workspace results plus the existing local/web/AI/archive
  surfaces; selecting a workspace result opens the right subject/version.
- No destructive change to old record/event data.
- `swift build` passes.

## Handoff

Stage 4 wires real RSS checks, auto discovery and notification coordination into
the injection points left here (`checkUpdates` checker, model observers,
AppDelegate notifier). Do not add a second window or a second launcher.
