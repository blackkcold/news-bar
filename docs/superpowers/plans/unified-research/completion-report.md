# Execution Report

## Metadata
- Task ID: UNIFIED-RESEARCH-WORKSPACE-2026-11-16
- Related Task Packet: `docs/superpowers/plans/2026-11-16-unified-research-workspace.md`
- Executor: OpenCode (general agents; main agent final self-check)
- Repo: NewsBar worktree (not the main checkout)
- Worktree: `/Users/11169285/.local/share/opencode/worktree/2c2cb18db9ec202ac5ec607efad1feaa54f77c57/unified-research-workspace`
- Branch: `feat/unified-research-workspace`
- Started At: 2026-11-16 (worktree created; session moved into it)
- Finished At: 2026-11-16 15:28 CST
- Status: Done（限定实现与编译；实机 UI/通知/真实网络未运行）

## Summary

- 交付一个以“主题/事件”为长期对象的研究工作台：五个筛选
  （全部/关注中/有更新/待核查/归档）与四个详情分段
  （概览/时间线/证据/研究记录），研究作为任务与不可变报告版本，证据跨研究/事件
  合并展示但保留出处。
- 所有旧入口（popover、Dashboard、研究 chip、burst、事件监测、设置、阅读器、
  通知点击）收敛到 `openResearchWorkspace`；旧 `type`/`recordID`/`eventID`
  通知定位保留，`subjectID` 仅增量，旧 Record/Event 编码未迁移。
- 阅读器 ⌘K 增加主题/报告/证据/历史问答本地结果；输入不联网，显式“在网页中
  查找”才走搜索；答案只回放归档，不升级为证据。
- 搜索与 AI 记账收敛为一套：单一 `SearchRouter`/`ResearchCacheStore`/epoch，
  `ResearchServiceAssembly` 统一装配，`AIChatClientFactory` 区分研究
  unmetered 与其余 metered，避免双扣；缓存 key 覆盖 query/recency/language/
  maxResults/provider-set。
- 同一主题任务经 `WorkspaceResearchLauncher` 复用/去重；新证据进入增量抽取；
  报告版本不可变，归档失败保留旧报告；plain topic 不伪造微博种子，`seedURL`
  持久化。
- 公开来源指标保持“研究独立来源”与“通知主体”两个口径；RSS-only 检查共享事件
  预算与 cursor，pending 持续到 durable ack；关注主题只在既有 RSS 刷新中收线索，
  不自动 AI；通知按同报告因果 token 去重，不抑制无关进展。
- 会话内按主题保存分段/版本/depth/滚动锚点，证据结果定位并短暂高亮；1040 pt
  窄窗口使用 `ViewThatFits` 自适应。
- 未 commit、未 push、未 release、未打包替换现有 app；本轮报告任务只改文档。

## Delivery Map

| 交付项 | 代码定位 | 状态/证据 |
|---|---|---|
| 单一主题工作台：五筛选、四分段 | `Views/Workspace/ResearchWorkspaceView.swift`、`ResearchWorkspaceModel.swift`、`WorkspaceSidebar.swift`、`WorkspaceDetailView.swift` | 代码已接线；编译通过；未启动 UI |
| 全入口与旧通知兼容 | `AppDelegate.openResearchWorkspace` 及 `openResearchCenter`/`openNewsEventMonitor`/`openBurstWindow` wrapper；`Services/NotificationClickRouter.swift` 未改 | 代码已接线；旧 payload 键保留；未点击验收 |
| ⌘K 主题/事件/问答本地搜索 + 显式联网 | `QuickSearchModel.swift`、`QuickSearchContent.swift`、`WorkspaceSearchService.swift`、`WorkspaceSearchIndex.swift` | 本地搜索代码验证；未真实联网 |
| 共享 SearchRouter/缓存 + AI 工厂精确记账 | `ResearchServiceAssembly.swift`、`AIChatClientFactory.swift`、`ResearchCacheCoordinator.swift`、`SearchRouter.swift` | 单一生产图；研究 client `quota == nil`；编译通过 |
| 同任务复用 + 新证据增量抽取 | `WorkspaceResearchLauncher.swift`、`ResearchIncremental.swift`、`ResearchPipeline.swift` | 复用签名/in-flight 去重/增量路径已接线；未实跑研究 |
| 不可变报告版本；归档失败保旧 | `WorkspaceReportVersionObserver.swift`、`ResearchCoordinator.swift`（`researchWillOverwrite`） | 版本追加/旧报告保护已接线；未实跑归档失败 |
| plain topic 无伪种子；seedURL 持久 | `ResearchRecordProvisioner.ensureTopicRecord`、`WorkspaceSubject.seedURL`、`WorkspaceSubjectStore.swift`、`WorkspaceResearchLauncher.makeSeed` | 无 `https://s.weibo.com` 伪造；旧 JSON 缺省 nil |
| 研究独立来源 vs 通知主体指标分离 | `WorkspaceSourceMetricsBuilder`（`WorkspaceDetailBuilder.swift`）、`WorkspaceOverviewPane.swift` | 两个 chip；`NewsEventSourceResolver` 口径；未实机核对 |
| RSS-only 共享预算/cursor/pending durable ack | `WorkspaceUpdateChecker.swift`、`NewsEventTracker.checkFeed`、`NewsEventController` broker | 复用单 budget/单飞槽；304/modified 才记覆盖；未真实 RSS |
| 关注主题刷新采线索、不触发 AI | `NewsOrchestrator` RSS 成功路径、`WorkspaceAutoDiscovery.ingestRSSItems` | 仅 followed/non-archived/topic；不建主题、不联网 |
| 通知同报告因果 token 去重 | `WorkspaceNotificationCoordinator.swift`、`WorkspaceResearchCausalToken`、`NotificationService` additive `subjectID` | 同版本抑制、不同进展不按时间误杀；未真机通知 |
| 会话分主题 tab/version/depth/scroll + 证据高亮 | `WorkspacePresentationStore.swift`、`WorkspaceEvidenceFocus`、`WorkspaceEvidencePane.swift` | 代码接线；精确滚动/高亮未运行时验收 |
| 1040 窄窗口自适应 | `WorkspaceDetailView.swift` 的 `ViewThatFits` 双布局 | 代码接线；未启动窗口观察 |
| Final-domain F1–F6 | 原子写/`updateSubject`/force search/search invalidation/reuse identity/canonical subject | 已在同一 Stage 2 收口，见 `stage-2-report.md` |
| Final-automation A–C | 共享检查补匹配、budget 持至 ack、因果 token | 已在 Stage 4 收口，见 `stage-4-report.md` |
| UI U1–U3 | 会话呈现状态、证据定位、窄头部 | 已在 Stage 3 收口，见 `stage-3-report.md` |

## Files Changed

| File | Change Type | Summary |
|---|---|---|
| `Sources/NewsBar/Services/Research/ResearchServiceAssembly.swift` | Added | 唯一生产 router/cache/page-reader 装配 |
| `Sources/NewsBar/Services/AI/AIChatClientFactory.swift` | Added | unmetered 研究 client 与 metered 客户端工厂 |
| `Sources/NewsBar/Services/Research/ResearchCacheCoordinator.swift` | Added | 统一清缓存、epoch、限额维护 |
| `Sources/NewsBar/Models/ResearchWorkspace.swift` | Added | Subject/version/update/evidence/metrics/detail 模型 |
| `Sources/NewsBar/Services/Workspace/*.swift` | Added | Store、reconciler、launcher、search、version observer、RSS checker、auto discovery、notification、automation |
| `Sources/NewsBar/Services/Research/ResearchIncremental.swift` | Added | 增量上下文、复用签名、材料模型 |
| `Sources/NewsBar/Views/Workspace/*.swift` | Added | 单窗口、五筛选、四分段、报告体、新主题 sheet、呈现状态、证据高亮 |
| `Sources/NewsBar/Services/Search/{SearchRouter,PageReader,ManualSearchGateway}.swift` | Modified | 共享 cache/key/maxAge/ticket；PageReader provider-free 读取 |
| `Sources/NewsBar/Services/Research/{ResearchStore,ResearchCoordinator,ResearchPipeline,ResearchHistoryClearer}.swift` | Modified | workspace 路径、版本/observer/finalize、增量、clear 阶段 |
| `Sources/NewsBar/Services/Events/{NewsEventTracker,NewsEventController,NewsEventStore}.swift` | Modified | 共享 RSS check broker、budget single-flight、`.newsEventsChanged` |
| `Sources/NewsBar/Services/NotificationService.swift` | Modified | 仅 add `subjectID`；旧 payload 键不变 |
| `Sources/NewsBar/AppDelegate.swift` | Modified | 单窗口、全入口、legacy 通知、automation 生命周期 |
| `Sources/NewsBar/Views/Dashboard/{QuickSearchModel,QuickSearchContent,ReaderAuxiliaryRail,NewsReaderView,DashboardWindow}.swift` | Modified | ⌘K workspace 结果、显式网页、回调贯通 |
| `Sources/NewsBar/Models/Localized.swift` | Modified | zh/en 新 key parity |
| `docs/superpowers/specs/2026-11-16-unified-research-workspace-design.md` 等 | Added/Modified | 设计、阶段计划、阶段报告、台账 |
| `README.md`、`README.zh-CN.md`、`docs/research-center*.md` | Modified | 新工作台 UX、迁移路径、监测不自动 AI |

## Tests Run

| Command | Result | Notes |
|---|---|---|
| `swift build`（Stage 1） | Pass | `Build complete! (40.07s)`，修正 maxAge 后 `7.27s`；EXIT=0；`.build/unified-research-stage1-build.log` |
| `swift build`（Stage 2） | Pass | `11.67s`；F1–F5/F6 修正后仍 EXIT=0；`.build/unified-research-final-domain-build.log` |
| `swift build`（Stage 3） | Pass | 最终 `8.35s`；`.build/unified-research-stage3-build.log` |
| `swift build`（Stage 4） | Pass | `9.41s`，确认 `0.19s`；`.build/unified-research-final-automation-build.log` |
| `swift build --build-tests`（最终） | Pass | `Build complete! (9.66s)`，EXIT=0；app 与 test target 均编译，测试未执行；`.build/unified-research-final-build.log` |
| `git diff --check` | Pass | 无 whitespace error（主代理已执行，EXIT=0） |
| `swift test` / 测试二进制 | Not Run | 按用户明确只做必要编译，不跑基线/专项/测试 |
| 启动 app / UI 点击 / 截图 | Not Run | 未做真实交互、精确滚动、主题对比度或 1040 窗口验收 |
| 真实搜索/AI/业务 API/网络 | Not Run | 未使用用户 key，未调用付费或业务接口 |

## Build Evidence

最终日志尾部（`.build/unified-research-final-build.log`）：

```text
[8/9] Linking NewsBarPackageTests
Build complete! (9.66s)

[unified-research] swift build --build-tests EXIT=0
```

日志中仅保留既有 Swift 6 actor-isolation、Keychain 弃用等 warning；无
`error:`。test target 编译成功但没有执行任何 test case。

## Verification Boundary

- 已证明：生产源码可编译，app target 与 test target 均可构建；静态 grep 确认
  单一 router/launcher/client 装配；`git diff --check` 通过。
- 未证明：UI 实际布局与交互、通知真实投递/点击、RSS 真实请求、搜索/AI 真实
  返回、精确滚动恢复、retro 主题对比度、1040 窗口收缩、归档失败磁盘行为、
  大库吞吐。
- 因此本报告不声明“实机通过”“通知已验证”“网络搜索已验证”。

## Risks

| Risk | Level | Mitigation |
|---|---|---|
| 未启动 app/未点击 UI/未接收真实通知 | Medium | 代码与编译证据已留档；实机冒烟需用户环境，不能由本轮勾选为通过 |
| 精确滚动、分段常驻、主题对比度只做代码验证 | Medium | 设计使用 macOS 15 `scrollPosition(id:)` 与 `ViewThatFits`；待实际窗口验收 |
| 大库全量 reconcile/搜索索引构建未压测 | Medium | 已有 2 秒合并、revision/generation 防旧任务；未做性能基准 |
| 真实搜索/AI 需用户自有 provider/AI 配置 | Medium | 本轮不写 key、不联网；配置后按现有 quota/SSRF/validator 路径使用 |

## Closure Notes

- Final-domain F1–F6 已收口：durable write 先于内存/epoch/通知；原子
  `updateSubject` 与 revision 保护；force refresh 绕过搜索/页面缓存；搜索索引
  revision/coalesced reload；复用身份含 endpoint/provider；canonical subject
  合并与 retired redirect。未新增待开发项。
- Final-automation A–C 已收口：共享检查复用会补匹配已落盘证据；budget 槽持有到
  evidence+cursor durable ack；通知按同报告 causal token 去重，不做 6 小时一刀切。
- UI U1–U3 已收口：会话内主题分段/版本/depth/滚动锚点；证据结果定位并高亮；
  1040 窄头部双布局。未新增待开发项。
- 已修复项（原子写、陈旧快照、重复通知、共享 cursor 丢资料、伪种子）不再列为
  未修 bug；本报告只保留验证边界。

## Unfinished Items

- 约定开发范围无已知未完成项；实机交互与真实网络未验证。

## Recommended Next Step

- 在用户自己的 AI/RSS 配置下做一次人工冒烟：打开工作台、切换五个筛选与四个
  分段、检查 RSS、启动/复用研究、点击旧通知、验证 1040 窄窗口与滚动恢复。
  这是验收动作，不是新一轮开发。

## Need Codex Review?

- No
- Reason: 本轮按用户明确要求由主代理做最终代码自查，不派独立评审、不重跑基线/
  专项；本报告不把“未评审”写成缺陷，也不建议重新开评审门禁。

## Safety / Integrity

- 本报告任务未修改产品代码、测试代码，仅更新交付文档与台账。
- 未写入 key、完整 diff、原始长对话或业务数据。
- 未 commit、未 push、未 release、未打包替换现有 app。
