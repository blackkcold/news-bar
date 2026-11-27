# 深度研究报告：弹窗阅读改版 + 研究引擎五角度 / 四象限评论

状态：方案已落版，待执行
日期：2026-11-27
基线：v3.7.0（`e3954ca`，分支 `feat/popup-body-and-resize`）

## 1. 目标

用户要的是**扩展信息**，不是原文的复述：

- 今年报双十一，深度研究应给出——去年销售额对比、商家参与程度、核心高光、排名前列商家。
- 「应该包括为什么，但不至于为什么」。
- 要做成**深度研究引擎**：先回归模型／策略／算法的组合，再落到一个简练公式。
- 引入**古今中外四象限评论**（如果有），构成「多角度 + 多评论 + 多维度事实」。

弹窗的职责是把引擎产出的多维度事实**读起来是一篇报告**，而不是一个数据仪表盘。

### 1.1 本轮三目标（对标开源实现后修订）

| 目标 | 结论 | 落点 |
| --- | --- | --- |
| 核心公式能否优化 | **能**。原公式只是审计分数，缺「下一轮问什么」的驱动层；补上缺口收敛 | §4.1 |
| 性能开销能否优化 | **能，且有一项是免费的**。Stage 2 检索是串行的，并发化不增加任何请求数 | §4.4 |
| 提供的是否用户需要的信息 | **不是**。36 份报告 35 份 `verdict = unverified`，有效引文 4.31 条（对标产品 31–111） | §5.0 |

对标来源与结论见 §4.0。三条结论共同指向一件事：**先补材料密度与收敛，再谈版式**；版式（P1）负责把一个「准确的薄报告」读起来不难受，它替代不了材料。

非目标：

- 不加报头、肩题、首字下沉、规则线分栏、盒子／边框／底色。视觉方向是「安静、精致、可读」，不是「有年代感」。
- 不替换字体族（继续系统字体；retro 主题的宋体保持原样）。
- 不改工作台的任何可见行为。

## 2. 已完成（本分支，未提交）

| 项 | 实现 | 验证 |
| --- | --- | --- |
| 正文改用 `overview` | `ResearchReportPresentation.swift:47` 新增 `usesOverviewAsBody`；结论章 `bodyCopy`（`ResearchReportSections.swift:130`）优先渲染 overview，summary 留数据层 | 渲染快照 |
| 段落结构 | overview 用空行分 3–4 段；新增 `ResearchProseParagraphs`，逐段堆叠，段间 10pt | 7 项分割单测 |
| 胶囊标题不再被裁 | 宽度约束从 `HStack` 下移到 `Text`（`ResearchTimelineStrip.swift:180`），省略号生效；视口右缘加渐隐 | 620/760 目检 |
| 窗口按内容自适应 | 内容实测高 → `ResearchPanelSizing.frameHeight`（下限 480，上限屏可见高 ×0.85，顶边固定）；只有边框拖拽算手动 | 10 项尺寸单测 |
| 全量回归 | — | 2113 tests / 0 失败 |

段间距取 **10pt**：章节内块间距是 12pt，段落间必须小于它，层级才成立。

## 3. P1 — 弹窗改动

本节三项实际改动：**P1-1 去章名、P1-3 计数行收敛、P1-5 折叠条预告**。P1-2 是复核后撤销的改动（标签不删），P1-4 登记在引擎侧（§4.3），放在这里是因为它决定首屏能否出现数字，P1-6 是三层改动合成后的高度预算。

### P1-1 结论章去掉章名

**现状**：`ResearchReportSections.swift:70` 无条件渲染 `ResearchReaderHeading(section: .conclusion, symbol: "text.alignleft")`，正文却已经是 overview（背景与经过）。标题叫「结论」是语义错误，不是措辞问题。

**改动**：

- `ResearchReportPresentation` 新增 `hidesConclusionHeading = false`，popup 设 `true`。
- 结论章 `body`：`if !presentation.hidesConclusionHeading { ResearchReaderHeading(...) }`。

**共用约束**：`ResearchReaderHeading` 与本章同文件，工作台同一个组件。必须走 presentation 分支，不能删代码。

**副作用（已评估，可接受）**：弹窗内该章失去一个 VoiceOver 标题停靠点。窗口标题栏已是报告标题，正文紧随其后，读屏顺序与视觉一致。弹窗不使用章节跳转（`showsChapterNavigator: false`、`linksToVerification: false`），因此 `accessibilityFocused` 无调用方。若读屏体验倒退，回退方式是恢复 9.5pt 的小型大写章名——与详情区章名同一套 chrome。

### P1-2 标签行：`深度` 不删，`verdict` 待量后定

**原方案拟删「深度」——撤销。** `TransientResearchReportView.swift:586` 的 `ViewThatFits` 已有三档降级（全部 → 去深度 → 仅结论），620pt 下本来就会自动丢它；删掉只是少一档回退。760pt 下三个标签都放得下。`ResearchReportHeaderTagBuilder` 与 `ViewThatFits` 均不动，`ResearchTimelinePreviewTests.swift:198` 保持通过。

**但 `verdict` 标签的问题被实测暴露出来**（§5.0）：36 份报告里 35 份是 `unverified`。`ResearchReportHeaderTagBuilder.swift:20` 的注释写「verdict 是唯一改变读者动作的标签」，那是设计意图，不是实测。

处置分两步，不合并：

1. **P1 不动标签行**。首屏只改计数行口径（P1-3）：`最高三级` 已经在解释「为什么未证实」。两个信号在同一屏互相印证，不是重复。
2. **P2 跑完 3 条 deep 后重新统计 `verdict` 分布**。判定规则先写死，避免事后找理由：
   - `unverified` 占比 **> 80%** → 降级为条件标签：仅当 `verdict != .unverified` 时才渲染，`unverified` 交给正文 `limitations` 表达
   - `unverified` 占比 **≤ 80%** → 保持常驻，它恢复成有区分度的信息

这样「删标签」变成一个可证伪的决策，而不是我的猜测。

### P1-3 计数行：5 项 → 2 项，且口径改掉

**现状**：`ResearchReportSections.swift:180` 的 `metaText` 最多拼 4 段——节点／来源+域名／已核验引文／独立来源。真实 deep 记录实测：

```
4 个节点 · 4 个来源 · 4 个域名 · 已核验 4/4 条引文 · 4 个独立来源
```

（4 个节点同日时 `displaySpanDays` 为 nil，「跨 N 天」已被省略。）

**本机 36 份真实报告的统计，推翻了我上一轮挑的那「2 项」**：

| 指标 | 实测 | 结论 |
| --- | --- | --- |
| `已核验 N/M` | 155/155 条引文，**36 份报告全部是 N/N** | 恒为满值，零信息量。放首屏是装饰 |
| `独立来源数` | 36 份报告里 `independentSources == 去重域名数`，**0 例外** | 与「N 个域名」同一个数，说了两遍 |
| `syndicationGroup` | 155 条引文里 **0 条**有值 | 上面那条的因果：没有转载合并，独立来源就退化为域名数 |
| `来源层级` | tier1 **14** / tier2 **12** / tier3 **129** | **这才是 `verdict` 为 `unverified` 的原因** |
| `verdict` | 36 份里 **35 份 `unverified`**、1 份 `mostlyConfirmed`，35 份 strength 0 | — |

所以弹窗该说的两件事不是「几个来源 / 核验几条」，而是：

```
4 个来源 · 最高三级
```

第二项直接解释读者眼前的「未证实」标签为什么是未证实。这才是决策信息。

**改动**：`metaText` 增加 `scope: MetaScope = .all`，popup 用 `.evidence`

| scope | 输出 | 使用者 |
| --- | --- | --- |
| `.all` | 现状 4 段（含 `已核验 N/M` 与独立来源） | 工作台（同一章在 `foldsDetailChapters == false` 时渲染） |
| `.evidence` | `N 个来源 · 最高 M 级` | 弹窗 |

`最高 M 级` 取 `report.evidence.map(\.tier).max()`：某来源存在时才有意义，无来源时退化为 `.all` 的「0 个来源」。Markdown 导出（`WorkspaceReportBody.swift:84`）不走 `metaText`，不受影响。

**测试影响**：`ResearchReportReaderRenderingTests.swift` 有 7 处 `metaText` 断言（655/659/807/811/827/850/868），全部走默认 `.all`，不改即绿；新增 `.evidence` 四条断言（单层、混层、无来源、中英）。

### P1-4 时间线条从「标题轮播」变「证据条」

**现状**：胶囊显示节点**事件名**——「双11手机销量数据发布」「马斯克宣布赠送SpaceX股票」。四个胶囊读完，读者得到的是目录，不是事实。

**根因在引擎侧**，UI 无可改：`ResearchPrompts.swift:357` 的 schema 只要求 `timeline[].title` 是空字符串占位，合成提示词没有任何形态约束。

**改动（P2 落地，此处仅登记）**：见 §4.3。UI 侧只承接结果——`captionTextWidth = 118pt`（`ResearchTimelineStrip.swift:48`）在 11pt 下约容 10 个汉字，所以提示词要求标题 ≤ 12 字，超出尾部省略。

这一项是首屏收益最大的一条：同为三个胶囊，换成数字后读者不点开详情就拿到三块扩展证据。**首屏应该出现数字。**

### P1-5 折叠条预告内容量

**现状**：`ResearchDetailFoldStrip`（`ResearchTimelineStrip.swift:260`）只有「展开调研详情 ⌄」。要求读者先付出一次点击才能评估值不值得展开。

**改动**：

- 新增纯函数 `ResearchDetailFoldPreview.make(chapters:timeline:report:language:) -> String?`
  - 「4 则时间线 · 5 条核验」
  - 有待补项时追加「· 2 处待补」
  - 两者皆为 0 时返回 nil，不占位
- `ResearchDetailFoldStrip` 增加 `preview: String?`，主标签右侧以 `.secondary` 显示。
- 不重复来源数：计数行已说「4 个来源」，折叠条再说一次是同一屏两个数字。

**测试**：`ResearchDetailFoldStrip` 目前**全仓零覆盖**。先补纯函数单测（数量、全零、待补、中英），再由既有 620/760 折叠态快照承接视觉回归。

**本地化**：新增 `research.report.fold.preview` 等 key，zh + en 同时加，否则 `LocalizationParityTests` 失败。

### P1-6 首屏高度预算（先算再画）

| 块 | 620 宽 | 760 宽 |
| --- | --- | --- |
| 头部（meta + 更多） | 50 | 50 |
| 标题 2 行 @22 | 62 | 62 |
| 标签行（2 个） | 30 | 30 |
| 正文（overview 3–4 段） | 332 | 248 |
| 计数行 | 30 | 30 |
| 时间线条 | 56 | 56 |
| 折叠条（带预告） | 41 | 41 |
| 上下留白 | 30 | 30 |
| **内容合计** | **631** | **547** |
| **窗口（+28 标题栏）** | **659** | **575** |

620 宽下 659pt 仍在 `0.85 × 900 ≈ 765` 上限内，折叠态一屏读完不滚动。760 宽下 575pt，比 v3.7.0 的固定 760 省 185pt。

## 4. P2 — 研究引擎：从「枚举覆盖」到「缺口收敛」

### 4.0 对标结论（三目标）

调研了四个开源/公开的深度研究实现，只取与本次三目标直接相关的机制：

| 项目 | 核心机制 | 对本方案的意义 |
| --- | --- | --- |
| **STORM**（Stanford，NAACL-2024） | **Perspective-Guided Question Asking**：不是枚举角度，而是先读一批**同类文章**，从它们的目录反推出该话题实际存在的视角，再用这些视角驱动提问 | 我的「五个角度」写死成枚举，模型只能照抄；角度应当**从同类文章推出**，这是公式层最大的一处可优化 |
| **LangChain open_deep_research** | supervisor 循环：反思 → 派 sub-agent → **压缩每路结论** → 判断是否继续；`max_researcher_iterations` 与 `max_concurrent_research_units` 双重闸门 | 「一轮固定查询」不可收敛。改为**两轮：广搜 + 补缺**，第二轮查询由第一轮的缺口生成 |
| **GPT-Researcher deep** | breadth × depth 树状递归；官方数据 **5 分钟 / 约 $0.4**（o3-mini high） | 对照我们实测 deep **平均 57.1s**、`aiCalls 5–6`。我们是「快而薄」，不是「慢而厚」——加检索有充裕的时间余量 |
| **LDR（local-deep-research）** | `focused-iteration` 策略自称 factual accuracy ~95%，原则是 **start broad → narrow progressively**；iterations 默认 5–8 | 同上的收敛式，而非一次性枚举 |
| **DeepResearch Bench（RACE/FACT）** | RACE 四维：**Comprehensiveness / Insight-Depth / Instruction-Following / Readability**；FACT 两项：**Citation Accuracy** 与 **有效引文数** | 「用户需要什么」有公开、有人工对齐的度量。Gemini-2.5-Pro DR 平均 **111 条有效引文**，我们实测 **4.3 条** |

三个目标各自的结论先写在前面：

1. **公式**：`D = A + Q` 是**审计分数**，不是**生成策略**。它只评价结果，不告诉引擎下一轮查什么。真正的驱动公式应是**缺口收敛**，见 §4.1。
2. **开销**：最大的浪费不是查询数，是 `Stage 2` 的**串行检索**（实测 deep 57.1s 里，第一条来源落库要 33.1s——58% 的时间在规划与串行检索）。并发化是**零成本**收益，比砍查询更值得做。
3. **用户需要什么**：现状最严重的不是「数字太多」，是**36 份报告里 35 份 `verdict = unverified`、35 份 `strength = 0`**。恒为默认值的标签不携带信息。详见 §5.0。

### 4.1 公式：两层，驱动层用缺口收敛

原方案只有一层（审计分数），缺了「下一轮问什么」这一层。补上：

#### 驱动层（生成策略）

> **R₀ = 由同类文章推出的疑问句集合**
> **R_{n+1} = R_n − 本轮已答上的疑问**
> **停止条件：|R_{n+1}| ≥ |R_n|（无进展）或 n = 2 或预算耗尽**

`R` 是**未答上的疑问**，不是检索词。一轮查询的价值 = 它消除了几个疑问，而不是它发了几个请求。这直接来自 STORM 的视角发现 + LDR 的 broad→narrow。

落在我们的预算上就是**两轮**：

| 轮 | 查询来源 | 目的 |
| --- | --- | --- |
| 第 1 轮 | 广搜，覆盖 5 类疑问（见 §4.2） | 摸清这个话题有哪些疑问是**有公开答案的** |
| 第 2 轮 | 由第 1 轮的**缺口**生成（哪些疑问零证据 / 只有单一来源 / 只有转述） | 只补缺口，不再广撒 |

第 2 轮在预算内实现（`aiCallLimit` 8，实测用 5–6，+1 次补缺规划后 6–7）。

#### 审计层（质量分数，保留）

> **D = A + Q**
>
> **A** = 命中的事实角度数（0–5），每个角度需 **≥2 条已验证事实**
> **Q** = 命中的评论象限数（0–4），每象限需 **1 条通过核验的引文**

| D | 判定 | 界面表现 |
| --- | --- | --- |
| 0–2 | 只是核查 | 不给「深度研究」标识 |
| 3–4 | 可用 | 正常 |
| 5–6 | 深度 | 正常 + 角度齐全 |
| 7–9 | 优秀 | 可作为样例 |

分两层的原因：驱动层决定**花钱的方向**，审计层决定**是否值得展示**。原方案把两者合成一个分数，于是「分数低」只能事后发现，无法指导下一轮。

### 4.2 五个角度：抽取时打标签，不额外检索

**这是本轮最省的优化。** 原方案要给每个角度单独分配 2 条查询（5 × 2 = 10 条），理由是一个角度只发 1 条查询拿不到 2 条事实。

但实测显示：deep 只读 **6–7 个页面**，抽 **4.3 条引文**，时间线 **0–7 个节点**。资料总量本来就不缺，缺的是**同一份资料的多次提问**。

所以：**检索不变，抽取时给每条引文打上它回答的角度标签。**

```json
{"evidence":[{"source":1,"quote":"…","claim":"…","angle":"time|compare|structure|cause|next","stance":"…"}]}
```

- 同一批页面、同一批抽取调用（deep 仍 3–4 批）、同一预算
- 抽完即可算出 A：某角度有 ≥2 条已核验引文 → 命中
- 零命中的角度就是第 2 轮的**缺口输入**（§4.1），不是硬凑的对象

`angle` 缺失时按 `claim` 归入最接近的一类；解析器容忍缺失（旧模型照常工作）。

五个角度的定义与双十一样例不变：

| 角度 | 回答 | 双十一样例 |
| --- | --- | --- |
| `time` 时间纵深 | 上一次什么样 | 去年 2,840 万台 |
| `compare` 横向坐标 | 别人／别处什么样 | 黑五 +6%、印度 +14% |
| `structure` 结构解剖 | 谁拿走什么 | 前五全是 iPhone，华为 +29% |
| `cause` 动因与外溢 | 为什么、波及谁 | 国补退坡、存储涨价外溢 |
| `next` 后续观察 | 接下来看什么 | 双十二预售、Q4 财报口径 |

**操作定义（必须写进提示词）**：一个角度 = **一组指向同一疑问句的检索词**。「去年多少」与「前五是谁」是两个疑问，两个角度；「销量数据」与「战报销量」是同一疑问，一个角度，多余查询丢弃。

**现状**：`ResearchPrompts.swift:99` 写的是「检索词要覆盖不同角度（事件时间线、官方回应、事实核查/最新进展）」——这三者回答的是同一个疑问「这件事对不对」，所以产出永远落在同一条线上。这是实测 A ≈ 1 的根因：`status` 全是 `unclear`。

**第 2 轮的缺口规范**（提示词）：只针对「零已验证引文」「仅单一来源」「仅转述」的疑问发问，最多 4 条，且必须与第 1 轮查询字面不同（防止重复烧钱）。

### 4.3 timeline 标题改为量化事实

合成提示词新增约束：

- `timeline[].title`：**能定量则写定量**（含数字、比例、排名），不超过 12 字。
- 数字必须出现在该节点 `evidenceIDs` 所引引文中。
- 无法定量时写「主体 + 动作」，仍 ≤ 12 字。
- 不得写事件名、栏目名、通稿标题。

**确定性校验（低成本、不删数据）**：新增 `TimelineTitleFigures.unsupportedTitles(report:)`——标题含数字但所引引文均不含任何该数字时，计入一处「待核」。命中时在 `limitations` 追加一句读者语言提示（「部分节点标题中的数字未能在引文中逐字找到，请以引文为准」），不删除节点、不清空 `evidenceIDs`。

理由：模型完全能编「销量下降 17%」。这条与四象限硬门槛共用同一套「逐字核验」基础设施，是同一原则的前移。

**注意**：实测 36 份报告里有 `nodes = 0` 与 `nodes = 1` 的情况各若干。所以折叠条不能只预告节点数，必须能容 0（§P1-5 已按此设计）。

### 4.4 检索并发：同预算下的墙钟收益

**实测的墙钟分解**（28 份 deep 记录，用 `progressFacts` 里 `sourceLocated` 的时间戳反推）：

| 指标 | 实测 |
| --- | --- |
| deep 总墙钟 | 均值 **57.1s**，最快 19.5s，最慢 105.3s |
| **第一条来源落库的时刻** | 均值 **33.1s**（占总数 **58%**） |
| 单次查询耗时 | 3–6s（6 条串行约 20–35s） |

也就是说：**从开始到第一页被读到，要花掉整条 pipeline 的六成时间。** 这 33s 里只有规划（1 次 AI 调用）与串行检索，没有任何产出落地。

> 一个测量口径的诚实说明：`sourceLocated` 是在读页循环**结束后**批量追加的，所以这批时间戳的跨度恒为 0，无法用它拆分「读页耗时」。它只能证明「来源落地很晚」，不能证明检索具体占多少。上表的 33.1s 是**规划 + 检索 + 选页**的合计。

**改动**：把 Stage 2 改为有界并发（`withThrowingTaskGroup`，并发上限 3），与 Stage 4 的读页循环同一写法。

`SearchAttemptTicket`（`SearchTypes.swift:328`）已用 `NSLock` 保护 `consumed`，本身就是并发安全的；`SearchRouter` 的缓存走 actor。所以无需改这类基础设施。

**收益（估算，执行时用真机核对）**：

| 项 | 现状 | 并发后（14 条查询） |
| --- | --- | --- |
| 检索墙钟 | 6 条 × ~5s ≈ 25–35s | 14 ÷ 3 ≈ 5 波 × ~5s ≈ 25s |
| 首来源落库 | 33.1s | ≈ 25s |
| 总墙钟 | 57.1s | ≈ 45–50s |

即**检索量翻 2.3 倍，总时长反而略降**。这是 P2 里唯一「免费」的一项，先做。

**风险**：并发会同时打多家搜索商，可能触发限流。处置：沿用现有 `blockedProviders`（403 即本轮停用该商）+ 并发上限 3，不做更高。执行时用 `SearchFailoverTests` 与真机日志核对 `failovers` 是否异常上升。

**为什么不砍查询来省钱**：砍查询直接减少材料密度，而这正是 §5.0 里最大的短板（4.31 条引文）。并发是唯一「不花材料也不花等待」的优化。

### 4.5 预算与档位

| 档 | 第 1 轮广搜 | 第 2 轮补缺 | 评论象限 | 合计 | 原 queryCount |
| --- | --- | --- | --- | --- | --- |
| quick | 2 | 0（不跑第 2 轮） | 1 | 3 | 2 |
| standard | 3 | 2 | 2 | 7 | 4 |
| deep | 6 | 4 | 4 | 14 | 6 |

- `DepthProfile.maxSearchHTTPCallsPerTask`：**12 → 18**。唯一预算常量改动。deep 的 14 条查询实测约 16 次 HTTP（一条 deep 记录实测 `queriesPlanned 6 → searchCalls 7`，约 1.17 次/查询）。
- `aiCallLimit` 不变（deep 8）：实测 5–6，补缺规划 +1 后 6–7，仍有余量。
- AI 成本不变；检索请求 deep 6 → 14（**+133%**）、standard 4 → 7（+75%）。
- 参照 GPT-Researcher deep 的 5 分钟 / $0.4：我们并发后约 45s、AI 调用数更少。**时间余量是有的，缺的是把余量用在收敛而不是广撒。**

## 5. P3 — 四象限评论

### 5.0 先解决「用户不需要什么」：恒为常量的 verdict

**本机 36 份真实报告实测：**

| 字段 | 分布 | 问题 |
| --- | --- | --- |
| `verdict` | `unverified` **35** / `mostlyConfirmed` 1 | 首屏最醒目的彩色标签，**94% 的报告是同一个值** |
| `strength` | **0** 占 35 / `2` 占 1 | 同上 |
| `quoteVerified` | **155/155 = 100%** | 引文可信度已经满分 |
| `independentSources` | 与去重域名数 **0 例外一致** | 与「N 个域名」同值 |
| `syndicationGroup` | 155 条里 **0 条**有值 | 转载合并从未生效，故独立来源退化为域名数 |

**结论一：一个恒为常量的字段不携带信息，但它是否该下首屏要量过再定。**

94% 取同一值，读者会学会忽略它，然后连带忽略整行 chrome。但「删掉」是不可逆的决定，而 `verdict` 的分布恰恰是 P2 要改善的对象之一——先删后测，等于把验收指标一起删了。

处置（与 §P1-2 完全一致，分两步）：

1. **P1 不动标签行**。首屏只改计数行口径（P1-3）：`最高 M 级` 已经在解释「为什么未证实」。两个信号互相印证，不是重复。
2. **P2 后用 80% 规则决定** `verdict` 是否降级为条件标签。规则写在 §P1-2，先定后测。

`verdict` 始终留在数据层、Markdown 导出、通知摘要里——讨论的只是它要不要占首屏一行。

**结论二：对标 DeepResearch Bench 的 FACT 指标，我们极准但极薄。**

先限定口径：FACT 的 Citation Accuracy 是「陈述–URL 对的支撑率」，我们这 100% 是「抽到的引文逐字命中率」（`quoteVerified`）。**两者不是同一个量**，不能并列。可比的只有量级方向：

| 指标 | Gemini-2.5-Pro DR | Perplexity DR | OpenAI DR | **本机 36 份** |
| --- | --- | --- | --- | --- |
| 引文逐字命中率（我们）/ C. Acc.（他们） | 81.44 | 90.24 | 77.96 | **100%**（155/155，口径不同） |
| 有效引文数 / 份 | 111.21 | 31.26 | 40.79 | **4.31** |

第二行才是可比的那一行，也是真正的问题：**4.31 vs 31–111，差一个数量级。** 不追 111（那是 30 分钟 PhD 级报告的规模），但 P2 必须把它推到 6–12。薄，才是「扩展信息」失败的直接原因。

同时它解释了 `verdict` 恒为 `unverified`：`ReportValidator` 用 tier 与独立来源数算 strength，而 tier3 占 129/155、独立来源退化为域名数——**不是核验做得不好，是可核验的材料不够**。所以 P2 同时改善「引文数量」和「`verdict` 分布」，这两件事本是一件事。

**结论三：RACE 的四个维度里，只有两个归 P1 管。**

| RACE 维度 | 本方案谁负责 | 现状 |
| --- | --- | --- |
| Comprehensiveness 全面性 | P2（补缺收敛 + 量化标题） | 4.3 条引文 / 0–7 节点 |
| Insight/Depth 洞察深度 | P2 + P3（角度 + 四格评论） | 全 `unclear` |
| Instruction-Following 指令遵循 | 引擎既有（`ReaderFacingText`、schema 约束） | — |
| Readability 可读性 | **P1**（去章名、收敛计数行、段落、折叠条预告） | 首屏原为数据仪表盘 |

所以 P1 不是「美化」，它直接对应一个官方评测维度。

### 5.1 四格

| | 中 | 外 |
| --- | --- | --- |
| **古** | 同类机制的历史先例 | 外文的历史类比 |
| **今** | 当下中文舆论场 | 当下外文舆论场 |

「古」必须精确，否则模型会编造：**同一品类、同一机制**的历史事件。双十一的「古」是 2016 年补贴退坡、2021 年直播电商分流，不是「古罗马也有集市」。

每格三种状态：

- **有**：署名、出处、逐字核验全通过 → 正常渲染
- **弱**：署名与出处通过，逐字未通过 → 渲染并标「转述」
- **缺**：不渲染、不占位、不写「暂无」。空格优于空话。

### 5.2 三道硬门槛（唯一防注水机制）

评论是最容易编的地方。三条**全部由确定性代码校验**，不采信模型声明：

1. **署名可查**：`speaker` 归一化后必须能在出处页面正文中找到。
2. **出处可达**：`ReaderNavigationPolicy.allowedURL`（`ReaderNavigationPolicy.swift:25`）通过，且本轮确实读到该页（`documents[canonicalURL]` 存在）。
3. **引文逐字**：复用 `QuoteVerifier.verified`（`ReportValidator.swift:7`，最短 8 字、命中率 0.6）——与 `EvidenceItem.quoteVerified`（`ReportValidator.swift:313`）同一实现。

任一不满足：门槛 1、2 直接丢弃；门槛 3 降级为「转述」。降级与丢弃的计数写进日志，不进 UI。

### 5.3 Schema（最小、向后兼容）

```swift
// BurstResearch 新增，默认 []，旧报告解码不失败
var commentary: [CommentaryItem] = []

struct CommentaryItem: Codable, Hashable, Sendable, Identifiable {
    let id: String               // C1…Cn，与 E 编号分开
    let era: CommentaryEra       // .past / .present
    let origin: CommentaryOrigin // .domestic / .foreign
    let speaker: String          // 署名，必须能在出处中搜到
    let role: String?            // 头衔／身份，可为空
    let quote: String
    let quoteVerified: Bool
    let url: String
    let domain: String
    let publishedAt: Date?
    let evidenceID: String?      // 指向支撑事实的 E 编号
    let isParaphrase: Bool       // 逐字未通过时的降级标记
}
```

`commentary` 与 `evidence` **平级**：

- 不参与时间线排序
- 不进 `E` 编号体系（C 与 E 分开）
- 不计入 `independentSources`、`claims`、`verdict`——现有四级 tier 与独立来源计数不受污染

### 5.4 落地位置（关键约束）

**不能新增 `ResearchReportSection` case**：`allCases`/`index`/`title` 会同时改掉工作台的章节 tab 栏，违反「工作台零变化」。

呈现位置：`ResearchReportReader.bodyContent`（`ResearchReportReader.swift:242`）的 `if disclosure.isExpanded` 分支内——该分支只有 `foldsDetailChapters == true`（仅弹窗）才可达。在遍历 `detailChapters` 时，紧随 `.timeline` 之后插入 `ResearchCommentarySection`（`commentary` 为空则该块不出现）。

阅读顺序：事实（时间线）→ 各方怎么看（评论）→ 核验 → 来源。

### 5.5 评论从哪来

合成调用直接返回 `commentary[]`，validator 逐条过门槛。**不改抽取提示词与 schema**，AI 调用数不变（评论查询已在 §4.5 计入检索预算）。

评论文本进合成输入的方式：四格命中的引文以 `[C1]`…`[Cn]`（与 `[E1]` 分开）交给合成模型，要求它只在四格内引用，每格最多一条。**为什么不让合成模型自己编评论**：它会编「有专家认为」。四格只能从检索到的原文里取，合成阶段只做选择与归属，不做创造。

### 5.6 版本与复用

`ResearchPrompts.version` 当前为 3（`ResearchPrompts.swift:51`）。`ResearchReuseSignature.promptVersion`（`ResearchIncremental.swift:38`）决定旧报告能否复用。

- P2 发布：3 → 4（标题形态与角度约束变了，旧报告不该复用）
- P3 发布：4 → 5

旧记录仍然可读（Codable 默认值），只是不再被当作「同配置可复用」。

## 6. 执行顺序与验收

阶段顺序按「零成本 → 低成本 → 需真机」排列，每阶段独立可回退。

| 阶段 | 内容 | 验收（必须能测出来） |
| --- | --- | --- |
| **P1** | 弹窗 P1-1 去章名、P1-3 计数行改口径、P1-5 折叠条预告 | `swift build`；`swift test`（2113 + 新增）；620/760 × 折叠/展开 四张快照目检；工作台相关断言保持通过 |
| **P2a** | Stage 2 检索并发化（并发上限 3） | **不改就量化不了后续一切**。验收：wide 查询墙钟下降；`SearchFailoverTests` 绿；真机 3 次 deep 的 `searchCalls/failovers` 与旧值对比不异常 |
| **P2b** | 抽取打 `angle` 标签 + 第 2 轮缺口补搜 + 量化标题 | 跑 3 条 deep：A 命中数（目标 ≥3）、timeline 标题含数字比例（目标 ≥50%）、有效引文数（目标 6–12） |
| **P2c** | `verdict` 分布复测 + 条件标签决策 | 3 条新报告的 `verdict` 分布，按 §P1-2 的 80% 规则决定是否降级 |
| **P3** | 四象限评论 + 三门槛 | 伪造署名／不可达 URL／引文不符三条单测必须被拒；真实记录至少一格命中 |

**P2a 放在 P2b 之前**，因为补搜会让查询数翻倍，不先并发化就是拿墙钟换质量，等于用用户等待时间付账。

验收的量化基线（现状 → 目标）：

| 指标 | 现状实测 | P2 后目标 |
| --- | --- | --- |
| 有效引文数 / 份 | 4.31 | **6–12** |
| `verdict = unverified` 占比 | 94% | **< 80%** |
| A 命中角度数 | ≈1（`status` 全 `unclear`） | **≥3** / 5 |
| timeline 标题含数字比例 | 0% | **≥50%** |
| deep 总墙钟 | 57.1s 均值 | **≤ 60s**（检索翻倍但不许变慢） |

目标不达成的处置：**先记录真实数字再决定**，不调低目标、不改验收口径。

## 7. 风险与回滚

| 风险 | 处置 |
| --- | --- |
| 检索预算涨到 1.3 倍，撞自动研究每日上限 | **已核实：自动研究不按 origin 降档。** `NewsOrchestrator.scheduleResearch`（`NewsOrchestrator.swift:1546`）对自动与手动统一传 `depth: settings.researchDepth`，`executeResearch` 仅在没有显式 depth 时才回落同一值 → 用户把默认档设成 deep，自动研究也会跑 deep。`automaticSearchDailyLimit` 默认 20，deep 单任务 16 次 → 自动研究一天只能跑 1 条 deep。P2 执行时必须**在 `isAutomaticRun` 分支把 depth 钳到 `.standard`**（`NewsOrchestrator.swift:1605` 已算出该标志），deep 只由工作台手动触发 |
| 角度硬凑产生空话 | 公式隐含门槛：角度不足宁可少写，差额记进现有 `missing`，不补足 |
| 量化标题编数字 | §4.3 的逐字校验 + 合成提示词禁令；命中只提示不删数据 |
| 评论四格被注水 | 三门槛全确定；任一不过即降级或丢弃，模型无权声明「已核验」 |
| `promptVersion` 提升导致下次打开重跑 | 有意的：旧报告的标题形态与角度覆盖不满足新契约。报告仍可读，仅不再复用 |
| 折叠条新增文案破坏本地化 | zh + en 同时加 key，`LocalizationParityTests` 与「used but undefined」lint 兜底 |

回滚：

- P1：`ResearchReportPresentation.swift` / `ResearchReportSections.swift` / `ResearchTimelineStrip.swift` / `ResearchReportReader.swift` 四处回退，无数据迁移。
- P2：`ResearchPrompts.swift` + `DepthProfile` 回退；`promptVersion` 保持不降（降版会让 4 版报告被 3 版标签复用）。
- P3：`commentary` 字段留在 schema 里无害（默认空数组），只回退 UI 与门槛代码。

## 8. 用户已定的判断准则（本方案的自检线）

- 不加 schema 字段能解决就不加；必须加时用 Codable 默认值向后兼容。
- 入口去重：同一目标不出现第二条路径。
- 层级靠字号 × 字体族 × 字距 × 留白，不靠盒子、边框、底色。
- 评论宁可少写不可补足。
- 一切以 UX 为先，长期稳定为目标，不妥协 UX。
