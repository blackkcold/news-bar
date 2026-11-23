# 研究报告阅读器设计

**状态**：方向 A+B 已确认，待实现  
**基线**：NewsBar v3.3.1（`origin/main` 6e83e06）  
**范围**：阅读层 UI。不改研究提示词、报告 JSON、研究流水线、通知正文 80 字上限、推荐排序。

## 1. 为什么改

推荐流「有深研」打开的浮窗是 `TransientResearchReportView`（680×720 `NSPanel`），研究中心的研究记录是 `WorkspaceResearchPane`。两处共用 `WorkspaceReportBody`，所以问题同源：

1. **结论被截断又重复。** 浮窗顶部「当前结论」来自 `ResearchNotificationSummary`，最多 80 字；往下滚又出现完整摘要。
2. **时间线不在浮窗里。** `report.timeline` 有数据，但 `WorkspaceReportBody` 不渲染；研究中心要切到另一个 tab 才能看到合并时间线。
3. **来源重复出现。** 每条主张内嵌引用卡片，文末再列全部来源；7 个来源可以膨胀成 20 多个来源块。
4. **来源默认全展开。** 每条带标题、整段引文、域名、立场、等级、打开按钮，5 行起步。
5. **没有目录。** 只能一路滚，想回看「仍待确认」或某个时间点没有落点。
6. **核验表达失真。** 「0/4」「未核验」和「6 条引文已逐字核验」同时出现，读者分不清「引文核验」和「结论置信度」。
7. **历史版本显示错误。** 浮窗 `reportContent` 使用 `record.report`，即使 `model.selectedVersion` 已设置；请求历史版本时仍显示最新报告。

## 2. 目标与非目标

### 目标

- 760×760 浮窗首屏看到完整结论 + 至少 2 个时间线节点，不用滚动。
- 时间线进入报告正文，不再依赖另一个 tab。
- 来源默认折叠成索引；引用变成 `E1` 芯片，点开是来源卡。
- 浮窗和研究中心共用同一阅读器；研究中心宽窗时来源变右侧栏。
- 核验拆成「引文核验」和「主张依据」两层，不再用 0/4 黑箱分数。
- 保留现有版本对比、新版提示、运行进度、失败/无报告/旧报告状态。

### 非目标

- 不改研究提示词、报告 JSON、`BurstResearch` 字段。
- 不改通知正文 80 字上限和通知投递逻辑。
- 不新增搜索源、图表、地图、全文搜索。
- 不在浮窗里加完整版本历史菜单；浮窗保留现有「新版报告已就绪 / 查看变化」。
- 不从摘要里用正则猜「关键事实」。
- 不重做研究中心侧栏、主题列表、依据总库。

### 反目标

- 为了简洁隐藏冲突、缺口、局限。
- 把未核验引文显示成已核验。
- 把没有结构化数据的内容伪装成「事实卡」。
- 为了来源栏牺牲 1180 默认窗口下的阅读宽度。

## 3. A+B 方案复核结论

A+B 方向成立。复核代码后需要修正 8 处，均已写入本设计：

| # | 原方案 | 复核结论 | 处理 |
|---|---|---|---|
| 1 | 结论区放「关键事实」chips | 没有结构化字段；从摘要猜会过拟合 | 改为数据可得的元信息条：节点数/跨度、来源数/域名数、引文核验数 |
| 2 | 浮窗底部「版本 V3 ▾」 | `TransientResearchReportModel` 只在局部加载 versions，没有历史列表 | 浮窗不加版本菜单；显示「更新于」，保留新版提示。版本菜单只进研究中心 |
| 3 | 研究中心 ≥1100px 出来源栏 | 默认窗口 1180，详情区约 630px，永远到不了 1100 | 按详情区宽度判断：≥820px（窗口约 1380+）才出来源栏；默认 1180 用折叠来源索引 |
| 4 | 历史版本直接显示 | 浮窗当前用 `record.report`，历史版本请求会显示最新报告 | 增加 `ResearchReportDisplay` 纯函数，按 `selectedVersion.report` 显示并用 digest 判断 `isHistorical` |
| 5 | 「研究记录」和「时间线」都改名 | 4 个分段控件里「事件时间线」过宽 | 只把「研究记录」改为「报告」；原「时间线」tab 保留，报告内的时间线独立 |
| 6 | 进入研究中心默认落在报告 | `WorkspacePresentationStore` 无法区分「没选过」和「选过概览」 | `State` 增加 `hasChosenSegment`；只在没选过且有报告时默认 `.research` |
| 7 | 核验显示「3/5 有直接依据、1 项已澄清」 | `ClaimCheck.status` 只有 supports/refutes/unclear，没有「已澄清」 | 只显示「N 项有已核验引文 / M 项待补」；冲突、缺口单独计数 |
| 8 | 点击 E1 在右栏定位 | 右栏是静态索引，芯片已有 popover；跨栏联动是额外状态 | 第一版右栏是浏览索引；E1 仍打开来源卡。跨栏定位留到后续 |

补充：`report.overview` 不再单独占一段，收进结论区的「背景与经过」折叠；这样时间线紧接结论，不被长背景推下去。

## 4. 方案

采用 **A 单栏简报式阅读器** 作为基础，**B 双栏来源栏** 只作为研究中心宽窗增强。

### 阅读顺序

```text
01 结论      完整摘要 + 数据元信息 + 仍待确认 + 背景（折叠）
02 时间线    节点、日期、细节、E1 引用芯片；核验覆盖
03 核验      主张账本、冲突、缺口、局限
04 来源      默认折叠；展开后按域名分组
```

### 浮窗

```text
┌──────────────────────────────────────────────┐
│ 海湾线周末夜班试行                  [在研究中心打开] [⋯] │
│ 部分核实 · 更新于 11/22 10:40 · 7 个来源 · 4 个域名      │
├──────────────────────────────────────────────┤
│ 01 结论   02 时间线   03 核验   04 来源        │  ← 固定
├──────────────────────────────────────────────┤
│ ScrollView                                    │
│  结论 → 时间线 → 核验 → 来源（折叠）            │
└──────────────────────────────────────────────┘
```

- 默认 760×760，最小 620×560。
- 固定头部 + 固定 01–04 导航；只有正文滚动。
- 顶部不再显示 80 字通知结论。
- 「本次变化」放在正文滚动区顶部，不占固定高度；更新提示仍在头部。
- `E1` 芯片打开现有 `ResearchEvidenceChip` 的 popover。
- 「在研究中心打开」用回调进入 workspace，并保留当前记录。

### 研究中心

```text
主题头（标题/关注/检查更新/查看报告）
运行条（状态/检索数/版本菜单）        ← 固定
01 结论  02 时间线  03 核验  04 来源    ← 固定
ScrollView（同一阅读器）
底部操作条（开始/更新/深度/复制）        ← 固定
```

- 「研究记录」tab 改名为「报告」；分段顺序保持现状（概览 / 时间线 / 依据 / 报告），不重排。
- 「时间线」tab 保留，仍是事件 + 研究的合并时间线；报告内的时间线是报告自身的时间线。
- 版本列表从正文顶部收进运行条右侧菜单；历史版本仍只读，可一键回最新。
- 进入时如果从未选过 tab 且已有报告，默认落在「报告」。
- 详情区 ≥820px 时：右侧 220px 来源栏，阅读器隐藏 04 来源段；否则阅读器保留折叠来源段。

### 引用交互

- 时间线节点、主张、来源索引统一使用 `E1` 编号。
- 时间线和主张里的 `E1` 复用 `ResearchEvidenceChip`：点击弹出来源卡（标题、域名、逐字引文、核验状态、打开原文）。
- 来源索引行用 `DisclosureGroup`：展开显示引文、立场、等级和打开按钮；默认收起。
- 打开原文走 `NewsNavigationRouter.shared.open`，不改现有路由。

## 5. 数据映射

| UI | 数据 | 说明 |
|---|---|---|
| 结论 | `report.summary` | 完整显示，不截断 |
| 元信息 | `ResearchReportMetrics(report:)` | 节点数/跨度、来源数/域名数、引文核验数 |
| 仍待确认 | `verification.missing` | 首屏显示前 2 项 + 总数；完整列表在 03 |
| 背景 | `report.overview` | `DisclosureGroup`，默认收起 |
| 时间线 | `report.timeline` + `ReportPresentation` | 节点状态沿用 verified/citedUnverified/unsourced |
| 主张 | `verification.claims` | 每条显示状态图标、引文数；展开显示 note + chips |
| 引文核验 | `evidence.quoteVerified` | `verifiedQuoteCount / evidenceCount` |
| 主张依据 | `claim.evidenceIDs` 是否命中已核验 evidence | `claimsWithVerifiedEvidenceCount` |
| 冲突/缺口 | `verification.conflicts` / `.missing` | 分别计数，可展开 |
| 局限 | `report.limitations` | 03 底部小字 |
| 来源 | `report.evidence` | 按 `domain` 分组，组内按 `id` 排序 |
| 独立来源 | `verification.independentSources` | 元信息条 |
| 更新时间 | `report.generatedAt ?? record.updatedAt` | 浮窗头部 |
| 版本 | `WorkspaceReportVersion.sequence` | 仅研究中心版本菜单 |

### 指标定义

```swift
struct ResearchReportMetrics: Equatable, Sendable {
    let evidenceCount: Int
    let verifiedQuoteCount: Int
    let domainCount: Int
    let claimCount: Int
    let claimsWithVerifiedEvidenceCount: Int
    let claimsNeedingEvidenceCount: Int
    let conflictCount: Int
    let missingCount: Int
    let timelineNodeCount: Int
    let timelineSpanDays: Int?
    let independentSourceCount: Int
}
```

- `claimsWithVerifiedEvidenceCount`：`claim.evidenceIDs` 中至少一个命中 `quoteVerified == true` 的 evidence。
- `claimsNeedingEvidenceCount = claimCount - claimsWithVerifiedEvidenceCount`。
- `timelineSpanDays`：只使用 `TimelineNode.sortDate`；没有日期则 `nil`。
- 不再使用 `verification.strength` 作为主展示。

## 6. 组件与文件

### 新增

- `Sources/NewsBar/Views/Workspace/ResearchReportMetrics.swift`
  - `ResearchReportMetrics`
  - `ResearchSourceGroup`
  - `ResearchSourceGrouping.groups(for:)`
  - `ResearchReportDisplay.report(selectedVersion:record:)` / `.isHistorical(...)`
- `Sources/NewsBar/Views/Workspace/ResearchReportReader.swift`
  - `ResearchReportSection`
  - `ResearchReportReader`（固定导航 + ScrollView + 章节偏移跟踪）
  - `ResearchReportNavigator`
  - `ResearchReportSectionOffsetKey`
- `Sources/NewsBar/Views/Workspace/ResearchReportSections.swift`
  - `ResearchReportConclusionSection`
  - `ResearchReportTimelineSection`
  - `ResearchReportVerificationSection`
  - `ResearchReportSourceSection`
  - `ResearchSourceRow`
- `Sources/NewsBar/Views/Workspace/ResearchSourceRail.swift`（Phase B）
- `Tests/NewsBarTests/ResearchReportMetricsTests.swift`
- `Tests/NewsBarTests/ResearchReportReaderRenderingTests.swift`
- `Tests/NewsBarTests/WorkspacePresentationStoreTests.swift`

### 修改

- `Sources/NewsBar/Views/Workspace/WorkspaceReportBody.swift`
  - 保留 `WorkspaceSectionHeader`、`WorkspaceOriginBadge`、`WorkspaceVerificationBadge`、`WorkspaceReportMarkdown`。
  - `WorkspaceReportBody` 在 Task 3 暂时保留为 `ResearchReportReader` 的薄包装，Task 5 两处调用迁移后删除该类型；保留 `WorkspaceSectionHeader`、`WorkspaceOriginBadge`、`WorkspaceVerificationBadge`、`WorkspaceReportMarkdown`。
- `Sources/NewsBar/Views/Workspace/TransientResearchReportView.swift`
  - 删除 80 字「当前结论」和 `WorkspaceReportBody` 调用。
  - 头部、版本对比、进度保留；正文换 `ResearchReportReader`。
  - 使用 `ResearchReportDisplay` 显示 `selectedVersion.report`。
- `Sources/NewsBar/AppDelegate.swift`
  - 浮窗 760×760，最小 620×560；传入 `onOpenWorkspace`。
- `Sources/NewsBar/Views/Workspace/WorkspaceDetailView.swift`
  - 默认 tab 逻辑；向 `WorkspaceResearchPane` 传事件时间线入口。
- `Sources/NewsBar/Views/Workspace/WorkspaceResearchPane.swift`
  - 运行条 + 版本文案 + 阅读器 + 底部操作条。
  - 删除正文顶部的版本列表和 footer 的滚动内布局。
  - 宽窗来源栏。
- `Sources/NewsBar/Views/Workspace/WorkspacePresentationStore.swift`
  - `hasChosenSegment`。
- `Sources/NewsBar/Models/Localized.swift`
  - 新增 `research.report.*`；`workspace.detail.research` 值改为「报告」/「Report」。

## 7. 验收

### 自动

- `ResearchReportMetricsTests`：计数、时间跨度、域名分组、空报告。
- `ResearchReportReaderRenderingTests`：760×760、620×560、两套主题、有空/无时间线、有/无来源、长报告。
- `WorkspacePresentationStoreTests`：首次访问无选择、设置后记住。
- `LocalizationParityTests`：中英 key 对齐、静态 key 都有定义。
- `swift test` 全量通过（或只保留与本改动无关的既有失败并记录）。

### 手动

- 浮窗 760×760：首屏完整结论 + ≥2 个时间线节点；来源默认折叠；`E1` 来源卡；打开原文可返回。
- 浮窗 620×560：导航不换行、不遮挡；来源展开可滚动。
- 历史版本：从通知带 `versionID` 打开，显示该版本报告，不显示最新版。
- 研究中心 1180：报告 tab、版本菜单、折叠来源；默认落在报告；切到别的 tab 再回来记住选择。
- 研究中心 1600：右侧来源栏出现；窄回 1180 自动消失。
- 两套主题、VoiceOver、键盘焦点、减少动态效果。
- 无时间线、无来源、旧版报告、搜索失败、失败/运行中状态。

## 8. 留给实现者

- 章节间距、字号、卡片圆角按现有 `newsCardSurface` / `EditorialTag` / `EditorialActionButtonStyle` 落地，不新造视觉语言。
- 导航用分段 `Picker` 还是自定义 HStack：优先系统 `Picker`（可访问性更好），标签固定 01–04，不把来源数量塞进分段标签。
- 来源栏的域名组头样式、空组处理由实现者按现有列表密度决定。
- 右栏与 E1 的跨栏定位不在第一版；如果实现，必须保持 popover 仍可用。

## 9. 明确不做

- 不改 `ResearchNotificationSummary.maxCharacters`。
- 不改 `WorkspaceReportMarkdown` 的导出字段（除非单独提出）。
- 不把 `report.timeline` 写回 `WorkspaceDetail.timeline`。
- 不在浮窗里加载完整版本历史。
- 不为「关键事实」新增模型字段或 NLP 抽取。
