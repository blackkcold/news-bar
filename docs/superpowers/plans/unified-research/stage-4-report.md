# Stage 4 Report — RSS Checks, Discovery, Notification Coordination

**Branch:** `feat/unified-research-workspace`
**Worktree:** `/Users/11169285/.local/share/opencode/worktree/2c2cb18db9ec202ac5ec607efad1feaa54f77c57/unified-research-workspace`
**Plan:** `docs/superpowers/plans/unified-research/stage-4-automation.md`
**Date:** 2026-11-16
**Status:** 代码完成，最终 `swift build` exit 0。**未运行测试、未启动 app、未联网、未调用业务 API、未提交/推送/发布。**

## 0. Final self-check follow-up (F1–F3, before code)

Root causes and minimal fixes recorded before editing:

- **F1 reused is not “unmatched”.** The shared-check reuse path returned
  `finishSuccess(added: [])` without matching already-fetched data, so a new or
  just-followed subject could see a false “0 leads” and a 10-minute lock.
  Reuse must hydrate evidence already persisted for the same RSS source, match
  it against the current subject, and save those leads without any new HTTP
  request. “Cursor is new” is not proof that this subject was matched.
  `reused` and `throttled`/`failed` must not claim `checkedSourceIDs`; only a
  real 304/modified check may present completed coverage. Candidate identity is
  unified as `subjectID + canonicalURL` for web, RSS and checker paths, and the
  store normalizes old IDs and keeps the earliest `discoveredAt` so the same
  URL is not duplicated or repeatedly reset.
- **F2 budget single-flight must cover durability.** The tracker released the
  budget when HTTP returned, but the cursor was committed later by the
  controller. A second check/tick could fetch the same source in that gap.
  A minimal pending check/result/ack state holds the same budget slot from
  acquire through evidence persistence and cursor commit. Concurrent callers
  get an explicit pending/deferred result; `tick` excludes pending sources and
  reports deferred rather than fetching. Commit, failure and cancel each ack
  and release; a stale pending check expires safely. Normal shared RSS refresh
  keeps “evidence first, cursor second” and adds no timer.
- **F3 causal notification token.** `recordEventNotified` only stored the event
  ID, so research suppression used subject + 30 min + origin and both missed
  same-report manual duplicates and suppressed unrelated later runs. Research
  evidence now carries an optional causal token
  `research:<recordID>:<generatedAt>:<digest>`, computed from the record the
  controller actually ingests. The event notice records that token when its
  triggering evidence is research-derived. A research completion is suppressed
  only when the same token was just notified (including manual runs); different
  versions and unrelated progress are not suppressed by time. Event eligibility,
  publisher thresholds, semantic-key-before-delivery and failure behavior stay
  unchanged. Workspace rejection still does not consume the event key. Claims
  remain atomic and use `updateSubject`; notification keys stay unchanged and
  `subjectID` remains additive.

## 1. 裁决落版（先于代码）

已写入 `stage-4-automation.md` 的 `## Rulings (Stage 4)` 与
`progress.md` 的 `## Stage 4 rulings`。要点：

- 版本层与 cache 清理已由 stage 2/1 完成，本阶段不重定义
  `ResearchResultObserving`、不重复追加版本、不替换内建
  `WorkspaceReportVersionObserver`，也不重复实现 cache clear。
- RSS checker 不再自己 new `NewsEventTrackingBudget`，而是通过
  `NewsEventController` 的薄 broker 使用事件追踪的同一个 budget 实例和
  单飞槽；条件请求、共享 cursor、失败退避、证据落盘后再提交 cursor 全部保留。
- 一次点击默认只检查 1 个 RSS 源（8 只是上限），并复用刚完成的共享检查，
  避免一次点掉滚动小时预算。
- 关注的普通主题在既有 RSS 刷新成功且 feed 内容变化时收集线索；不新增
  timer、不额外联网、不自动创建主题、不自动 AI。
- 所有研究触发统一走 `WorkspaceResearchLauncher`，保留自动开关、triage、
  每小时启动闸门、`ResearchAutoAdmission`、queue limit 与 `isAllowed`。
- 通知协调取消 6 小时同 kind 一刀切；只协调同主题同次更新/同报告版本，
  事件优先；claim 串行；事件语义键在 workspace 允许后才 claim。
- AppDelegate 注入真实 checker；automation start/stop 幂等，2 秒合并，
  generation 防旧任务；`researchWorkspaceChanged` 不触发 reconcile。
- 旧通知键/路由保留，`subjectID` 只新增；docs/README 明确监测不自动 AI。

## 2. 实际接口

### 2.1 RSS 检查与共享 budget

```swift
@MainActor final class WorkspaceUpdateChecker: WorkspaceUpdateChecking {
    static let shared: WorkspaceUpdateChecker
    init(
        controllerProvider: @escaping @MainActor () -> NewsEventController = { .shared },
        store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        researchStore: any ResearchPersisting = ResearchStore.shared,
        matcher: WorkspaceLeadMatcher = WorkspaceLeadMatcher(),
        maxFeedsPerCheck: Int = 1,       // 8 is the ceiling
        throttle: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    )
    func check(subjectID: String, sources: [NewsSource], now: Date)
        async -> WorkspaceUpdateCheckResult
}
```

`WorkspaceUpdateCheckResult` 新增 `coverage: WorkspaceCheckCoverage`：
检查过的源、启用源总数、延后源数、是否复用共享检查、新增数、budget
used/limit、budget 重置时间、下次可检查时间、失败重试时间。

`NewsEventController` 新增薄 broker：

```swift
func checkSharedFeed(_ source: NewsSource, now: Date)
    async -> NewsEventSharedFeedCheck
func commitSharedFeedCheck(_ cursor: NewsEventFeedCursor) async -> Bool
func recordSharedFeedFailure(sourceID: String, now: Date, message: String) async
func sharedFeedBudgetSnapshot(now: Date) async -> NewsEventBudgetSnapshot?
```

`NewsEventTracker` 实现 `checkFeed(_:now:)`，返回：

```swift
enum NewsEventSharedFeedCheck: Sendable {
    case reused(cursor:budget:)
    case notModified(cursor:budget:)
    case modified(evidence:cursor:budget:)
    case pending(budget:reason:)
    case throttled(until:budget:reason:)
    case failed(message:retryAt:budget:)
}
```

行为：

- 只接受 `.rss`；调用方只传 `settings.activeSources` 中启用的 RSS。
- `cursor.retryAfter > now` 直接 throttled，不绕过退避。
- 90 秒内已完成的共享检查直接 reused，不再花 budget；checker 会从同一
  source 已落盘的 event 证据（24 小时内、排除 research 证据）匹配当前
  subject 并保存 leads，不再假称 0 资料。
- 条件请求成功后：`modified` 返回 evidence + 新 cursor；`notModified`
  返回 304 cursor；两者都由 checker 在证据/线索落盘后调用
  `commitSharedFeedCheck`。
- 成功 fetch 到 ack 之前，同一 source 的 budget 槽保持占用；并发
  `checkFeed` 返回 `pending`，`tick` 排除 pending source 并报 deferred。
  commit/failure/cancel 都会 ack 释放；120 秒无 ack 的 pending 安全过期。
- 网络失败保存 `failureCount`/`retryAfter`（5/10/20/40/60 分钟），并返回
  准确重试时间。
- checker 保存 workspace 线索失败或 `controller.ingest(evidence)` 失败时
  调用 `recordSharedFeedFailure`，cursor 不前进，避免丢资料。
- 只有真实 304/modified 才把 source 写入 `checkedSourceIDs`；reused、
  pending、throttled、failed 不会冒充“已完成覆盖”。
- candidate id 统一为 `WorkspaceUpdateCandidate.identity(subjectID:url:)`
  （subject + canonical URL）；store 会把旧 id 规范化、按 canonical 去重并
  保留最早 `discoveredAt`，pending id 也同步重映射。

### 2.2 自动归集

```swift
@MainActor final class WorkspaceAutoDiscovery {
    static let shared: WorkspaceAutoDiscovery
    func fullReconcile(now: Date) async -> WorkspaceReconcileResult
    func ingestResearch(recordID: String, now: Date) async -> String?
    func ingestEvents(now: Date) async -> Set<String>
    func ingestRSSItems(_ items: [NewsItem], now: Date) async
    func applyUpdateCandidates(_ candidates: [WorkspaceUpdateCandidate],
                               subjectID: String, now: Date) async
}
```

- `fullReconcile` 从完整 record 收集报告证据 canonical URL 与 seed URL，
  传 `evidenceURLsByRecordID`；显式 record/event ID 仍由 reconciler 处理。
- `ingestResearch` 只链接，不设置 `isFollowed`。
- `ingestEvents` 在全量关联后，如果事件最新证据晚于关联报告
  `generatedAt`，设置 `needsReview`，不启动研究。
- `ingestRSSItems` 只匹配 `isFollowed && !isArchived && kind != .event`，
  去重后 `saveUpdates`；不建主题、不联网。
- 自动话题仍不按标题合并两个不同时间的 event-backed subject。

`NewsOrchestrator` 在 RSS batch 与单源刷新成功、`evidenceDurable` 后，
仅对 `outcome.changed` 的 feed items 调用 `ingestRSSItems`。

### 2.3 研究 finalize observer

```swift
@MainActor final class WorkspaceResearchObserver: ResearchResultObserving {
    static let shared: WorkspaceResearchObserver
    func researchWillOverwrite(_:nextReport:) async -> Bool // true, version layer owns it
    func researchDidFinalize(_:previous:) async // link + activity only
}
```

`WorkspaceAutomationService.start` 调用
`coordinator.setResultObservers([WorkspaceResearchObserver.shared])`；
`ResearchCoordinator` 继续保留内建版本 observer，并先跑 event ingest 再跑
notifier。

### 2.4 通知协调

```swift
@MainActor final class WorkspaceNotificationCoordinator {
    static let shared: WorkspaceNotificationCoordinator
    func subjectID(forRecordID:) async -> String?
    func subjectID(forEventID:) async -> String?
    func authorizeEvent(eventID: String, at: Date, causalToken: String? = nil)
        async -> WorkspaceNotificationDecision
    func recordEventNotified(eventID: String, at: Date, causalToken: String? = nil) async
    func claimResearch(recordID: String, at: Date)
        async -> WorkspaceNotificationDecision
    func claim(subjectID:kind:at:) async -> WorkspaceNotificationDecision
    func reset()
}

enum WorkspaceNotificationDecision: Equatable, Sendable {
    case allowed(subjectID: String?)
    case suppressed(reason: String)
}
```

- 所有 claim 走 MainActor 串行队列（`isProcessing` + continuation waiters），
  避免跨 await 重入的 read+write race。
- event 先 `authorizeEvent`，workspace 拒绝时直接持久化说明并 return，
  **不 claim** `NewsEventStore.claimNotification` 的语义键。
- 允许后 controller 先 claim 事件键，再发送；发送被系统接受后
  `recordEventNotified` 写入 `lastNotifiedAt/kind/reference`。
- research 完成：同 report 版本（digest + generatedAt）不重复；研究证据携带
  `WorkspaceResearchCausalToken`，事件通知若由同一报告版本触发就记录该 token，
  research completion 仅在 token 完全相同时抑制（包括 manual）。不同版本或
  无关进展不做时间窗口抑制。
- 归档主题拒发并说明；不删除旧证据；取消归档后新进展恢复提示。
- workspace save 失败时 fail-open 到通知，并保留内存 fallback，不静默丢失。
- `WorkspaceSubject` 新增可选 `lastNotifiedReference`（旧 JSON 缺省 nil），
  `saveAll` 的 user-state adopt 已包含它。

`NotificationService.sendNewsEventAlert` / `sendResearchNotification` 增加
可选 `subjectID`，payload 继续保留 `type`、`eventID` / `recordID`；
`NotificationClickRouter` 未改。

### 2.5 生命周期与统一启动器

```swift
@MainActor final class WorkspaceAutomationService {
    static let shared: WorkspaceAutomationService
    func start(orchestrator: NewsOrchestrator, settings: AppSettings) // idempotent
    func stop() // idempotent
}
```

- start：一次 `fullReconcile` → `orchestrator.refreshResearchSummary()`；
  注册结果 observer/notifier；监听 `.researchRecordsChanged`、
  `.newsEventsChanged`；2 秒合并；generation 防旧任务。
- `.researchWorkspaceChanged` 只观察不触发 reconcile，避免 saveAll 风暴。
- 重复相同输入不落盘：reconcile 仅在 changed/created/count 变化时 `saveAll`。
- `AppDelegate` 在 `settings` 创建后启动 automation；terminate 调 `stop()`；
  `openResearchWorkspace` 注入 `WorkspaceUpdateChecker.shared`。
- 旧通知点击读取 payload `subjectID`，再回退 record/event 解析；
  `.newsEvent` / `.research` / `.burst` 都落到 `openResearchWorkspace`。
- `ResearchWorkspaceModel.handleNotification` 会校验传入 subjectID 是否存在，
  避免旧/错误 subjectID 打开空窗口。

### 2.6 研究入口统一

`WorkspaceResearchRequest` 新增：

```swift
var notify: Bool
var recordID: String?
var allowReuse: Bool
var allowsIncremental: Bool
```

`WorkspaceResearchLauncher` 新增：

```swift
func start(recordID: String, request template: WorkspaceResearchRequest)
    async -> WorkspaceResearchAction
```

`NewsOrchestrator.scheduleResearch` 不再直接调用
`ResearchCoordinator.schedule`，改为经 launcher；自动/关键词传
`notify: settings.burstPushEnabled`、`allowReuse: false`、
`allowsIncremental: false`；手动传 `notify: true`。自动研究仍先经过
`automaticBudgetAllows`、`ResearchAutoAdmission`，launcher 后 coordinator
仍检查 `isAllowed`、queue limit 与自动 admission。

## 3. 界面与文案

- `ResearchWorkspaceModel.activeRSSSources` 只取启用 RSS；检查按钮、
  availability、实际传给 checker 的 sources 三者一致。
- 检查后显示实际覆盖：`已检查 1/N 个源，新增 M 条；预算 U/L；下次 …`；
  复用共享检查、延后源、失败重试时间、已保存线索数都有独立文案。
- 概览的 check 状态改用 `lastCheckOutcome.checkedAt`，失败也能显示时间。
- 关注按钮/侧栏增加帮助：关注只会收集 RSS 线索，不会自动 AI/扩大监控。
- 归档主题显示“停止收集与通知、旧证据保留、取消归档恢复”。
- 设置事件区文案已明确“打开研究工作台”；README 中英文与
  `docs/research-center.md`、`docs/research-center.zh-CN.md` 已同步新 UX、
  迁移路径与“监测不自动 AI、用户显式研究例外”。

## 4. 文件清单

新增：

- `Sources/NewsBar/Services/Workspace/WorkspaceUpdateChecker.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceAutoDiscovery.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceResearchObserver.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceNotificationCoordinator.swift`
- `Sources/NewsBar/Services/Workspace/WorkspaceAutomationService.swift`

修改：

- `Services/Events/NewsEventTracker.swift`（`checkFeed` 与共享失败退避）
- `Services/Events/NewsEventController.swift`（check/commit/failure/budget broker）
- `Services/NotificationService.swift`（additive `subjectID`）
- `Services/NewsOrchestrator.swift`（RSS 线索收集 + 统一 launcher）
- `Services/Workspace/WorkspaceResearchLauncher.swift`
  （`notify`/`recordID`/reuse/incremental + record 入口）
- `Models/ResearchWorkspace.swift`（coverage、request 字段、通知 reference）
- `Services/Workspace/WorkspaceSubjectStore.swift`（通知 reference 用户状态）
- `Views/Workspace/ResearchWorkspaceModel.swift`（启用 RSS、coverage notice）
- `Views/Workspace/WorkspaceOverviewPane.swift`（coverage/归档说明）
- `Views/Workspace/WorkspaceDetailView.swift`、`WorkspaceSidebar.swift`
- `AppDelegate.swift`（automation 生命周期、checker 注入、通知路由）
- `Models/Localized.swift`、`README.md`、`README.zh-CN.md`、docs

文档：`stage-4-automation.md` Rulings、`progress.md`、本报告。

## 5. 构建

```
$ swift build
Build complete! (9.41s)   # F1–F3 语义修正后的完整构建
Build complete! (0.19s)   # 最终无源码变化的确认构建
EXIT=0
```

日志：`.build/unified-research-final-automation-build.log`。最终 0 error；
本 feature 新增/修改文件无新增 warning（剩余为既有 Swift 6 /
actor-isolation 提示）。

F1–F3 收口后已重新构建通过：共享检查复用会补匹配已落盘证据；budget 槽持有
到 cursor commit；通知按 causal token 去重。未执行：`swift test`、任何测试
二进制、baseline、独立评审、启动 app、网络或付费 API、
commit/push/release/新增依赖。

## 6. 风险与偏差

1. **无运行时验证**：所有交互、通知投递、RSS 检查与预算行为只通过编译与
   代码审阅验证；首次运行仍需看 1040 pt 分栏、长报告滚动、通知点击定位。
2. **手动检查会共用事件 ingest**：为了不因共享 cursor 让事件发现丢资料，
   checker 在提交 cursor 前调用 `controller.ingest(evidence)`。这意味着手动
   检查可能创建事件并按既有事件通知策略投递事件通知；这是有意的共享语义，
   但未在真实通知权限下验收。
3. **一次只查 1 个源**：UI 会显示覆盖与延后数量；用户若期待一次扫完所有
   启用源，需要多点几次或等待后续刷新。这是保护 12/h 预算的保守取舍。
4. **full reconcile 会读取报告 record 以收集证据 URL**：大量历史记录时
   每次 record/event 通知的 2 秒合并任务可能变慢；未做大库性能测量。
5. **workspace 写竞争**：store actor 串行化单次写入，但 reconcile 快照与
   checker/观察者并发时，理论上仍可能以旧快照覆盖 `updateState`；已让
   ingestion 重新读取当前 subject，但没有运行时并发压测。
6. **通知协调的归档语义**：归档时事件语义键不 claim，取消归档后新证据可
   继续通知；同一事件本身不会自动重发。该行为只按代码路径核对，未做真机
   通知验收。
7. **测试目标未编译**：`NewsEventTracking` 协议新增 `checkFeed`，测试 double
   若存在需要补方法；本次按验证策略只 build app target，未运行测试。
8. **未 commit/push/release**，工作区保留全部改动供主代理最终自查。
