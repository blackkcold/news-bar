# Stage 3 Report — Workspace UI and Entry Points

**Branch:** `feat/unified-research-workspace`
**Worktree:** `/Users/11169285/.local/share/opencode/worktree/2c2cb18db9ec202ac5ec607efad1feaa54f77c57/unified-research-workspace`
**Plan:** `docs/superpowers/plans/unified-research/stage-3-workspace.md`
**Date:** 2026-11-16
**Status:** 代码完成，最终 `swift build` exit 0。**未运行测试、未启动 app、未联网、未调用业务 API、未提交/推送/发布。**

## 0. Final same-stage acceptance U1–U3

These were recorded in `stage-3-workspace.md` / `progress.md` before code.

- **U1 continuous reading.** Added session-only
  `WorkspacePresentationStore` keyed by canonical subject ID. It stores segment,
  selected report version, research depth and one stable scroll anchor per
  segment. `ResearchWorkspaceModel.select` now canonicalizes retired IDs and
  migrates state (`presentation.migrate(from:to:)`); refresh follows a redirected
  selected ID and keeps the preferred record. `WorkspaceDetailView` no longer
  owns a global `@State segment`; `WorkspaceResearchPane` no longer owns
  subject-independent `selectedVersionID` / `depthChoice`. New versions do not
  replace a selected historical version; an explicit `查看最新` clears the
  selection. Each pane uses macOS 15 `scrollPosition(id:)` + stable section/row
  IDs and a per-subject anchor; only the current subject's panes are mounted.
- **U2 search location.** `WorkspaceEvidenceFocus` carries result ID, canonical
  URL, quote hint and title through `ResearchWorkspaceModel` and
  `AppDelegate.openResearchWorkspace(..., evidenceHint:)`. Evidence results
  select the subject, set the evidence segment, scroll to the matching real row
  (canonical URL first, quote/snippet second) and highlight it for ~2.2 s. A
  missing/expired item gets `workspace.search.evidenceMissing`; a missing owner
  subject gets `workspace.search.evidenceSubjectMissing`. Report results keep
  their specific record and reset only that subject's version selection; answer
  results still only replay the archive. Read-only still allows reading/search;
  mutating actions remain disabled.
- **U3 narrow header.** The whole header now uses `ViewThatFits` with two full
  layouts: wide one row (title block capped 250–310 pt + actions) and narrow
  title/meta full width with actions on a second row. At 1040 pt the detail
  column falls to the second layout; the title cannot be squeezed to a few
  characters and buttons cannot overflow horizontally. Aliases are capped at
  two truncated chips with help; last-activity truncates with the full time in
  help. Body text remains 13/12 pt. Follow/archive still use
  `updateSubject(id:mutation:)`; the real `WorkspaceUpdateChecker`, first-click
  availability, coverage/budget notices remain. Themes and accessibility labels
  are unchanged; no Liquid Glass or new visual language.

Build verification for this follow-up (test target compiled, never executed):

```
$ swift build --build-tests
Build complete! (43.08s)
EXIT=0

$ swift build --build-tests   # after removing one unused-binding warning
Build complete! (9.88s)
EXIT=0

$ swift build --build-tests   # final after layout/location cleanup
Build complete! (10.32s)
EXIT=0

$ swift build --build-tests   # final after per-subject depth cleanup
Build complete! (15.05s)
EXIT=0

$ swift build --build-tests   # final after redirect-state merge cleanup
Build complete! (9.66s)
EXIT=0
```

Log: `.build/unified-research-final-build.log`. No test binary, app, network or
business API was run. UI behavior (including exact scroll restoration across
A→B→A) is **not runtime-verified**.


## 1. 先于代码的 UX 裁决

已写入 `stage-3-workspace.md` 的 `## Rulings (Stage 3)` 与
`progress.md` 的 `## Stage 3 rulings`：

- **R1** 主题列表与详情是一体化画布；固定五个筛选
  `全部/关注中/有更新/待核查/归档`；默认 1180×780、最小 1040×680；
  侧栏 220 + 列表 300 + 详情 ≥480；工具栏溢出而不是截断；沿用
  retroEditorial/现代主题、明暗色、现有密度与 SF Symbols，不做巨型空白卡
  或营销彩色卡。
- **R2** 报告不是摘要卡：最新与历史版本都完整显示
  summary/overview/claims/verdict/conflicts/missing/limitations、逐字引文与
  可追溯引用；保留复制 Markdown 与取消运行；旧 origin/burst/keyword 只作
  元信息；事件/研究证据合并展示但保留出处；研究来源与通知主体计数分开。
- **R3** 切分段、后台刷新、切主题保留选择、各分段滚动与历史版本；record
  深链定位到具体记录及其版本，event 深链定位主题。
- **R4** 查找默认本地、输入不联网；200 ms 去抖；显式网页按钮才联网；网页
  结果只作未核实 lead，可加入当前主题或新建主题；历史问答回放完整答案。
- **R5** 所有入口只打开 `openResearchWorkspace`；Dashboard 并排中心入口去掉
  用户可见重复，保留 callback；设置“打开事件工作台”映射到统一工作台并优先
  最近事件主题；旧视图保留编译但不再是窗口 root。
- **R6** 所有手动研究经 `WorkspaceResearchLauncher`，先过
  `ResearchConsent`；共享 in-flight 去重，不用按钮 disabled 充当去重。
- **R7** 新主题可带可选 `seedURL`，存到 `WorkspaceSubject` 的兼容元数据；
  不改 Record/Event encoded shape；不自动 AI、不编造微博 URL。
- **R8** 有 RSS 源时首次检查可点击（不再被默认 `.notConfigured` 永久禁用）；
  stage 4 checker 为 nil 时明确“待配置”但保留注入点；`hasUpdates` 也提示更新；
  缺 AI key/consent 给出可操作引导；depth 菜单控制真实 `request.depth`，
  force 是完整重新检索。
- **R9** 搜索/详情 revision 守卫；索引只建一次并按合并后的 store 通知更新；
  reconcile 只在有变化时 `saveAll`；重计算不逐键/不全盘扫描。
- **R10** 加载/无主题/空筛选/无结果/私域阻断/错误/忙碌/只读分别有状态；
  不支持 schema 显示只读 banner；方向键不抢表单光标；⌘N/⌘F/⌘1–5/Escape
  与归档确认/撤销可用；稳定 ForEach ID、无障碍标签、Reduce Motion；不自动加
  Liquid Glass。

## 2. 实际接口

### 2.1 工作台模型与筛选

```swift
enum WorkspaceFilter: String, CaseIterable, Identifiable, Sendable {
    case all, following, updated, review, archived
    var titleKey: String
    var symbol: String
    func matches(_ subject: WorkspaceSubject) -> Bool
}

enum WorkspaceSort: String, CaseIterable, Identifiable, Sendable {
    case activity, created, title
}

enum WorkspaceSegment: String, CaseIterable, Identifiable, Sendable {
    case overview, timeline, evidence, research
}

enum WorkspacePrimaryAction: Equatable, Sendable {
    case none, start, active, update, view
}

enum WorkspaceUpdateCheckAvailability: Equatable, Sendable {
    case ready, noSources, pendingChecker
}

struct WorkspaceActionNotice: Identifiable, Equatable, Sendable {
    enum Tone { case info, error }
    let id: UUID
    let message: String
    let tone: Tone
    let subjectID: String?
    var action: WorkspaceNoticeAction?
}
```

`@MainActor @Observable final class ResearchWorkspaceModel` 的实际构造：

```swift
init(
    orchestrator: NewsOrchestrator,
    settings: AppSettings,
    store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
    coordinator: ResearchCoordinator? = nil,          // resolved to .shared on main
    eventController: NewsEventController? = nil,      // stage-4 injection point
    updateChecker: (any WorkspaceUpdateChecking)? = nil, // stage-4 injection point
    launcher: WorkspaceResearchLauncher? = nil,
    search: WorkspaceSearchService? = nil,
    researchStore: any ResearchPersisting = ResearchStore.shared,
    eventStore: any NewsEventPersisting = NewsEventStore.shared
)
```

提供 `load/refresh/select/searchAll/searchWeb/openSearchResult/createSubject/
toggleFollow/setArchived/checkUpdates/startResearch/cancelActiveResearch/
openRecord/openEvent/handleNotification/replayAnswer/saveWebHit`，以及
`primaryAction`、`updateCheckAvailability`、`canCheckUpdates`、`reusePreview`、
`activeSubjectIDs`、`isReadOnly` 等只读状态。详情分段仍是视图 `@State`，
模型只发 `segmentRequest` 深链提示。

### 2.2 数据兼容扩展

```swift
struct WorkspaceSubject {
    // 新增可选字段；旧 JSON 缺省为 nil，Record/Event 编码未改
    var seedURL: String? = nil
}
```

- `WorkspaceSubjectStore.save` 在单主题写入时保留已存 `seedURL`，避免旧快照
  把它清掉。
- `WorkspaceResearchLauncher.makeSeed` 在无显式 seed/事件证据时使用
  `subject.seedURL`（经 `ReaderNavigationPolicy` 校验）；否则保持无 seed，
  不伪造微博首页。
- 新增 `WorkspaceReusePreview` 与
  `WorkspaceResearchLauncher.reusePreview(subjectID:depth:)`，只读预测复用，
  不产生任务。
- `NewsEventStore.commit` 新增 `.newsEventsChanged` 通知，供工作台合并刷新；
  事件文件 shape 未变。

### 2.3 窗口与入口

```swift
@MainActor
func openResearchWorkspace(
    subjectID: String? = nil,
    researchID: String? = nil,
    eventID: String? = nil,
    answerID: String? = nil,
    startResearchDepth: ResearchDepth? = nil
)

@MainActor func openResearchCenter(selecting recordID: String? = nil) // wrapper
@MainActor func openNewsEventMonitor(eventID: String? = nil)          // wrapper
@MainActor func openBurstWindow(title: String)                        // wrapper
```

- `openResearchWorkspace` 复用活窗口；record/event 深链先解析 subject，缺链接时
  先完整 reconcile 再打开，避免旧通知落在空窗口。
- `.researchRequested` 由 `openWorkspaceResearch(for:)` 建/复用一个 followed
  subject，把页面 URL 写入 `seedURL`，再由统一 launcher 启动；不再调用
  `orchestrator.startManualResearch`。
- 设置“打开事件工作台”仍发 `.newsEventMonitorRequested`，现在落到
  `openNewsEventMonitor` → 最近事件 subject。
- 新增 `.openAISettingsRequested` / `.openRSSSettingsRequested` 通知，供
  无 key/RSS 的引导按钮打开设置。
- 窗口关闭、`applicationWillTerminate`、Dock 存在判断、刷新可见性判断、
  清空兴趣数据均已纳入 workspace 窗口。

### 2.4 阅读器 ⌘K

```swift
enum QuickSearchResult {
    case news(NewsItem)
    case readerHistory(ReaderHistoryEntry)
    case archive(AISearchArchiveEntry)
    case workspace(WorkspaceSearchResult)      // new
}

QuickSearchModel.searchLocal(
    query:newsItems:readingHistory:archiveEntries:
    workspaceResults: [WorkspaceSearchResult] = []  // appended, deduped, max 8
)
```

- `QuickSearchContent` 新增
  `onOpenWorkspaceResult: (WorkspaceSearchResult) -> Void`，用可取消的
  `.task(id: model.query)` 做 200 ms 去抖后取本地 workspace 结果；不联网。
- 工作台结果在一个 `研究` 小标题下按 主题/报告/证据/历史问答 展示，行有
  “在研究中心打开”上下文菜单；答案只回放归档，不建主题。
- `ReaderAuxiliaryRail` / `NewsReaderView` / `DashboardWindow` / AppDelegate
  已贯通回调；⌘K 快捷键绑定未改。
- 阅读器研究侧栏的工具栏“联网核查”已移除，只保留侧栏内“对当前页面发起
  核查”，两者不再等价重复。

## 3. 界面结构

- `ResearchWorkspaceView`：`NavigationSplitView` 侧栏/列表/详情，
  1180×780（min 1040×680），`.adaptiveColorScheme()` + `.appThemeSurface()`。
- `WorkspaceSidebar`：标题/副标题、五筛选实时候选计数、新建主题、存储/只读
  状态。
- `WorkspaceSubjectList`：搜索（⌘F）、排序、主题行、四类搜索结果、显式
  `在网页中查找`、网页结果与“加入当前主题资料/新建主题并加入”。
- `WorkspaceSubjectRow`：标题、1 个别名、最近活动、状态点与
  `待核查/有更新/研究中`、关注 pin；指标不在行内。
- `WorkspaceDetailView`：头部（标题/别名/类型/最近活动/关注/检查更新/主操作/
  溢出菜单）+ 恰好四个分段，分段以 ZStack 常驻保留滚动。
- `WorkspaceOverviewPane`：事件摘要与 claims/冲突、最新报告 verdict/摘要、
  待核查资料、两个独立指标 chip、检查状态、下一步。
- `WorkspaceTimelinePane`：事件/研究合并、来源徽章、置信度、`时间未知` 组底。
- `WorkspaceEvidencePane`：标题/来源/日期/来源类型/引文核验/立场/等级/
  事件共享标记；点击经安全策略打开；空态跳转报告。
- `WorkspaceResearchPane`：当前运行状态与取消、完整报告、历史版本（只读）、
  depth 菜单、force 重研、复制 Markdown、复用提示。
- `WorkspaceReportBody`：summary/overview/claims/verdict/conflicts/missing/
  limitations/逐字引文/可点击来源；最新与历史同构。
- `WorkspaceNewSubjectSheet`：标题必填、别名最多 8、可选 seed URL 校验、
  创建不启动 AI 的说明。
- `WorkspaceActionNotice`：info/error、自动消失、配置 AI/RSS、归档撤销。

## 4. 构建与验证

```
$ swift build        # 第一次（全部改动后）
EXIT=1
# 5 处 `?? (await ...)` autoclosure 错误 + 1 处 AppDelegate 同类错误

$ swift build        # 修正后
EXIT=0

$ swift build        # 深链/读卡/提示等语义修正后
EXIT=0

$ swift build        # 最终（全部语义修正后）
Build complete! (8.35s)
EXIT=0

$ swift build        # 收尾确认（无源码变化，0.21s）
Build complete! (0.21s)
EXIT=0
```

日志：`.build/unified-research-stage3-build.log`。最终 0 error；新增
`Views/Workspace/*` 0 warning；`AppDelegate` 只余既有同步上下文的
DockPresence/assumeIsolated warning，没有新增 workspace 文件 warning。

未执行：`swift test`、任何测试二进制、baseline、专项/独立 review、启动 app、
网络或付费 API、commit/push/release/新增依赖。

## 5. 需求对照（自检）

| 验收项 | 实现 |
|---|---|
| 一个窗口；五个筛选计数 | `ResearchWorkspaceView` + `WorkspaceFilter` |
| 四个详情段，无旧页面 tab | `WorkspaceSegment` 四段 + 四 Pane |
| 新建/关注/归档/研究/查看 | `WorkspaceNewSubjectSheet`、`toggleFollow`、`setArchived`、`startResearch`、`primaryAction` |
| RSS-only 检查状态诚实 | `updateCheckAvailability`、`.notConfigured` 不永久禁用、nil checker 待配置 |
| 报告完整可读/历史版本/复制 | `WorkspaceReportBody`、版本选择、`WorkspaceReportMarkdown` |
| 取消 active | `cancelActiveResearch` |
| 深链 record/event/version | `openRecord`、`openEvent`、`preferringRecordID`、`segmentRequest` |
| 本地优先搜索/200ms/revision | `scheduleSearch`、`QuickSearchContent.task(id:)` |
| 显式网页 + lead 保存 | `searchWeb`、`saveWebHit`、`saveWebHitAsCandidate` |
| 历史答案回放 | `replayAnswer` + `AnswerDocumentView` |
| Dashboard/popover/settings/reader/通知统一 | 所有路径落到 `openResearchWorkspace`；旧 view 仅注释保留 |
| Dashboard/BottomBar 去重 | 可见事件按钮移除，callback 保留 |
| 研究 chip 指向未读 | `workspaceUnreadResearchSubjectID` |
| 单 launcher + consent | `openBurstWindow`/`.researchRequested`/pane 全部走 `WorkspaceResearchLauncher` |
| seedURL 持久且不编造 | `WorkspaceSubject.seedURL` + launcher seed |
| 指标不合并 | `研究独立来源` / `通知主体` 两个 chip |
| 键盘/无障碍/减弱动态 | ⌘N/⌘F/⌘1–5/⌘⌫/⌘R/⌘↩/Escape、标签、Reduce Motion |
| 只读/损坏/不支持 schema | `WorkspaceBootstrap.issue/readOnly` banner |

## 6. 文件清单（本阶段）

新增（14）：

- `Sources/NewsBar/Views/Workspace/ResearchWorkspaceModel.swift`
- `ResearchWorkspaceView.swift`
- `WorkspaceSidebar.swift`
- `WorkspaceSubjectList.swift`
- `WorkspaceSubjectRow.swift`
- `WorkspaceDetailView.swift`
- `WorkspaceOverviewPane.swift`
- `WorkspaceTimelinePane.swift`
- `WorkspaceEvidencePane.swift`
- `WorkspaceResearchPane.swift`
- `WorkspaceReportBody.swift`（计划外拆分：完整报告/共享组件/Markdown）
- `WorkspaceNewSubjectSheet.swift`
- `WorkspaceActionNotice.swift`
- `WorkspacePresentationStore.swift`（U1：会话内按 canonical subject 保存分段/版本/深度/滚动锚点）

修改（15）：

- `AppDelegate.swift`（单窗口/所有入口/legacy 通知/设置通知/Dock/终止）
- `Models/ResearchWorkspace.swift`（`seedURL`、`WorkspaceReusePreview`）
- `Services/Workspace/WorkspaceResearchLauncher.swift`
  （seedURL seed + `reusePreview`）
- `Services/Workspace/WorkspaceSubjectStore.swift`（seedURL 保留）
- `Services/Events/NewsEventStore.swift`（`.newsEventsChanged`）
- `Views/Dashboard/QuickSearchModel.swift`
- `Views/Dashboard/QuickSearchContent.swift`
- `Views/Dashboard/ReaderAuxiliaryRail.swift`
- `Views/Dashboard/NewsReaderView.swift`
- `Views/Dashboard/DashboardWindow.swift`
- `Views/Dashboard/DashboardNewsroomBar.swift`
- `Views/MenuBar/BottomBar.swift`
- `Views/Research/ResearchCenterView.swift`（仅 legacy 注释）
- `Views/EventMonitor/EventMonitorCenterView.swift`（仅 legacy 注释）
- `Models/Localized.swift`（zh/en 全部新 key，key parity 通过脚本核对）

文档：`stage-3-workspace.md`（Rulings）、`progress.md`、本报告。

## 7. 偏差与剩余风险

1. **构建次数**：先失败一次（autoclosure async），修复后又构建三次以验证
   语义修正；不属于逐任务编译。最终一次 exit 0。
2. **计划外文件**：`WorkspaceReportBody.swift` 用于共享完整报告、章节头、
   徽章与 Markdown；避免 Overview/Research 两套报告渲染漂移。
3. **新增通知/状态**：`.openAISettingsRequested`、`.openRSSSettingsRequested`、
   `.newsEventsChanged` 是兼容性新增；`WorkspacePresentationStore` 仅会话内存，
   不写全局 memory；`WorkspaceEvidenceFocus` 只做导航定位，不写存储。
4. **stage 4 checker 仍为 nil**：工作台如实显示“更新检查尚未接入，可先配置
   RSS”，不会伪造成功；接口已就位。
5. **无 UI 运行时验证**：所有交互与布局只通过编译与代码审阅验证；首次运行需
   重点看 NavigationSplitView 在 1040 宽度的实际收缩、retro 主题下分段控件
   可读性、以及长报告滚动。
6. **搜索索引构建仍在 `@MainActor` 的 `WorkspaceSearchService` 上执行**
   （沿用 stage 2 接口），只在首次/合并通知后重建，不逐键；若首次打开大库
   感知卡顿，stage 4 可把 rebuild 移入后台 actor，不改变调用契约。
7. **每分段滚动保持依赖 ZStack 常驻**；背景刷新不会重建 Pane，但切换主题时
   内容变更可能被系统夹取滚动位置，未做显式 offset 持久化。
8. **未支持 schema 的 workspace 文件** 会只读展示且不覆盖；旧
   `ResearchCenterView`/`EventMonitorCenterView` 仍编译，但无 AppDelegate
   构造点。
9. **研究窗口的 `eventController` 目前只注入不主动 reload**；事件数据仍从
   `NewsEventStore` 读取，stage 4 可用 controller 统一刷新。

## 8. 交接给 Stage 4

可注入点（均已在生产路径留下真实参数/协议，不是 TODO 占位）：

- **RSS 检查**：`ResearchWorkspaceModel(updateChecker:)`；
  `AppDelegate.openResearchWorkspace` 目前传 `nil`。实现
  `WorkspaceUpdateChecking.check(subjectID:sources:now:)` 后替换该参数即可；
  UI 的 `checkUpdates`/首次可点击/结果 notice 已就绪。
- **通知协调**：`eventController: NewsEventController?` 已注入模型；
  `AppDelegate` 仍保留 legacy 通知路由并新增 `subjectID` 可扩展。Stage 4 可
  在 coordinator 完成 subject 关联后调用
  `openResearchWorkspace(subjectID:researchID:eventID:)`。
- **自动研究入口**：统一使用 `WorkspaceResearchLauncher`（共享 in-flight），
  不要新增第二窗口/第二 launcher；自动任务也走它并传 `.trigger/seed/depth`。
- **事件→研究报告 URL 严格链接**：`WorkspaceReconciler.reconcile` 已保留
  `evidenceURLsByRecordID` 参数，stage 4 可从完整记录填入以提升 event/research
  合并精度。
- **索引/观察合并**：模型已监听 `.researchWorkspaceChanged`、
  `.researchRecordsChanged`、`.newsEventsChanged`；新增自动化写入应继续发这些
  通知或直接调用模型 refresh，避免轮询。
