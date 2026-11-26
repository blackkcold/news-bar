# 深度研究报告弹窗：两态阅读方案（落版规格）

- 状态：已落版，待实施。
- 基线：`main`，`bc52662`（v3.6.2），2026-11-26 源码复核。
- 上位设计：[研究报告阅读器](2026-11-23-research-report-reader-design.zh-CN.md)、[研究阅读与通知](2026-11-18-research-reading-notifications-v1.zh-CN.md)。
- 取代：[深度研究报告弹窗：单栏阅读器升级规格](2026-11-25-transient-research-reader-upgrade-design.zh-CN.md) 的「头部」「目录」「次要状态」三节；其余（版本身份、来源去重、四态文案、工作台契约）继续有效。
- 参考图：用户提供的设计稿（一栏正文 + 横向时间线 + 「展开调研详情」收口）。结构与层级采纳，滑块文字不采纳——数据里没有节点类型字段，照抄等于编造分类。
- 适用范围：`openTransientResearch` 打开的统一研究报告浮窗。工作台、Dashboard AI 简报不在范围内。

## 1. 目标与非目标

读者的第一眼要回答三件事：这是哪份报告、结论是什么、有没有时间线。当前弹窗用 40pt 常驻章节条换导航，用 15pt 标题换字体统一，用五行计数条换「数据充分」的印象，三处都在挤压第一眼的密度。

**目标**：一个滚动容器、两态切换（阅读 / 调研详情）、首屏三件事齐全、详情仍是单栏、所有文本可选取复制。

**非目标**：不改研究任务、提示词、报告 JSON／`BurstResearch`、「复制 Markdown」格式、通知上限、已读触发、入口路由；不改工作台双栏、来源栏、章节导航、版本切换语义；不新增节点类型字段；不自动加粗或高亮正文（`summary` 现在是纯文本，自动标记等于改提示词与 schema）。

### 已确认的三条决策

| # | 决策 | 落实方式 |
|---|---|---|
| D1 | 展开后**不保留**顶部章节快捷跳转，但章节标题等文本必须可选取、可复制 | 删除导航条（弹窗专属）；详情区整体 `.textSelection(.enabled)`；章间跳转交给 VoiceOver 标题 rotor |
| D2 | 时间线滑块文字取**节点标题截短**；深度研究标题**限制长度** | 不新增字段；标题 2 行上限，完整标题由窗口标题、悬停提示、VoiceOver 标签与复制 Markdown 兜住 |
| D3 | 预览 **3 个 + `+N`**，可横向滚动，优先展示重要时间段 | 3 个取「重要性最高的连续窗口」；条形内全量按时间序排列，可横向滚动；`+N` 是「初始窗口之外还剩几个」的提示，也是把条形推到下一窗口的按钮 |

## 2. 基线事实（本次复核）

| 类型 | 结论 |
|---|---|
| 已核实 | 弹窗为 760×760 非模态 `NSPanel`，内容下限 620×560（[AppDelegate](../../../Sources/NewsBar/AppDelegate.swift#L1286)）。 |
| 已核实 | 标题用 `.title3.weight(.semibold)`（≈15pt），正文被 `ResearchReportPresentation.popup` 钉在 15pt，两级同号（[TransientResearchReportView](../../../Sources/NewsBar/Views/Workspace/TransientResearchReportView.swift#L441)）。 |
| 已核实 | 四章固定导航条常驻滚动区上方，高约 40pt，弹窗与工作台共用 `ResearchReportNavigator`（[ResearchReportReader](../../../Sources/NewsBar/Views/Workspace/ResearchReportReader.swift#L275)）。 |
| 已核实 | 导航条里的「历史版本」badge 在弹窗中**不生效**：`ResearchReportReader(isHistorical:)` 默认 false，弹窗未传；版本身份实际由 `headerMeta` 输出「历史版 · V2 · 11月24日」。删导航条不损失该信息，新标签行也不得重复编码。 |
| 已核实 | 结论章同时存在「查看核验」下行按钮与导航条「核验」tab，同一目标两条入口（[ResearchReportSections](../../../Sources/NewsBar/Views/Workspace/ResearchReportSections.swift#L87)）。 |
| 已核实 | 真实记录标题 60+ 字（`算力"利空砸盘"：…GPU价格"多达1/3"`），22pt 下 620pt 宽约 28 字/行，必须限 2 行。 |
| 已核实 | 真实时间线 5 个节点全部落在 2 天内。按日历聚成「时间段」只剩 2 段，过粗；重要性必须按节点窗口计算，不能按天聚合。 |
| 已核实 | 时间线在写入时已按 `sortDate` 升序排序（[ReportValidator](../../../Sources/NewsBar/Services/Research/ReportValidator.swift#L188)），未定日期节点排在末尾。预览不得重排时间序。 |
| 已核实 | 节点状态由 `ReportPresentation` 从证据推导（verified / citedUnverified / unsourced），无来源节点会被降 `confidence` 到 low。这就是唯一可信的「重要性」原料。 |
| 待实测 | 22pt 标题在两行内的实际断行位置、`.textSelection(.enabled)` 与滚动手势在真实面板上的摩擦、`+N` 叠层在长中文标题下的可读性，需实机目检。 |

## 3. 线框与布局

图中内容是示例，控件为原生 SwiftUI。

```text
阅读态（默认，760×760）                        调研详情态（同一滚动容器，向下追加）
╭─ 研究报告 ────────────────────────╮        ╭─ 研究报告 ────────────────────────╮
│ V1 · 11 月 24 日          更多 ⌄   │        │ V1 · 11 月 24 日          更多 ⌄   │
│ 苹果为云端智能设置每日额度，超额   │        │ 苹果为云端智能设置每日额度，超额   │
│ 需订阅 iCloud+                     │        │ 需订阅 iCloud+                     │
│ [华尔街见闻] [深度] [未证实]       │        │ [华尔街见闻] [深度] [未证实]       │
│                                    │        │                                    │
│ 苹果在近期推送的 iOS 27.3 … 正文    │        │ 苹果在近期推送的 iOS 27.3 … 正文    │
│ 16pt / 行高 1.75 / 净宽 640         │        │ …                                  │
│                                    │        │ 3 节点 · 4 来源 · 已核验 4/4 引文   │
│ 3 节点 · 4 来源 · 已核验 4/4 引文   │        │ ─────────────────────────────────  │
│ ─────────────────────────────────  │        │ ⏱ 时间线                           │
│ (额度引入) (分类划分) (超额升级) +2 │        │ ● 11-24 测试版引入每日额度  E11 E15│
│ ─────────────────────────────────  │        │ ○ 11-25 超额后需升级 iCloud+  E1   │
│        展开调研详情 ↓              │        │ ✓ 核验                             │
╰────────────────────────────────────╯        │ [未证实] 5 条主张 · 0 条已验证      │
                                              │ ▸ SemiAnalysis 报告称 SpaceX…      │
  620×560（时间线 3 可见 + +N）                 │ 来源                               │
╭─ 研究报告 ──────────────╮                   │ sina.com.cn  芯片产能过剩     E1   │
│ 历史版 · V2 · 11/23 更多⌄│                   │ ─────────────────────────────────  │
│ 苹果为云端智能设置每日…  │                   │        收起 ↑（同位，不再下滚）    │
│ [华尔街见闻] [深度]      │                   ╰────────────────────────────────────╯
│ 正文 …                   │
│ (额度引入) (分类) (最新) +2│                 无任何可展开章节
│ ──────────────────────── │                 ╭─ 研究报告 ──────────────╮
│      展开调研详情 ↓      │                 │ 正文与计数 …            │
╰──────────────────────────╯                 │（不出现折叠条）         │
                                              ╰──────────────────────────╯
```

| 区域 | 布局与优先级 |
|---|---|
| 顶部 chrome | 单行：左 `meta`（历史版？· V# · 日期），右「更多 ⌄」。弹窗去掉独立「研究中心」按钮与复制图标，二者进菜单。 |
| 标题 | 22pt / `.bold`，行距收紧，上限 2 行，尾部截断。`help` 与 `accessibilityLabel` 用完整标题。 |
| 标签行 | 最多 3 个胶囊，12pt。空间不足时按「深度 → 载体 → 结论」顺序丢弃；结论状态最后丢，因为它是唯一影响可信度判断的标签。没有任何标签时整行不出现。 |
| 正文 | 16pt，行高 1.75，净宽 ≤640pt，容器级 `.textSelection(.enabled)`。 |
| 计数行 | 单行 12pt 次级文字，**不带底色**。始终紧接正文之后，只出现一次。 |
| 时间线预览 | 横向条，高约 60pt；节点 = 状态点 + 胶囊标题（1 行截断，宽度上限 132pt），下方日期。条内可横向滚动，滚动条隐藏。展开详情后**保留**，此时它的作用是页内节点索引。 |
| 折叠条 | 1px 分隔线 + 居中 `展开调研详情 ↓` / `收起 ↑`，11.5pt semibold。**位置固定**：详情追加在其下方，展开时上方零位移。 |
| 详情 | 三章顺序：时间线、核验、来源。章标题 15pt semibold + 图标 + 细线，是**标签**不是与正文争视线的标题：比正文小 1pt 是刻意的，读者的注意力先落在结论上。每章标题带 heading trait，可被 VoiceOver rotor 逐章跳转。 |
| 详情章间距 | 章间 24pt，章内 8pt。不出现章节序号、不出现第二层滚动。 |
| 窗口变宽 | 只扩大左右留白，正文不拉长；标题、正文与详情同宽上限 640pt 居中。 |

**正文字号由 15 改 16，会碰到既有断言**。`ResearchReportPresentation.popup.bodyFontSize` 现为 15，`Tests/NewsBarTests/ResearchReportReaderRenderingTests.swift` 有四处需要同步：

| 行 | 现断言 | 改为 |
|---|---|---|
| 28 | `popup.bodyFontSize == 15` | `== 16` |
| 33 | `scalingBodyFont(by: 1.35).bodyFontSize == 20.25` | `21.6`（16 × 1.35） |
| 49 | `popup.fontSize(14) == 15` | `== 16` |
| 75 | `accessibility5` 下 `fontSize(14) == 37.5` | `40`（16 × 2.5） |

`secondaryFontSize == 12.5` 与 `fontSize(11.5) == fontSize(10.5) == 12.5` 不变：这次只抬正文一级，不是又一次「全抬一档」。两级比例从 15/12.5（1.20）变为 16/12.5（1.28），层级更清楚；Dynamic Type 仍同比缩放。

## 4. 内容与数据契约

### 4.1 标签行

| 标签 | 取值 | 出现条件 |
|---|---|---|
| 载体 | `ResearchReportHeaderTagBuilder.sourceName(_:language:)`（不直接用 `NewsSource.displayName`，见下） | 始终有种子来源时 |
| 深度 | `workspace.research.depth.<depth>`（快速／标准／深度） | 记录存在且 `depth` 可读 |
| 结论 | `research.verdict.short.<verdict>`（已证实／基本证实／分歧／未证实／反驳） | `verification != nil` |
| 历史版 | — | **不在标签行重复**。身份由顶部 `meta` 承担，见 §2 复核结论 |

结论标签用 `research.verdict.short.*` 而非 `research.verdict.*`：后者是「已被反驳」这类完整句，在胶囊里会撑宽并挤掉其余标签；前者已存在于中英两表，无需新增。缺少 `verification` 时第三个标签整条不出现，标签行只剩两项，不占位、不留空胶囊。

**语言必须显式传入**。`NewsSource.displayName` 内部读 `L10n.currentLanguage` 这个全局量，而标签行是按某一次 `settings.appLanguage` 构建的。直接用 `displayName` 会在语言切换的瞬间渲出中英混排；因此载体标签走 `ResearchReportHeaderTagBuilder.sourceName(_:language:)`，RSS 取自身的源名，微博／B站 走显式语言的 key。

**宽度不足时的丢弃顺序：深度 → 载体 → 结论**。用 `ViewThatFits(in: .horizontal)` 提供三套候选（全部 / 无深度 / 只剩结论）；结论最后丢，因为它是唯一影响可信度判断的标签。

**无障碍：偏离原规格，登记在此**。原规格写「不进 Tab 顺序，`.accessibilityHidden(true)`」。实装改为：标签行是一个 VoiceOver 停留点，`accessibilityElement(children: .ignore)` + 朗读全部标签文本。理由是标签行现在是首屏唯一承载核验结论的位置，删掉章节 tab 之后，看不到颜色胶囊的读者将完全拿不到「这份报告未证实」这一信息。它仍不承载动作、仍不进 Tab 顺序（不是可聚焦控件），只是改为被朗读。这属于 DESIGN_RULES F 段的「承载不可见信息」豁免，不是静默偏离。

### 4.2 计数行

沿用 `ResearchReportMetrics` 三项上限：节点数、来源数与域名数、已验证引文数、独立来源数（有则显示）。去掉现有底色块，降到 12pt 次级文字。历史报告（`reportVersion == 0`）无证据时不显示来源段，避免「0 个来源」被读成结论。

**缺失项不上首屏**。现状在结论章还有两个同类问题需要一起清掉：

| 现状 | 本方案 |
|---|---|
| `linksToVerification` 为 true 时画「查看核验 ↓」按钮 | 弹窗置 false，按钮消失（导航条删除后它成为第三条同类入口） |
| 置 false 后原 `else if` 分支会画 `missingStrip`（最多 2 条缺失） | 追加 `!presentation.usesReadableChapters` 条件：弹窗不再渲染 `missingStrip`，缺失项只在核验章出现一次 |

代价是缺失项从首屏移到一次展开之后。这是有意的：首屏的可信度由「已核验 X/Y 条引文」与「未证实」标签承担，具体缺什么属于追查行为，而折叠条就在同一屏。工作台两个分支均不变。

### 4.3 时间线预览算法（D3）

新增纯函数 `ResearchTimelinePreview.make(nodes:)`，无 SwiftUI 依赖，可单测。

**输入**：`ReportPresentation` 推导后的节点数组，顺序即时间线顺序（已按 `sortDate` 升序，未定日期在末尾）。

**重要性打分**（只用已有字段，不新增）：

```
state     : verified 2 / citedUnverified 1 / unsourced 0
confidence: high 2 / medium 1 / low 0
evidence  : min(evidenceIDs.count, 3)
dated     : sortDate != nil ? 1 : 0
```

**窗口选择**：取长度 `min(3, count)` 的**连续窗口**，使窗口内分数和最大；并列时取更靠后的窗口（更接近当下）。连续窗口而非任意挑三个，是因为时间线一旦抽点，读者会把缺口读成「这段时间没有事情发生」。

**输出**：

```swift
struct ResearchTimelinePreview {
    let nodes: [ReportPresentation.Node]
    /// 初始滚动位置对准的节点下标（重要性窗口起点）。
    let anchorIndex: Int
    /// count - 3；≤0 表示不画 `+N`。仅供初始渲染与测试断言，
    /// 界面显示的 N 由视口实时计算（见下）。
    let hiddenCount: Int
}
```

| 数量 | 行为 |
|---|---|
| `count == 0` | 不画条形，折叠条是否出现另由 §4.4 决定 |
| 全部放得下 | 全部展示，胶囊宽度按标题内容自适应（上限 132pt），无 `+N`，无横向滚动 |
| 放不下 | 视口内的胶囊保持完整；右边缘叠层显示剩余数 `+N`；条形全量按时间序排列并横向滚动；初始位置对准重要性窗口 |

**为什么不是「固定 3 个」**：3 是设计的起点，不是上限。实测 620pt 下 6 个短标题（「节点 1」这类）都能完整放下；此时硬塞一个 `+N` 等于把可达内容藏起来，违背「不用特别限制太少」。规则因此改为「放得下就都显示，放不下才出 `+N`」，3 只作为重要性窗口的最小长度。固定不变的只有 `+N` 的语义：它恒表示视口之外还剩几个，不是总共有几个。

**`+N` 是视口叠层，不是滚动内容里的最后一项**。若把它当条目放进内容，滚到底会显示 `+0`，读者会以为出错。作为右边缘叠层，它恒定表达「视口之外还剩几个」：`N = count − 当前完整可见节点数`，滚到底时 `N = 0`，叠层消失。

它也承担第二个职责：滚动条隐藏后，横向可滚动本身不可见，`+N` 是那个可见暗示——同时表达「还有几个」与「可以往那边推」。点击位移 `min(offset + step, count − visible)`，推到下一窗口后**不回卷到头部**：回卷会让读者以为内容重新开始。

**「不用限制太少」的落点是滚动而非压缩**：所有节点都在条形里，横向滚动即可到达，不丢弃、不折叠、不省略；胶囊只截断过长的单条标题。

**两级目标要分开**：

| 点击对象 | 结果 |
|---|---|
| 胶囊（节点） | 详情收起时先展开，再滚到详情内该节点 |
| `+N` | 只横向滚动条形，不展开详情、不改变折叠状态 |

`+N` 不与详情耦合，因为它描述的是条形自身的剩余量；把条形内容和条形状态绑在一起会得到「点了 +N 却跳到别处」的断裂。

条形不做选中态高亮：内容是时间线，不是「当前阅读位置」指示器。展开详情后条形**保留**，此时它同时是页内节点入口与全量节点索引；胶囊（截断标题 + 日期）与详情节点（完整标题 + 详情 + 引用 chip）是两级缩放，不是同一信息的重复编码。

### 4.4 折叠条与门控

- 需至少有 1 个可展开章节才出现折叠条。可展开章节 = 时间线非空 **或** 核验／局限／证据存在 **或** 补充来源链接非空。
- 无任何可展开内容时：不画折叠条，正文与计数行照常显示，不留空壳。
- 展开状态持久化到 `TestIsolation.defaults["reader.research.detailsExpanded"]`（与 `reader.research.progressExpanded` 同一机制）。跨版本切换、关闭再开保持；不随报告 digest 变化重置。
- 折叠条文案只有两个状态：`展开调研详情` + `chevron.down`，`收起` + `chevron.up`。不同时显示「详情」标题。

### 4.5 四态

沿用 `TransientReportEmptyState` 现有四条专属文案，不改措辞：

| 状态 | 首屏 | 折叠条 | 计数行 |
|---|---|---|---|
| 研究中无报告 | 标题位置显示事件标题（若有）；正文区给状态与进度 | 不出现 | 不出现 |
| 失败／取消／中断 | 同上，附 `lastError` 一行 | 不出现 | 不出现 |
| 已移除／不可用 | 一句状态，关闭即回原位 | 不出现 | 不出现 |
| 通知 pin 的历史版本不可用 | 专用文案 + 说明可去研究中心看当前报告 | 不出现 | 不出现 |

失败态的研究中心入口在「更多」菜单，与正文态的菜单是同一个，不做第二处入口。

### 4.6 标题长度（D2）

| 位置 | 上限 | 超出处理 | 完整标题在哪 |
|---|---|---|---|
| 弹窗标题 | 2 行 @22pt | 尾部省略号 | 窗口标题（`panel.title` 跟随当前报告主题）、`help` 悬停、VoiceOver 标签、复制 Markdown 首行 |
| 时间线胶囊 | 1 行，宽度上限 132pt | 尾部省略号 | 详情内该节点标题、VoiceOver 标签 |
| 详情章标题 | 1 行 | 不截断（章节名固定） | — |

**标题 22pt 是独立于正文字号的一级**。正文 16pt 时标题若仍用 `.title3`（15pt）会出现标题小于正文，这正是当前版本的问题；22/16 = 1.375，接近 1.4 的常规标题比例。Dynamic Type 下标题也同比缩放（`readerTextScale`），与正文两档一起缩放，比例不变。

`panel.title` 现为创建时写死「研究报告」。改为随显示目标更新为完整报告主题，是 2 行上限可接受的唯一理由：任何长度的标题都始终在窗口标题栏、Mission Control 与 Dock 可读可复制。

更新时机与目标切换一致：`open()` 完成后按 `model.event?.title ?? model.record?.topic ?? fallbackTitle` 写 `panel.title`；目标未解析出来时保持上一标题，不回退成「研究报告」，避免标题在解析期间闪一次。历史版本切换不改窗口标题：版本身份在 `meta` 行，窗口标题承载的是「这是哪份报告」。

### 4.7 新增与本规格改写的文案 key

全部中文、英文各一条，必须通过 `LocalizationParityTests`。

| key | 中文 | 英文 | 用途 |
|---|---|---|---|
| `research.report.fold.expand` | 展开调研详情 | Show research details | 折叠条收起态 |
| `research.report.fold.collapse` | 收起 | Hide | 折叠条展开态 |
| `research.report.timeline.more` | +%ld | +%ld | 条形末尾 `+N` 胶囊（数字格式，中英同形） |
| `research.report.timeline.preview.a11y` | 时间线预览，共 %1$ld 个节点，显示前 %2$ld 个 | Timeline preview, %1$ld nodes, showing %2$ld | 条形整组 VoiceOver 标签 |

复用不新造：`research.report.nav.timeline`／`verification`／`sources` 作为详情章标题继续使用；`research.report.verification.jump`（查看核验）在本方案中**不再出现**，key 保留不删，避免与其它契约测试冲突。

## 5. 交互契约

1. **展开／收起**：折叠条原位切换，不动滚动锚点。展开时视口底部追加内容，读者当前所读位置零位移；收起时回到展开前位置。
2. **选取复制**（D1）：阅读正文与详情区整体 `.textSelection(.enabled)`，包括章节标题、节点标题、日期、计数行、来源行。时间线条的胶囊**不**开选取，避免与横向拖拽和点击冲突。
3. **章节跳转**：弹窗不再有顶部 tab，也不再有「查看核验」下行按钮（同一目标的第二条入口）。章间跳转由 VoiceOver 标题 rotor 完成；鼠标读者用滚动。展开后时间线预览条仍承担页内跳转，因此「不保留章节快捷跳转」指的是章节 tab，不是节点索引。
4. **引用**：行为不变。点 `E1` 弹现有证据卡；Esc 先关卡片再关窗口；关卡片后焦点回到 chip。
5. **焦点**：「更多」→ 折叠条 → 正文可互动项。折叠条是原生 `Button`，`accessibilityLabel` 为展开／收起后的结果状态。
6. **滚动**：进度更新、新版就绪不换报告、不跳位。显式切换版本或换目标时，回到结论且折叠状态保持用户选择。
7. **新版就绪**：横幅压到单行，位于正文区之上；折叠条不受影响。
8. **无障碍**：折叠条 `isSelected` 不得只靠颜色；胶囊状态（已验证 / 未验证 / 无来源）用点形状区分（实心 / 虚线环 / 半透明实心），与工作台同一套。

## 6. 工程拆分与回退

| 包 | 修改面 | 完成条件 | 回退 |
|---|---|---|---|
| **A1 · 外壳 chrome** | `TransientResearchReportView` 头部；`AppDelegate` 面板标题跟随 | 单行 chrome + 更多菜单 + 标题 2 行 + 标签行 + `panel.title`；工作台零变化 | 单包回退，不涉数据 |
| **A2 · 阅读态结构** | `ResearchReportPresentation` 新增 `showsChapterNavigator` / `showsFoldStrip` / `titlePointSize`，`bodyFontSize` 15→16；`ResearchReportReader` 折叠条与详情容器；计数行下移；结论章 `missingStrip` 门控 | 阅读态首屏三件事齐全；折叠条门控与持久化；`.textSelection` 覆盖详情文本；`ResearchReportReaderRenderingTests` 四处字号断言同步（见 §3） | 关闭 `showsFoldStrip` 即回到当前常驻导航（保留 flags 作为灰度开关） |
| **A3 · 时间线预览** | 新增 `ResearchTimelinePreview`（纯逻辑）+ `ResearchTimelineStrip`（视图） | 打分与窗口选择单测覆盖；水平滚动、`+N`、点击定位到详情节点 | 不给 `ResearchTimelinePreview` 即不渲染条形，回到纯文字入口 |
| **A4 · 验收** | 渲染快照矩阵、`TransientResearchReportModelTests`、文案 key 完整性 | 见 §7；工作台渲染基线与弹窗共用 reader 的回归均通过 | — |

正交性检查（每条改动只碰一处）：

- `showsChapterNavigator = false` 只影响弹窗是否画导航条。
- `showsFoldStrip = true` 只影响阅读态是否把详情收入折叠条。
- `titlePointSize` 只影响弹窗标题字号。
- `bodyFontSize` 只影响正文字号。

工作台不传任何新配置，四处默认值均保持现状，因此它的导航、滚动、字号、折叠全部不变。

落地顺序 A1 → A2 → A3 → A4，A2 与 A3 可并行但以 A2 为基准。A1 单独交付不构成完成本规格。

## 7. 验收矩阵

| ID | 条件／操作 | 通过标准 |
|---|---|---|
| R01 | 760×760 真实长标题记录 | 标题 2 行内截断，完整标题在悬停与窗口标题可见；正文首屏可见不少于 3 行。 |
| R01b | 标题层级 | 弹窗报告标题 22pt > 正文 16pt > 次要 12.5pt，三档在 Dynamic Type 放大后比例不变；详情章标题 15pt 是标签级，不等于报告标题。 |
| R02 | 620×560 与 1150×850 | 620 无横向滚动、标题不断成 3 行；1150 只扩大留白，正文净宽 ≤640。 |
| R03 | 折叠条展开 / 收起 | 展开时上方内容零位移，收起回到原位；状态跨关闭重开保持；无内容时不出现。 |
| R04 | 正文与详情文本选取复制 | 正文、章标题、节点标题、日期、计数行、来源行均可选中并复制；胶囊不可选。 |
| R05 | 时间线 1 / 2 / 3 / 5 / 12 个节点，620 与 760 两宽 | 1–3 全展无 `+N`；5 与 12 初始可见 3 个并显示 `+N`；两宽下都可横向滚动到全部节点，初始位置对准重要窗口；滚到底时 `N = 0` 且叠层消失。 |
| R06 | 重要性窗口 | 全 verified 且高置信的连续三节点被选为初始窗口；全 unsourced 时退化为最近三节点；分数并列取靠后窗口。 |
| R07 | 详情已展开时点击胶囊 | 滚到详情内该节点，不改变折叠状态、不折叠其他章节。 |
| R07b | 详情处于收起时点击胶囊 | 先展开再滚到目标，不出现「点了没反应」或「只展开不滚动」；展开后目标在视口内可见。 |
| R07c | 点击 `+N` | 只横向滚动条形一个窗口宽度，不展开详情、不改变折叠状态、不移动主滚动区；到末尾不回卷。 |
| R08 | 标签行 | 载体／深度／结论三项齐全；缺 `verification` 时只有两项，不留空胶囊；历史版不在标签行重复出现。 |
| R09 | 计数行 | 只出现一次，位于正文之后；历史报告无证据时不显示来源段；无底色块。 |
| R09b | 弹窗结论章 | 「查看核验」按钮与 `missingStrip` 均不出现；两者只在核验章出现一次；工作台两分支不变。 |
| R10 | 四态 | 四种文案互异；四种状态都不显示计数行与折叠条；失败态的研究中心入口只在「更多」菜单出现一次。 |
| R11 | 键盘与 VoiceOver | 「更多」→ 折叠条 → 正文顺序可达；章标题为 heading，rotor 可逐章跳转；引用卡 Esc 两段式。 |
| R12 | 三主题 | 浅色／深色／复古下标题、正文、次级、标签、胶囊状态点与焦点环可辨认；状态不只靠颜色。 |
| R13 | 工作台回归 | 章节导航、来源栏、版本切换、默认折叠全部不变；`ResearchReportPresentation.workspace` 的 `bodyFontSize` 仍为 `nil`；`swift test --filter ResearchReportReaderRenderingTests` 通过。 |
| R14 | 复制 Markdown | 输出格式不变，首行为完整标题；与界面所见差异不称「所见即所得」。 |

验证入口：`swift test --filter ResearchTimelinePreviewTests`、`swift test --filter ResearchReportReaderRenderingTests`、`swift test --filter TransientResearchReportModelTests`，再全量 `swift test`。L4 实机项见 R02、R11、R12。

## 8. 代码依据

- [TransientResearchReportView.swift：头部](../../../Sources/NewsBar/Views/Workspace/TransientResearchReportView.swift#L441)、[同一文件：headerMeta](../../../Sources/NewsBar/Views/Workspace/TransientResearchReportView.swift#L488)、[空态枚举](../../../Sources/NewsBar/Views/Workspace/TransientResearchReportView.swift#L303)。
- [ResearchReportReader.swift：读者容器](../../../Sources/NewsBar/Views/Workspace/ResearchReportReader.swift#L74)、[章节导航](../../../Sources/NewsBar/Views/Workspace/ResearchReportReader.swift#L275)、[章节偏移 PreferenceKey](../../../Sources/NewsBar/Views/Workspace/ResearchReportReader.swift#L36)。
- [ResearchReportPresentation.swift：弹窗配置](../../../Sources/NewsBar/Views/Workspace/ResearchReportPresentation.swift#L24)、[可读章节过滤](../../../Sources/NewsBar/Views/Workspace/ResearchReportPresentation.swift#L58)、[Dynamic Type 缩放表](../../../Sources/NewsBar/Views/Workspace/ResearchReportPresentation.swift#L116)。
- [ResearchReportSections.swift：结论章](../../../Sources/NewsBar/Views/Workspace/ResearchReportSections.swift#L30)、[查看核验入口](../../../Sources/NewsBar/Views/Workspace/ResearchReportSections.swift#L87)、[章标题组件](../../../Sources/NewsBar/Views/Workspace/ResearchReportSections.swift#L3)、[时间线节点行](../../../Sources/NewsBar/Views/Workspace/ResearchReportSections.swift#L408)。
- [ResearchReportMetrics.swift：计数来源](../../../Sources/NewsBar/Views/Workspace/ResearchReportMetrics.swift#L11)。
- [ReportPresentation.swift：节点状态推导](../../../Sources/NewsBar/Views/Research/ReportPresentation.swift#L57)。
- [ReportValidator.swift：时间线排序](../../../Sources/NewsBar/Services/Research/ReportValidator.swift#L188)、[节点置信度降级](../../../Sources/NewsBar/Services/Research/ReportValidator.swift#L149)。
- [AppDelegate.swift：面板尺寸与下限](../../../Sources/NewsBar/AppDelegate.swift#L1286)、[面板创建](../../../Sources/NewsBar/AppDelegate.swift#L1285)。
- [ResearchReportReaderRenderingTests.swift：字号断言](../../../Tests/NewsBarTests/ResearchReportReaderRenderingTests.swift#L28)。
- [LocalizationParityTests.swift：文案 key 校验](../../../Tests/NewsBarTests/LocalizationParityTests.swift#L4)。
