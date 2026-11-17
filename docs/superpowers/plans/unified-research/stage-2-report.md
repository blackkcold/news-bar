# Stage 2 Report — Domain (subjects, versions, launcher, local search)

**Branch:** `feat/unified-research-workspace`
**Worktree:** `/Users/11169285/.local/share/opencode/worktree/2c2cb18db9ec202ac5ec607efad1feaa54f77c57/unified-research-workspace`
**Plan:** `docs/superpowers/plans/unified-research/stage-2-domain.md`
**Date:** 2026-11-16
**Status:** 代码完成，最终 `swift build` 通过（exit 0）。**未执行测试、未启动 app、未调用业务 API、未联网、未提交。**

## 0. 交接后最小修正（同一 stage 2）
- **旧报告归档失败不再覆盖**：`ResearchCoordinator` 尊重
  `researchWillOverwrite` 的 `false`。任一步失败时保留
  `previousRecord.report`，把本次 run 置为可见 `.failed`（
  `research.error.versionArchive`），保存 counts，跳过
  `researchDidFinalize`、event ingest 与成功通知。`didFinalize` 现在只在新
  report 真正替换旧版后调用。
- **forceRefresh 真全量**：`WorkspaceResearchLauncher` 在
  `forceRefresh == true` 时不再创建增量 context；planning/search/page
  fetch（绕过 page cache）/extraction 全部重跑。非 force 仍走增量。
- **复用时效上限**：按 `researchDefaultRecency` 计算保守窗口（auto 12h，
  其余 `min(24h, max(1h, days*1h))`），超过即重研，不再把过期报告永久当
  current。
- **无伪造种子**：topic-only 通过
  `ResearchRecordProvisioner.ensureTopicRecord` 直接建 record，`seed.url`
  保持 nil；`makeNewsItem` 已删除，事件证据才生成真实 seed。pipeline 的
  fallback 也不再使用 `https://s.weibo.com`，无 URL 时 `seedSourceName` 为空。
- `request.depth` 仍经 `record.run.depth` + depth hand-off 双路径生效。

## 0.1 Final-domain F1–F5（主代理自查后）

- **F1 持久化原子性**：`WorkspaceSubjectStore` 的 create/save/saveAll/
  saveUpdates/saveReportState/appendVersion 改为先生成候选、durable write
  成功后才发布内存/epoch/通知；失败保持内存与缓存不变，`appendVersion`
  不会留下“已见 digest 但未落盘”的缓存。`applyHistoryClear` 的版本/状态/
  索引删除失败抛 `WorkspaceStoreError.clearIncomplete`，不推进 clear
  generation；read-only 也抛错而不是假装清空。
- **F2 原子字段更新**：新增
  `updateSubject(id:mutation:)`，actor 内读取最新 subject。快照 `save`/
  `saveAll` 按 `userRevision` 保护 follow/archive/seed，pending 并集，检查/
  通知时间单调，旧快照不能回滚新状态。Model toggle/archive/seed、
  launcher link、version observer、research observer、auto discovery、
  notification coordinator、update checker 均已迁移；pending 清除只由
  observer 基于 `startedAt` 分析边界执行。
- **F3 force search**：pipeline 搜索调用补上
  `useCache: !configuration.forceRefresh`；配合 page cache 绕过，ticket/
  quota/SSRF 未变。
- **F4 搜索失效**：`WorkspaceSearchService` 观察
  `researchWorkspaceChanged/researchRecordsChanged/newsEventsChanged/
  aiSearchArchiveChanged`，`markDirty` 立即清 subjectsByID；reload 用
  revision + `WorkspaceSearchIndex` generation 双闸，跨 clear 的旧 rebuild
  不提交，并合并并发 reload。archive 成功写后 post 新通知。
- **F5 复用身份**：`ResearchReuseSignature` 增加
  `endpointIdentity`/`providerIdentity`，不含 key；模型仍为 effective
  `aiModel`。指纹排除 `.research` 事件证据及已在本报告中的 URL，只计
  `startedAt` 前的外部证据；报告自灌事件不再制造无限 needsReview。

新增/实际 API：

```swift
@discardableResult
func updateSubject(id: String,
                  mutation: @Sendable (inout WorkspaceSubject) -> Void)
    async throws -> WorkspaceSubject

func beginRebuild() -> Int
func rebuild(subjects:records:events:answers:now:generation:) async -> Bool
func reset() async
func markDirty()

var endpointIdentity: String?
var providerIdentity: String?
```

## 0.2 Final integration: one canonical subject (F6)

- Event evidence IDs of the form `research:<recordID>:<digest>` are parsed as
  explicit record provenance. If the event already owns subject B and the
  research record owns A, B becomes canonical; A's research links, event links,
  aliases and lookup keys move to B and A becomes retired.
- User state merge: `isArchived` is OR (an existing event archive is never
  silently cleared), `isFollowed` is OR, check/notification times use the newer
  value, pending IDs union, update state takes the stronger value.
- `subject:<retiredID>` is persisted on the survivor. `store.subject(id:)`
  resolves it, so old subject/record/event deep links still work. `saveAll`
  derives retired IDs from those keys, removes the retired rows and refuses to
  re-add them from an old snapshot.
- URL fallback only attaches an event to a research/topic subject with no event
  yet. Two event-backed subjects are never merged by a shared article URL.
- `changedIDs` is now diffed against the initial `existing` snapshot, so newly
  linked IDs, conflict state and merges are counted; an unchanged reconcile
  returns no changed/created IDs and `saveAll` is a no-op.
- Reports, versions, research records and events are never deleted by a merge.

## 1. 裁决落版（先于代码）

R1–R13 已写入 `stage-2-domain.md` 的 `## Rulings`，并在 `progress.md` 记录 Stage 2。要点：

| 裁决 | 落地 |
|---|---|
| R1 版本属于 stage 2 | `ResearchCoordinator` 真实 finalize 路径接入版本归档；覆写前存旧版，成功后存新版 |
| R2 稳定 observer | `ResearchResultObserving` + `WorkspaceReportVersionObserver`；stage 4 只追加，不可移除内建 observer |
| R3 单调 sequence / digest 去重 | `appendVersion` 自己算 `max+1`，相同 digest 不追加；上限 20 |
| R4 旧报告惰性首版 | launcher 启动前、搜索索引 reload、下次 finalize 都会补 V1；不改 record 文件 |
| R5 存分析 fingerprint | `report-state/<recordID>.json` 保存“实际分析采用”的 fingerprint；新证据只改 subject 状态 |
| R6 指标不合并 | 研究独立来源优先用 `verification.independentSources`；通知主体只用 `NewsEventSourceResolver` |
| R7 保守链接 | 显式 ID → 证据/seed 规范 URL → 精确标题；事件到事件不按标题合并 |
| R8 未支持版本只读 | `WorkspaceBootstrap.issue/.readOnly`；文件保留字节；损坏文件隔离 |
| R9 用户状态优先 | `saveAll` 保留 follow/archive/check/pending/notified；`save` 对链接做并集 |
| R10 clear intent | 清空历史删除版本/分析状态、剥离研究链接、删除并重置搜索索引；事件证据保留 |
| R11 depth 真正生效 | launcher 写 `record.run.depth`；production executor 显式传给 `executeResearch(depth:)` |
| R12 真增量 | 缓存页面直接复用；旧 quote 必须当前正文逐字命中；只抽取新增/变化文档；原 validator 不变 |
| R13 单入口合并 | 静态 in-flight map；运行中返回 `.focusedRunning` |

## 2. 实际接口

### 2.1 模型与状态

```swift
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
    var userRevision: Int          // stage-2 addition
}

struct WorkspaceReportVersion: Codable, Identifiable, Hashable, Sendable {
    let id: String                 // "\(recordID)#\(sequence)"
    let recordID: String
    let subjectID: String
    let sequence: Int
    let createdAt: Date
    let trigger: ResearchOrigin
    let report: BurstResearch
    let digest: String
    var evidenceFingerprint: String?          // analysis-adopted fingerprint
    var analysisSignature: ResearchReuseSignature?
}
```

新增：`WorkspaceReportState`（`.pending/.analyzed` + signature + analyzedFingerprint + versionID）、`WorkspaceStoreIssue`、`WorkspaceBootstrap.readOnly/issue`、`WorkspaceEvidence`/`WorkspaceTimelineEntry`/`WorkspaceSourceMetrics`/`WorkspaceDetail`、`WorkspaceSearchScope`/`Result`/`Document`。

### 2.2 Store

```swift
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
    func reportState(recordID: String) async -> WorkspaceReportState?
    func saveReportState(_ state: WorkspaceReportState) async throws
    func ensureBaselineVersion(record: ResearchRecord, subjectID: String, at: Date) async throws
    func applyHistoryClear(now: Date) async throws -> Int
}
```

`actor WorkspaceSubjectStore: WorkspacePersisting`，`static let shared`。文件：
`Research/workspace/workspace-v1.json`（durable）、`report-versions/<id>.json`（durable）、`report-state/<id>.json`、`search-index-v1.json`。`ResearchPaths` 只新增 workspace 路径，未改原有路径。

### 2.3 Reconciler / detail

```swift
struct WorkspaceReconciler: Sendable {
    func reconcile(research: [ResearchIndexEntry], events: [NewsEvent],
                   existing: [WorkspaceSubject], now: Date,
                   evidenceURLsByRecordID: [String: Set<String>] = [:])
        -> WorkspaceReconcileResult
}

enum WorkspaceSourceMetricsBuilder {
    static func metrics(event: NewsEvent?, research: ResearchRecord?) -> WorkspaceSourceMetrics
}

struct WorkspaceDetailBuilder: Sendable {
    func build(subject: WorkspaceSubject, event: NewsEvent?,
               research: ResearchRecord?, versions: [WorkspaceReportVersion],
               updates: [WorkspaceUpdateCandidate]) -> WorkspaceDetail
}
```

`WorkspaceLeadMatcher`：CJK 别名 ≥2 字符、拉丁/数字 ≥4；只做包含匹配。

### 2.4 Launcher

```swift
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

复用条件：`!forceRefresh`、`record.status == .ready`、`report-state == .analyzed`、stored fingerprint == 当前 fingerprint、signature 完全一致、无未分析 update。签名包含 subjectID/depth/provider/model/promptVersion/recency。

### 2.5 搜索

```swift
actor WorkspaceSearchIndex {
    static let shared: WorkspaceSearchIndex
    func rebuild(subjects:records:events:answers:now:) async
    func upsert(_:) async
    func remove(subjectID:) async
    func reset() async
    func search(text:scopes:limit:) async -> WorkspaceSearchResponse
}

@MainActor
final class WorkspaceSearchService {
    func reloadIndex() async
    func searchLocal(_ text: String, scopes: WorkspaceSearchScope,
                     limit: Int = 20) async -> WorkspaceSearchResponse
    func searchWeb(_ text: String, language: AppLanguage,
                   settings: AppSettings) async throws -> SearchBatch
    @discardableResult
    func saveWebHitAsCandidate(_ hit: SearchHit, subjectID: String,
                               now: Date = Date()) async -> WorkspaceUpdateCandidate?
}
```

评分：标题前缀 300 > 标题包含 200 > 正文包含 100 > 词项全含 40；再按 `updatedAt` 降序、id 稳定。`searchLocal` 只走本地索引；`searchWeb` 只走显式 gateway。答案只索引 `readerSearch`，selection lookup 不进持久索引；正文片段 ≤400 字符。

## 3. 真实增量研究

```swift
struct ResearchMaterial: Codable, Hashable, Sendable { url, canonicalURL, title, snippet, publishedAt, sourceName }
struct ResearchReuseSignature: Codable, Hashable, Sendable { subjectID, depth, provider, model, promptVersion, recency }
struct ResearchIncrementalContext: Sendable { priorReport: BurstResearch; newMaterials: [ResearchMaterial]; signature: ResearchReuseSignature }

actor ResearchIncrementalContextStore { put/take/discard }
```

`ResearchPipelineConfiguration` 新增 `incremental: ResearchIncrementalContext? = nil`。`NewsOrchestrator.executeResearch` 新增 `depth: ResearchDepth? = nil`，并从 store `take(recordID:)`。

流水线行为：
- 增量分支跳过 planning AI；复用 prior claims / queries。
- 不重跑全量搜索；prior evidence URL 只从 page cache 读；new materials 先读缓存，未命中才联网。
- 只对“prior 证据里没有的 URL”或 `fetchedAt > prior.generatedAt` 的文档做抽取。
- 旧 quote 只有 `QuoteVerifier.verified` 在当前本地正文命中才加入 candidates；缺正文不猜、不标记 verified，旧版本仍在版本文件里。
- 合并证据后照常 synthesis + 原 `ReportValidator`；不绕过 validator。
- 无新增且签名/fingerprint 一致时 launcher 直接复用，不跑 24h 规则。

`PageReader` 新增 `PageReadRequest` 与 `cachedDocument(canonicalURL:)`，页面读取不再需要伪造 `SearchHit`。

## 4. 文件清单

新增（10）：

- `Sources/NewsBar/Models/ResearchWorkspace.swift`
- `Sources/NewsBar/Services/Research/ResearchIncremental.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceSubjectStore.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceReconciler.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceLeadMatcher.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceDetailBuilder.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceResearchLauncher.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceSearchIndex.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceSearchService.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceReportVersionObserver.swift`

修改（7）：

- `Services/Research/ResearchStore.swift`（仅 `ResearchPaths` workspace 路径）
- `Services/Research/ResearchCoordinator.swift`（observer / notifier / finalize 顺序）
- `Services/Research/ResearchPipeline.swift`（incremental）
- `Services/Research/ResearchHistoryClearer.swift`（workspace clear 阶段）
- `Services/NewsOrchestrator.swift`（depth + incremental pickup + clearer 接线）
- `Services/Search/PageReader.swift`（provider-free request + cache read）
- docs：`stage-2-domain.md`、`progress.md`、本报告

Final-domain F1–F5  additionally touched:

- `Services/AISearchArchiveStore.swift`（post `.aiSearchArchiveChanged`）
- `Services/Workspace/WorkspaceAutoDiscovery.swift`
- `Services/Workspace/WorkspaceNotificationCoordinator.swift`
- `Services/Workspace/WorkspaceUpdateChecker.swift`
- `Services/Workspace/WorkspaceResearchObserver.swift`
- `Views/Workspace/ResearchWorkspaceModel.swift`
- `AppDelegate.swift`
- `Models/ResearchWorkspace.swift`（fingerprint/self-evidence）
- `Services/Research/ResearchIncremental.swift`（signature fields）

## 5. 构建

```
$ swift build
Build complete! (11.67s)
EXIT=0
```

日志：`.build/unified-research-final-domain-build.log`。最终 0 error；新增 stage-2 文件 warning 已清理。F1–F5 修正后重新构建仍 exit 0。

构建过程中出现过 1 次编译错误（`compactMap` 元组签名），修正后连续通过；语义修正（损坏文件隔离、链接并集、增量上下文过期、clear intent）后重新构建仍 exit 0。

## 6. 未执行

- 未运行 `swift test`、任何测试二进制、baseline、专项评审。
- 未启动 app，未调用任何业务 API 或网络接口。
- 未 commit / push / 发布 / 安装依赖。
- 因此没有任何“测试通过”的结论；唯一验证是编译。

## 7. 交接给 Stage 3/4

Stage 3 需要：

- 用 `WorkspaceResearchLauncher.productionExecutor(orchestrator:settings:)` 或自建等价 executor；`start` 写入的 depth 会被真正使用。
- 打开详情前调用 `WorkspaceSearchService.reloadIndex()`（会补旧报告 V1）或显式 `store.ensureBaselineVersion`。
- `searchLocal` 结果已带 subjectID，可直接定位主题。
- 网页按钮调用 `searchWeb`；结果转待核查用 `saveWebHitAsCandidate`（`.research`，永不是 report evidence）。

Stage 4 需要：

- `setResultObservers` 只追加状态 observer；版本 observer 已内建，不要重复写版本。
- `reconcile` 可传 `evidenceURLsByRecordID` 以严格匹配报告证据 URL。
- RSS/event 新证据通过 `saveUpdates` 进入；store 会设置 `hasUpdates`，有已分析 report 时设置 `needsReview`。
- `WorkspaceUpdateChecker` / `WorkspaceNotificationCoordinator` 接口未在本阶段实现（仅协议/模型）。

## 8. 剩余风险

1. 无 UI/运行时验证：launcher、索引、版本 hook 只通过编译与阅读验证；stage 3 首次运行需重点看 store 文件权限与 read-only 分支。
2. 增量只由 launcher 的 process-local context 触发；直接 legacy 调用仍是全量运行（安全 fallback）。
3. 搜索是确定性 substring/词项匹配，不做分词/相关性模型；对长中文查询可能召回偏保守。
4. `WorkspaceReportVersionObserver` 归档失败只记日志，不阻塞新报告；磁盘持续失败时旧版本可能无法落盘（但不会伪造成已核实）。
5. `WorkspaceSubjectStore.save` 对 research/event 链接做并集，本阶段没有“显式解除单个链接”的 API；清空历史走 clear intent。
6. 事件到研究 subject 的 URL 严格匹配依赖 `seedURL`/已链接事件证据；报告证据 URL 需 stage 4 传入 `evidenceURLsByRecordID`。
7. `WorkspaceSearchIndex` 的 selection lookup 明确排除，可能让部分历史划词问答搜不到；这是隐私取舍。
8. 增量复用旧 quote 时，若缓存正文已被清理且新资料页面读取失败，该旧证据不会进入新报告（旧版本仍保留）。
