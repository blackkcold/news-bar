# Stage 2 — Domain: Subjects, Versions, Launcher, Local Search

> Checkbox status (2026-11-16): `[x]` means the item was delivered in code and
> covered by the compile evidence in `stage-2-report.md`. Runtime UI/notification/network
> was not executed; those behaviors remain unverified.

> Depends on Stage 1. Read `research-findings.md` first.
> No UI in this stage except small previews if needed for compilation.

## Goal

Add the link/version layer over existing research and event stores, a single
research launcher, and a local-first unified search index. Existing record and
event encoded shapes stay untouched.

## Rulings (landed before code, 2026-11-16)

These amend the task list below and are authoritative where they differ.

- **R1 report versions are stage-2, not stage-4.** The real
  `ResearchCoordinator` final-save path archives the previous report *before*
  overwriting it, and archives the new report after a successful save (ready or
  partial with a usable report). Versions keep the original
  `quoteVerified`, timestamps, source names and URLs. A failed/empty run never
  appends a fake version and never removes history.
- **R2 stable observing hook.** `ResearchResultObserving` is declared here with
  `researchWillOverwrite(_:nextReport:)` (default `true`) and
  `researchDidFinalize(_:previous:)`. Stage 4 adds state handling; it must not
  change these signatures.
- **R3 monotonic sequence, digest dedupe.** `appendVersion` owns the sequence
  (`max+1`) and ignores the caller's sequence. An identical digest anywhere in
  the retained window is not appended again. Cap 20, oldest pruned first.
- **R4 lazy first version.** A linked legacy record with a report and no stored
  version gets sequence 1 on the next finalize or explicit workspace action.
  The record file is never rewritten for this.
- **R5 stored fingerprint, never `current`.** The latest analysed report stores
  the evidence fingerprint it actually analysed in
  `workspace/report-state/<recordID>.json`. Reuse compares the *current*
  fingerprint with that stored value. A new event evidence item or update
  candidate never rewrites the stored fingerprint; it marks the subject
  `hasUpdates`/`needsReview` instead.
- **R6 metrics.** `researchIndependentSourceCount` reuses
  `report.verification.independentSources` when a validated report exists (0 is
  a valid authoritative result). Only a legacy report without verification
  falls back to the canonical-URL/syndication/domain count.
  `notificationPublisherCount` is always
  `NewsEventSourceResolver().countablePublisherCount(in: event.evidence)`.
  The two counts are never merged.
- **R7 conservative linking.** Explicit IDs (`research:<id>`, `event:<id>`,
  legacy `topic:<key>`), evidence canonical-URL equality, then exact normalized
  title/alias. Title fallback never merges event-to-event; two events with the
  same subject but different times stay separate subjects.
- **R8 unsupported workspace files are read-only.** A file with
  `schemaVersion != 1` is kept byte-for-byte and the store refuses writes; the
  bootstrap surfaces `issue: .unsupportedVersion`. A corrupt index is moved
  aside to `workspace-v1.corrupt-<timestamp>.json` and rebuilt; follow/archive
  data already in the corrupt bytes is never deleted.
- **R9 user state wins over reconcile.** `saveAll` preserves the stored
  follow/archive/check/pending/notified fields and ignores a stale reconcile
  whose `updatedAt` is older than the stored subject. A per-subject
  `userRevision` is bumped by `save` when a user-controlled field changes.
- **R10 clear intent.** A pending/unsupported clear intent or a newer clear
  generation prunes research links, report versions and report-state files,
  then the search index is rebuilt without those documents. Event evidence and
  event-backed subjects keep their independent lifecycle. Subjects themselves
  keep follow/archive state.
- **R11 depth is per request.** The launcher writes `record.run.depth` from
  `WorkspaceResearchRequest.depth`; the workspace production executor passes
  that value to `NewsOrchestrator.executeResearch(depth:)`. The legacy call
  path keeps `settings.researchDepth`.
- **R12 real incremental research.** New materials are page-read only for new
  or changed URLs; already cached pages are reused. Old quotes become extracted
  candidates only when the current local body still contains them verbatim
  (`QuoteVerifier.verified`). Missing bodies are not trusted. Synthesis and the
  original `ReportValidator` still run. Reuse of an existing report requires a
  compatible signature (subject, stored fingerprint, depth, provider, model,
  prompt version, recency) and no unanalysed update.
- **R13 one launcher in flight per subject.** Concurrent starts across entries
  coalesce on a static in-flight map; a coordinator-active record returns
  `.focusedRunning` with the same record ID.
- **R14 archive failure never replaces the report.** If any
  `researchWillOverwrite` returns `false`, the coordinator keeps
  `previousRecord.report`, marks the run `.failed` with a visible "history not
  replaced" error, saves counts, and skips event ingestion/notifications.
  `researchDidFinalize` is only called when a new usable report actually
  replaced the old one, so no observer can archive a non-existent new version.
- **R15 force refresh is a full run.** `WorkspaceResearchRequest.forceRefresh`
  bypasses report reuse, incremental context **and the page cache**: planning,
  search, page fetching and extraction run again. Non-force incremental stays.
  Reuse has a recency-derived age cap (maximum 24 h; 12 h for `auto`), so an
  expired report is never kept "current" forever just because its fingerprint
  matches.
- **R16 no fabricated seed URL/source.** A topic with no event evidence and no
  explicit seed creates a `ResearchRecord` directly through
  `ResearchRecordProvisioner.ensureTopicRecord`; `seed.url` stays `nil` and no
  `https://s.weibo.com` citation is invented. `request.depth` remains
  authoritative through both `record.run.depth` and the depth hand-off store.
- **R17 durable-write-then-publish.** Every `WorkspaceSubjectStore` mutator
  builds its next state, performs the durable `PrivateFile.write`, and only then
  publishes memory/caches/epoch/notification. A failed write leaves all of
  them unchanged; `appendVersion` cannot later skip an unpersisted digest.
  `applyHistoryClear` propagates file-deletion failures instead of marking the
  clear complete while bytes remain.
- **R18 atomic subject field updates.** `updateSubject(id:mutation:)` reads the
  latest stored subject inside the actor, applies one field intent, and commits
  transactionally. Snapshot `save`/`saveAll` preserve `isFollowed`,
  `isArchived`, `archivedAt` and `seedURL` unless `userRevision` is strictly
  newer; pending updates are unioned, check/notification times are monotonic.
  Feature code migrates read-modify-save to field updates.
- **R19 force refresh bypasses search cache too.** The pipeline passes
  `useCache: !forceRefresh` to `SearchRouter` as well as the page reader.
  Ticket/quota/SSRF behavior is unchanged.
- **R20 search index revisioning.** `WorkspaceSearchService` observes workspace,
  record, event and AI archive changes; reloads coalesce, and an index generation
  captured before a clear cannot commit. A dirty service never serves old
  `subjectsByID` or an old index snapshot.
- **R21 analysis identity and external evidence.** The reuse signature includes
  provider plus credential-endpoint identity and the effective model, without
  keys. The fingerprint excludes event evidence derived from the report itself
  (`.research` input kind or URLs already in the report) and only counts external
  evidence fetched before the run started; unchanged evidence reuses, new
  external evidence does not.
- **R22 one canonical subject per event/record provenance.** An event evidence
  ID `research:<recordID>:<digest>` is an explicit record join. If research and
  event already have separate subjects, fold them into the event's canonical
  subject, merge links/user state (archived stays archived), and persist
  `subject:<retiredID>` on the survivor. `store.subject(id:)` resolves the
  retired ID. `saveAll` derives retired IDs from those keys and refuses old
  snapshots that would resurrect a retired row. URL-only joins never merge
  event-backed subjects. `changedIDs` is computed against the initial snapshot.

## Files

Create:

- `Sources/NewsBar/Models/ResearchWorkspace.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceSubjectStore.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceReconciler.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceLeadMatcher.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceDetailBuilder.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceResearchLauncher.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceSearchIndex.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceSearchService.swift`

Modify:

- `Sources/NewsBar/Services/Research/ResearchStore.swift` — add `ResearchPaths`
  workspace directory helpers only; do not change record encoding.
- `Sources/NewsBar/Services/Research/ResearchCoordinator.swift` — expose the
  launcher-facing schedule signature only if needed; no observer hook yet.

## Interfaces

Produces (frozen; Stage 3/4 consume these exactly):

```swift
enum WorkspaceNotificationKind: String, Codable, Sendable {
    case researchCompleted, eventProgress
}

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
    let id: String
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
    var lookupKeys: [String]
    var lastNotifiedAt: Date?
    var lastNotificationKind: WorkspaceNotificationKind?
    var schemaVersion: Int
}

struct WorkspaceReportVersion: Codable, Identifiable, Hashable, Sendable {
    let id: String              // "\(recordID)#\(sequence)"
    let recordID: String
    let subjectID: String
    let sequence: Int
    let createdAt: Date
    let trigger: ResearchOrigin
    let report: BurstResearch
    let digest: String
}

struct WorkspaceUpdateCandidate: Codable, Identifiable, Hashable, Sendable {
    let id: String              // digest(canonicalURL + subjectID)
    let subjectID: String
    let title: String
    let url: String
    let sourceName: String
    let publishedAt: Date?
    let discoveredAt: Date
    let origin: WorkspaceUpdateOrigin
}

struct WorkspaceEvidence: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let url: String
    let canonicalURL: String
    let quote: String
    let publishedAt: Date?
    let sourceName: String
    let origin: WorkspaceEvidenceOrigin
    let verification: WorkspaceEvidenceVerification
    let tier: SourceTier?
    let independence: NewsEventIndependence?
    let sharedWithEvent: Bool
}

struct WorkspaceTimelineEntry: Identifiable, Hashable, Sendable {
    let id: String
    let occurredAt: Date?
    let text: String
    let origin: WorkspaceEvidenceOrigin
    let evidenceIDs: [String]
    let confidence: Confidence?
}

struct WorkspaceSourceMetrics: Equatable, Sendable {
    var researchIndependentSourceCount: Int
    var researchUniqueDomainCount: Int
    var notificationPublisherCount: Int
    var notificationEligible: Bool
    var basis: String
}

struct WorkspaceDetail: Sendable {
    var subject: WorkspaceSubject
    var event: NewsEvent?
    var research: ResearchRecord?
    var versions: [WorkspaceReportVersion]
    var evidence: [WorkspaceEvidence]
    var timeline: [WorkspaceTimelineEntry]
    var metrics: WorkspaceSourceMetrics
    var updates: [WorkspaceUpdateCandidate]
}
```

Store:

```swift
struct WorkspaceBootstrap: Sendable, Equatable {
    var subjects: [WorkspaceSubject]
    var rebuilt: Bool
    var corruptFile: Bool
}

protocol WorkspacePersisting: Sendable {
    func bootstrap() async -> WorkspaceBootstrap
    func subjects() async -> [WorkspaceSubject]
    func subject(id: String) async -> WorkspaceSubject?
    func subject(containingResearchID id: String) async -> WorkspaceSubject?
    func subject(containingEventID id: String) async -> WorkspaceSubject?
    func createSubject(title: String, aliases: [String], isFollowed: Bool,
                       now: Date) async throws -> WorkspaceSubject
    func save(_ subject: WorkspaceSubject) async throws
    func saveAll(_ subjects: [WorkspaceSubject]) async throws
    func updates(subjectID: String) async -> [WorkspaceUpdateCandidate]
    func saveUpdates(_ updates: [WorkspaceUpdateCandidate], for subjectID: String) async throws
    func versions(recordID: String) async -> [WorkspaceReportVersion]
    func appendVersion(_ version: WorkspaceReportVersion) async throws
    func dataEpoch() async -> Int
}

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
```

`WorkspaceSubjectStore` is an actor with `static let shared`. It writes
`Research/workspace/workspace-v1.json` and
`Research/workspace/report-versions/<recordID>.json` through `PrivateFile`,
with `durable: true` for the index and versions.

Reconciler and helpers:

```swift
struct WorkspaceReconcileResult: Sendable {
    var subjects: [WorkspaceSubject]
    var changedIDs: Set<String>
    var createdIDs: Set<String>
}

struct WorkspaceReconciler: Sendable {
    func reconcile(research: [ResearchIndexEntry], events: [NewsEvent],
                   existing: [WorkspaceSubject], now: Date,
                   evidenceURLsByRecordID: [String: Set<String>] = [:])
        -> WorkspaceReconcileResult
}

struct WorkspaceLeadMatcher: Sendable {
    func normalized(_ value: String) -> String
    func matches(title: String, summary: String, aliases: [String]) -> Bool
}

enum WorkspaceSourceMetricsBuilder {
    static func metrics(event: NewsEvent?, research: ResearchRecord?) -> WorkspaceSourceMetrics
}

struct WorkspaceDetailBuilder: Sendable {
    func build(subject: WorkspaceSubject, event: NewsEvent?, research: ResearchRecord?,
               versions: [WorkspaceReportVersion],
               updates: [WorkspaceUpdateCandidate]) -> WorkspaceDetail
}

enum WorkspaceEvidenceFingerprint {
    static func make(event: NewsEvent?, research: ResearchRecord?,
                     updates: [WorkspaceUpdateCandidate]) -> String
}

typealias WorkspaceResearchExecutor = @MainActor (
    ResearchRecord,
    @escaping @Sendable (ResearchRun) async -> Void
) async -> ResearchExecution

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

@MainActor
final class WorkspaceResearchLauncher {
    init(settings: AppSettings,
         store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
         researchStore: any ResearchPersisting = ResearchStore.shared,
         eventStore: any NewsEventPersisting = NewsEventStore.shared,
         coordinator: ResearchCoordinator? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         executor: @escaping WorkspaceResearchExecutor)
    func start(_ request: WorkspaceResearchRequest) async -> WorkspaceResearchAction
    static func productionExecutor(orchestrator: NewsOrchestrator,
                                   settings: AppSettings) -> WorkspaceResearchExecutor
}
```

Search:

```swift
struct WorkspaceSearchScope: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
    static let subjects: WorkspaceSearchScope
    static let reports: WorkspaceSearchScope
    static let evidence: WorkspaceSearchScope
    static let answers: WorkspaceSearchScope
    static let all: WorkspaceSearchScope
}

enum WorkspaceSearchResult: Identifiable, Sendable {
    case subject(id: String, title: String, snippet: String, isFollowed: Bool)
    case report(recordID: String, subjectID: String, title: String,
                snippet: String, generatedAt: Date?)
    case evidence(id: String, subjectID: String, title: String,
                  snippet: String, url: String)
    case answer(id: String, query: String, snippet: String, createdAt: Date)
    var id: String { get }
}

struct WorkspaceSearchResponse: Sendable {
    var results: [WorkspaceSearchResult]
    var isLocalOnly: Bool
    var truncated: Bool
}

struct WorkspaceSearchDocument: Codable, Identifiable, Sendable {
    let id: String
    let subjectID: String?
    let kind: WorkspaceSearchDocumentKind
    let title: String
    let body: String
    let url: String?
    let updatedAt: Date
}

enum WorkspaceSearchDocumentKind: String, Codable, Sendable {
    case subject, report, evidence, answer
}

actor WorkspaceSearchIndex {
    static let shared: WorkspaceSearchIndex
    func rebuild(subjects: [WorkspaceSubject], records: [ResearchRecord],
                 events: [NewsEvent], answers: [AISearchArchiveEntry],
                 now: Date) async
    func upsert(_ documents: [WorkspaceSearchDocument]) async
    func remove(subjectID: String) async
    func search(text: String, scopes: WorkspaceSearchScope,
                limit: Int) async -> WorkspaceSearchResponse
}

@MainActor
final class WorkspaceSearchService {
    init(store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
         index: WorkspaceSearchIndex = .shared,
         researchStore: any ResearchPersisting = ResearchStore.shared,
         eventStore: any NewsEventPersisting = NewsEventStore.shared,
         archiveStore: AISearchArchiveStore = AISearchArchiveStore(),
         gateway: ManualSearchGateway = ManualSearchGateway())
    func reloadIndex() async
    func searchLocal(_ text: String, scopes: WorkspaceSearchScope,
                     limit: Int = 20) async -> WorkspaceSearchResponse
    func searchWeb(_ text: String, language: AppLanguage,
                   settings: AppSettings) async throws -> SearchBatch
}
```

## Incremental research — exact interface (frozen for stage 3/4)

`Sources/NewsBar/Services/Research/ResearchIncremental.swift`:

```swift
struct ResearchMaterial: Codable, Hashable, Sendable {
    var url: String
    var canonicalURL: String
    var title: String
    var snippet: String
    var publishedAt: Date?
    var sourceName: String
}

struct ResearchReuseSignature: Codable, Equatable, Sendable {
    var subjectID: String
    var depth: ResearchDepth
    var provider: String
    var model: String
    var promptVersion: Int
    var recency: String
}

struct ResearchIncrementalContext: Sendable {
    var priorReport: BurstResearch
    /// New leads to inspect. Empty contexts are never scheduled; the launcher
    /// reuses a compatible report instead.
    var newMaterials: [ResearchMaterial]
    var signature: ResearchReuseSignature
}

/// Process-local hand-off from the launcher to the executor. `take` removes the
/// value, so one run cannot consume another run's context.
actor ResearchIncrementalContextStore {
    static let shared: ResearchIncrementalContextStore
    func put(_ context: ResearchIncrementalContext, recordID: String)
    func putDepth(_ depth: ResearchDepth, recordID: String)
    func take(recordID: String) -> ResearchIncrementalContext?
    func takeDepth(recordID: String) -> ResearchDepth?
    func putForceRefresh(_ force: Bool, recordID: String)
    func takeForceRefresh(recordID: String) -> Bool
    func discard(recordID: String)
}
```

`ResearchPipelineConfiguration` gains
`var incremental: ResearchIncrementalContext? = nil` (defaulted; existing
callers unchanged). `NewsOrchestrator.executeResearch` gains
`depth: ResearchDepth? = nil` and pulls the context from the store before
building the pipeline. Legacy callers keep `settings.researchDepth`.

Pipeline rules: no planning AI call in incremental mode (prior claims and
queries are reused); prior evidence URLs load from the page cache, never the
network; materials are page-read once; only documents outside the prior
evidence set, or fetched after the prior report, are sent to extraction; reused
quotes are re-checked with `QuoteVerifier` and go through the unchanged
`ReportValidator`; synthesis receives the prior summary/overview as background
only.

## Additional actual signatures (compatible extensions)

```swift
struct WorkspaceReportState: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case pending, analyzed }
    let recordID: String
    let subjectID: String
    var status: Status
    var signature: ResearchReuseSignature?
    /// Fingerprint adopted by the analysis. Nil until the run finalizes.
    var analyzedFingerprint: String?
    var versionID: String?
    var recordedAt: Date?
}

struct WorkspaceBootstrap {
    var subjects: [WorkspaceSubject]
    var rebuilt: Bool
    var corruptFile: Bool
    var readOnly: Bool
    var issue: WorkspaceStoreIssue?
}

enum WorkspaceStoreIssue: String, Codable, Sendable {
    case corruptFile, unsupportedVersion, ioUnavailable
}

@MainActor
protocol ResearchResultObserving: AnyObject {
    func researchWillOverwrite(_ previous: ResearchRecord, nextReport: BurstResearch) async -> Bool
    func researchDidFinalize(_ record: ResearchRecord, previous: ResearchRecord) async
}
```

`WorkspacePersisting` additions (defaulted where possible):

```swift
func reportState(recordID: String) async -> WorkspaceReportState?
func saveReportState(_ state: WorkspaceReportState) async throws
func ensureBaselineVersion(record: ResearchRecord, subjectID: String, at: Date) async throws
func applyHistoryClear(now: Date) async throws -> Int
```

`WorkspaceReportVersion` gains optional `evidenceFingerprint` and
`analysisSignature`; `WorkspaceSubject` gains `userRevision: Int = 0`.
`WorkspaceSearchService` adds:

```swift
@discardableResult
func saveWebHitAsCandidate(_ hit: SearchHit, subjectID: String,
                           now: Date = Date()) async -> WorkspaceUpdateCandidate?
```

This stores an explicitly requested web hit as an **unverified lead**
(`origin: .research`) for the subject; it never becomes report evidence.

`ResearchCoordinator` always retains
`WorkspaceReportVersionObserver.shared`; `setResultObservers(_:)` appends stage-4
observers instead of replacing it. `WorkspaceSearchService.reloadIndex()` also
creates the lazy V1 for a linked historical report that has no version file.

Final-domain additions (F1–F5):

```swift
// WorkspacePersisting
@discardableResult
func updateSubject(id: String,
                  mutation: @Sendable (inout WorkspaceSubject) -> Void)
    async throws -> WorkspaceSubject

// ResearchReuseSignature
var endpointIdentity: String?   // credential endpoint, never the key
var providerIdentity: String?   // provider id + endpoint identity

// WorkspaceSearchIndex
func beginRebuild() -> Int
func rebuild(subjects:records:events:answers:now:generation:) async -> Bool
func reset() async              // bumps generation

// WorkspaceSearchService
func markDirty()                // observers call it; searchLocal coalesces
```

`Notification.Name.aiSearchArchiveChanged` is posted after a successful archive
record/remove/clear. `ResearchPipeline` passes
`useCache: !configuration.forceRefresh` to both `SearchRouter` and `PageReader`.

## Tasks

### 2.1 Add paths and models

- [x] Add `ResearchPaths.workspaceDirectory` and
  `ResearchPaths.workspaceIndexFile` (and `workspaceVersionsDirectory`). Do not
  alter `researchDirectory` or any existing file name.
- [x] Add every type above to `ResearchWorkspace.swift`. Use `Hashable` only
  where the type's members are hashable; `WorkspaceEvidence`/`WorkspaceTimelineEntry`
  are intentionally not `Codable` (display projections).
- [x] Implement `WorkspaceSubject` helper methods:
  `normalizedAliases`, `contains(recordID:)`, `contains(eventID:)`,
  `link(researchID:title:aliases:)`, `link(eventID:title:aliases:)`,
  `markActivity(at:)`, `markArchived(_:at:)`.
- [x] Build checkpoint: `swift build`.

### 2.2 Store

- [x] Implement `WorkspaceSubjectStore` with the protocol. Load the index once
  per actor lifetime; cache subjects in memory; write atomically.
- [x] Bootstrap rules: missing file -> empty + reconcile; decode failure ->
  move the bad file aside as `workspace-v1.corrupt-<timestamp>.json` (do not
  delete) and rebuild; `schemaVersion != 1` -> rebuild but keep the file.
- [x] `appendVersion` reads the record's array (or an empty array), skips an
  identical `digest` already at the tail, appends, sorts by `sequence`
  ascending, caps at 20, writes. `versions(recordID:)` returns ascending by
  `sequence`; the UI reverses for display. Sequence is
  `max(existing.sequence) + 1`.
- [x] `saveUpdates` replaces the candidate list for one subject and drops
  candidates older than 90 days.
- [x] `createSubject` trims the title, rejects empty, creates a stable UUID,
  normalizes aliases, writes `lookupKeys = ["topic:<key>"]`, sets
  `schemaVersion = 1`, `kind = .topic`, `updateState = .current`,
  `lastCheckOutcome = .notConfigured`, and saves. It never creates a research
  record.
- [x] Post `.researchWorkspaceChanged` after durable writes, with
  `userInfo["subjectID"]` when one subject changed. Define the notification
  name in the store file.
- [x] Build checkpoint: `swift build`.

### 2.3 Reconciler and matcher

- [x] Implement matching in the exact order from the design: lookup key, exact
  normalized alias, create. Never merge two event-backed subjects.
- [x] New reconciled subjects default to `isFollowed = false`,
  `isArchived = false`, `updateState = .current`,
  `lastCheckOutcome = .notConfigured`, `schemaVersion = 1`. Only the explicit
  `createSubject` path sets `isFollowed = true`; auto discovery never follows.
- [x] Preserve user state (`isFollowed`, `isArchived`, `archivedAt`,
  `lastCheckOutcome`, `pendingUpdateIDs`, `lastNotified*`) on every reconcile.
- [x] When a subject gains both a research link and an event link, set
  `kind = .mixed`; otherwise keep `.topic` or `.event`.
- [x] If a linked event `hasConflict` and the subject is not archived, promote
  `updateState` to `.needsReview`. Do not downgrade an existing `.needsReview`
  to `.hasUpdates` during a reconcile.
- [x] Refresh title only from the most recent source (research `lastSeenAt` or
  event `lastEvidenceAt`); refresh `lastActivityAt` to the max.
- [x] `WorkspaceLeadMatcher`: normalize with `TopicFingerprint.normalized`;
  accept CJK aliases of 2+ characters and Latin aliases of 4+ characters;
  match title or summary containment. No fuzzy edit distance, no AI.
- [x] Build checkpoint: `swift build`.

### 2.4 Detail builder and metrics

- [x] Research evidence mapping: use `canonicalURL`, `quoteVerified` ->
  `.verifiedQuote`/`.unverifiedQuote`; tier from `EvidenceItem.tier`; no
  re-validation.
- [x] Event evidence mapping: `.snippetOnly`, independence from the event
  evidence; `notificationPublisherCount` comes only from
  `NewsEventSourceResolver().countablePublisherCount(in:)`. Set
  `notificationEligible = event?.notificationEligibility == .eligible`.
- [x] Research metric: dedupe by canonical URL, then collapse
  `syndicationGroup`, then count distinct registrable domains. Set
  `researchUniqueDomainCount` to the deduped domain count.
- [x] Merge evidence by `(canonicalURL, QuoteVerifier.normalize(quote))`. If a
  key exists in both stores, emit one research-priority row with
  `sharedWithEvent = true`; otherwise keep the source row with
  `sharedWithEvent = false`. Never overwrite either store.
- [x] Timeline: merge event nodes and report timeline; deterministic sort by
  date descending, nil dates last, stable id tiebreak.
- [x] `WorkspaceDetailBuilder` returns `updates` sorted newest first and
  `versions` newest first.
- [x] Build checkpoint: `swift build`.

### 2.5 Launcher

- [x] Resolve the subject; if missing return `.failed(.subjectMissing)`.
- [x] Resolve or create the record:
  - latest by `researchStore.latestRecord(topicKey: TopicFingerprint.key(for: subject.title))`
    or any linked record ID;
  - if none, build a `NewsItem` from the subject's primary event evidence or
    seed and call
    `ResearchRecordProvisioner.ensureRecord(for: item, origin: request.trigger,
    store: researchStore)`.
- [x] Coalesce concurrent calls per `subjectID` with an in-flight task map.
- [x] Reuse when `!forceRefresh`, latest report exists, age < 24 h and
  `WorkspaceEvidenceFingerprint` equals the report's stored/derived fingerprint.
  Return `.reused`.
- [x] Otherwise call `coordinator.schedule(recordID:notify:trigger:executor:)`.
  Map `.accepted -> .started`, `.alreadyActive -> .focusedRunning`; all other
  outcomes map to `.failed` with the closest failure case.
- [x] Never create a second record for a subject when a linked record exists.
- [x] Build checkpoint: `swift build`.

### 2.6 Search index and service

- [x] Define scope bits explicitly: subjects `1<<0`, reports `1<<1`, evidence
  `1<<2`, answers `1<<3`, `all` is their union.
- [x] Index subject title/aliases, latest report summary/overview, all report
  evidence titles/quotes, event claims/timeline, and archive queries/answers.
  Do not index raw private page text; store only short snippets (<= 400 chars).
- [x] Ranking: title prefix > title contains > body contains; then recency;
  then stable id. Apply `limit` and set `truncated`.
- [x] Persist `workspace/search-index-v1.json`; rebuild if missing or version
  mismatched. `reloadIndex()` calls `await archiveStore.prepare()` first, loads
  subjects, all records, events and archive entries once, then calls `rebuild`.
- [x] `searchWeb` is explicit only: load `SearchKeyStore.loadAll()`, use
  `settings.enabledSearchProviders`, build `SearchRouterConfiguration`, call
  the injected `ManualSearchGateway`. Never call it from `searchLocal`.
- [x] Build checkpoint: `swift build`.

## Acceptance

- A `WorkspaceSubject` can link one research record and one event without
  changing either store file.
- Reconcile twice with unchanged inputs produces the same subject IDs and
  preserves follow/archive state.
- A second `start` for the same subject coalesces, not duplicates.
- Search returns subject/report/evidence/answer sections; no network call in
  `searchLocal`.
- Metrics expose separate research and notification counts.
- `swift build` passes.

## Handoff

Stage 3 consumes only the frozen interfaces above. If a field is missing, add
it here and update the design/plan index; do not work around it in the view.
