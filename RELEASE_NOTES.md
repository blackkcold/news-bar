## [Unreleased]

## [v2.3.0] - 2026-08-05

### ✨ 新功能
- **RSS 标题翻译**：英文界面下可开启 RSS 标题自动翻译（免费 MyMemory 服务），翻译结果缓存避免重复请求与限流；原文始终保留用于 AI 总结，失败自动回退原文。
- **多语言本地化框架**：新增轻量 `L10n` 本地化层（无需 `.xcstrings` bundle），界面文案全面支持中英双语，随语言设置实时切换。

### ⚡ 性能与稳定性
- **AI 总结提速与截断修复**：请求超时由 30s 提升至 60s；输出 token 预算按摘要长度动态扩容，避免 360 字简报被截断。
- **DeepSeek 思考模式开关**：新增「关闭 DeepSeek 思考模式（更快输出）」设置项（默认开启）。DeepSeek V4 思考过程会占用输出额度并拖慢速度，关闭后可大幅提速并避免摘要截断；可在设置中重新开启以换取更高归纳精度。
- **AI 截断判定增强**：即使返回 `length` 截断标记，只要已解析出【趋势概览】与【每日精选】两个完整板块即视为摘要完整，消除「内容其实完整仍被标记为不完整」的误报。
- **AI 请求兼容性**：放宽响应 `Content-Type` 校验，兼容代理缺失请求头的情况，减少偶发「AI 总结失败」。

### ✅ 测试
- **全量测试**：`swift test` 333/333 通过。

## [v2.2.3] - 2026-08-04

### ✨ 新功能
- **AI 两层判断 + 爆标签即时触发**：AI 摘要新增两层判断。常态下统一按「距上次总结 ≥ 1 小时」作为自动生成基准；当识别到微博热搜出现「爆」标签话题时，立即触发一次总结，并强制将带爆标签的微博热搜纳入【趋势概览】优先展示。爆标签成功总结后 15 分钟内不重复触发。
- **微博状态标签识别**：新增解析微博热搜 `label_name`（爆/沸/热/新）及 `is_boom`/`is_fei`/`is_hot`/`is_new` 布尔兜底标记，作为 AI 即时触发的依据。
- **Ollama Cloud 提供商**：新增 Ollama Cloud 内置提供商，支持 deepseek-v4-flash:cloud、deepseek-v4-pro:cloud、gpt-oss、kimi-k3、minimax-m3 等云模型。
- **自定义 AI 提供商**：支持用户自定义端点、模型 ID 与认证头，灵活接入任意兼容 OpenAI 的服务。
- **AI 模型折叠**：默认仅显示各供应商的 DeepSeek 系模型；在「通用 → 开发者选项」开启「显示全部 AI 模型」可查看全部官方模型。

### 🐛 稳定性修复
- **AI 冷却倒计时假死修复**：Popup 与 Dashboard 的「重新生成/独立刷新」按钮冷却倒计时由静态快照改为每秒实时刷新，倒计时结束后自动解除禁用，不再出现按钮无法点击的假死问题。

### ✅ 测试
- **新增测试**：`testBurstWeiboTriggersImmediatelyButThrottled` 覆盖爆标签即时触发与 15 分钟去抖；`testAutomaticSummaryRespectsTrendAndRSSMinimumIntervals` 更新为 1 小时基准。
- **全量测试**：`swift test` 322/322 通过。

---

## [v2.2.2] - 2026-08-03

### ✨ 新功能
- **共享 AI 摘要**：Popup 与 Dashboard 复用同一份详细 AI 简报，不再各自独立生成。Popup 每类最多显示 2 条，Dashboard 显示完整结果，消除重复 AI 请求。
- **Dashboard AI 独立刷新**：AI 简报面板新增独立刷新按钮，支持 60s 冷却保护，不依赖全局刷新。
- **RSS 单源刷新**：Dashboard 每个 RSS 源卡片增加独立刷新按钮，带加载状态反馈，不影响其他源。
- **智能刷新调度**：热搜按可见性自适应刷新（可见 5 分钟/后台 30 分钟/低电量 60 分钟），RSS 按活跃度自适应（30 分钟/60 分钟/3 小时），失败退避（15 分钟 → 30 分钟 → 60 分钟 → 最长 3 小时）。
- **12/24 小时趋势历史**：新增 TrendHistoryStore，24 小时滚动保留最多 288 个快照，30 分钟 heartbeat，趋势评分与变化摘要，跨启动持久化。
- **历史感知 AI 总结**：AI 自动总结结合近 12/24 小时趋势历史，仅在显著变化及冷却条件满足时重建（趋势 ≥30 分钟、RSS ≥4 小时），避免重复总结热点。
- **AI 摘要持久化**：新增 AISummaryCacheStore，持久化摘要内容、内容哈希、趋势哈希、引用快照和生成时间，跨启动恢复。
- **RSS 条件请求**：支持 ETag/Last-Modified 与 HTTP 304，减少无效网络传输。

### ⚡ 性能优化
- **Popup 实例复用**：首次打开后复用 NSPopover 实例，消除重复创建 SwiftUI 树的开销。
- **启动缓存预热**：App 启动时异步预加载缓存数据，减少首次打开 popup/Dashboard 的等待时间。
- **图片缩略解码**：ImageCache 新增 CGImageSource 缩略图解码（最大 480px），避免 SwiftUI 渲染时解码原始大图。
- **图片请求合并**：相同 URL 的并发请求自动合并，减少重复网络开销。
- **Popup 外层懒加载**：ScrollView 内 VStack 改为 LazyVStack，延迟非可见区域视图创建。
- **日期格式器复用**：Popup 与 Dashboard 的 DateFormatter 提升为静态常量，避免每次 body 重建。
- **缓存 freshness 追踪**：新增 lastValidatedAt 字段，stale-while-revalidate 策略，过期缓存立即显示不阻塞 UI。
- **AI 逐字动画计算优化**：预计算 RenderModel 和字符数组，30ms/3 字符稳定帧率，AISummaryParser 正则静态缓存。
- **Observation 子树隔离**：Popup AI 区域拆为独立 Observation 子树，减少无关视图刷新。
- **稳定 NewsItem ID**：改为 SHA-256 哈希，消除重复条目。
- **BatchProgress 结构体化**：改为 Equatable struct，减少不必要的 SwiftUI 重绘。

### 🎨 UI 优化
- **RSS 卡片元信息精简**：移除图文卡片底部重复的来源徽章和网址，仅保留顶部来源徽章，底部改为「阅读原文」提示。
- **RSS 文本行精简**：移除来源名称右侧的网址显示，减少信息冗余。
- **AI 设置页简化**：移除独立的 Popup/Dashboard 摘要长度和预算模式选择器，统一为共享摘要长度和共享额度。
- **设置页刷新说明**：通用设置新增智能刷新调度说明和日志类型。

### ✅ 测试
- **新增测试**：`AISummaryParser.limited` 摘要裁剪、`ImageCache.decodeThumbnail` 缩略解码、共享摘要目标常量。
- **测试适配**：截断哈希、连续截断计数、clearCache 等测试从双目标改为共享单目标。
- **新增回归测试**：RefreshTrendPerformanceTests 覆盖刷新调度、缓存 freshness、条件请求、趋势历史、AI 持久化、性能回归。
- **全量测试**：`swift test` 321/321 通过。

---

## [v2.2.0] - 2026-07-30

### ✨ 新功能
- **复古报刊编辑风主题**：新增可持久化的 Retro Editorial 主题，并在设置页主题区域提供切换入口；以米白、砖红、黑色、纸张颗粒、粗边框和硬阴影统一覆盖主要界面。
- **全局主题组件体系**：新增共享主题色、纸张背景、编辑式抬头、剪报卡片、印刷按钮与新闻源徽记，确保 Dashboard、Popup、设置页及状态组件使用同一套视觉语言。

### 🎨 界面重制
- **Dashboard 深度重制**：重新设计窗口导航栏、趋势卡片、AI 简报和 RSS 新闻卡片；居中椭圆标题改为响应式布局，并移除重复标题与文字阴影重影。
- **Popup 深度重制**：重做新闻分区、AI 摘要、新闻行、RSS 文本流与图片流、底部操作栏和更新提示，使主题在完整弹窗流程中保持一致。
- **主题形态统一**：复古主题下将圆角容器与控件切换为方框和硬边界；普通模式同步引入更清晰的页面抬头结构，同时保持现代材质外观。
- **新闻源与热搜符号重制**：为微博、B 站、RSS 与趋势排行提供适配复古报刊语义的印刷式 UI 符号、徽记和状态标识。

### ✅ 测试
- **主题状态回归测试**：覆盖主题默认值、持久化、无效值回退和复古主题配色解析。
- **全量测试**：`swift test` 303/303 通过。

---

## [v2.1.0] - 2026-07-29

### 🔐 安全增强
- **更新下载信任链加固**：仅接受 canonical GitHub Release 元数据与 GitHub 自有下载主机组合，拒绝代理元数据、第三方主机及重定向攻击路径。
- **网络与图片负载上限**：为微博、B 站、RSS、AI 响应设定大小上限；图片缓存校验 MIME 类型和 10 MB 单文件上限，并限制总缓存成本。
- **1Password 引用校验**：校验 `op://` 引用格式，并以异步读取避免阻塞主线程。

### 🐛 稳定性修复
- **AI 预算共享正确记账**：Popup 与 Dashboard 共享每日请求基线，避免并发生成或重试重置预算；两端截断计数彼此隔离。
- **摘要生成更可控**：Dashboard 仅在打开时惰性生成，避免普通刷新触发不必要的 AI 请求。

### ✨ 交互与一致性
- **设置操作增加确认**：删除 RSS 源、清除缓存与退出应用均提供明确确认，减少误操作。
- **原生可访问控件**：更新提示改用原生 Button，AI 摘要重试状态由实际生成与冷却状态驱动。

### ✅ 测试
- **新增安全与回归测试**：覆盖更新信任链、HTTP 负载边界、图片缓存、1Password 引用及 AI 预算/截断状态；全量 `swift test` 301/301 通过。

---

## [v2.0.8] - 2026-07-28

### 📦 构建优化
- **DMG 打包增加 Applications 文件夹快捷方式**：打开 DMG 即可看到 Applications 文件夹符号链接，用户可快速拖入安装
- **自定义 DMG 背景布局**：新增 Resources/DMGBackground.png 深色玻璃质感背景图，Finder 图标自动定位在 {200,200}（App）和 {600,200}（Applications）
- **DMG 打包流程重构**：从纯 hdiutil 升级为 staging + 可写 DMG + Finder layout 两阶段流程，支持自定义背景和图标布局

### 🔧 改进
- `scripts/build.sh`：新增 DMG_STAGING 临时目录组装；osascript 写入 Finder 窗口布局（图标位置/大小/背景/视图选项）；压缩阶段添加 zlib-level=9 提高压缩率

---

## [v2.0.9] - 2026-07-29

### 🐛 Bug 修复
- **Popup AI 摘要格式异常不再显示原始长文本**：当 AI 返回的响应无法解析出任何主题板块时，自动以更严格的格式约束重试一次（受日调用上限约束）；重试后仍不可解析则显示格式错误提示与「重新生成」按钮，不再回退显示原始 AI 文本。
- **来源徽章首次启动一致性**：摘要状态、解析结果与新闻快照作为同一生成结果提交，消除首次渲染时来源索引映射的残余时序风险。

### ✅ 测试
- **新增离线回归测试**：覆盖不可渲染格式的解析器行为、格式重试判定逻辑、重试预算边界，共 15 个新测试用例。

### 🔧 改进
- **格式重试受预算约束**：重试计入既有日调用上限，不绕过预算检查；最多一次，不循环。
- **开发文档同步**：`.memory/PROJECT_BOOTSTRAP.md` 更新 AI 生成/重试说明。

---
## [v2.0.7] - 2026-07-28

### 🐛 Bug 修复
- **Popup AI 摘要逐字生成保持 SectionRow 与可点击来源角标**：逐字生成时不再切换成单个原始文本块，保持 SectionRow 结构和来源角标可点击。
- **修复内联引用格式未提取来源**：修复 `【标题】正文[#N]` 格式中来源未正确提取的问题，Popup 现可正确显示并点击来源角标。

## [v2.0.6] - 2026-07-28

### 🐛 Bug 修复
- **无引用趋势概览不再消失**：趋势概览分类明确标注为「趋势概览」时，即使无有效引用编号，该段落仍保持可见，不再被错误隐藏。无引用时不显示来源角标

### ✨ 新功能
- **Popup 双分类渲染**：Popup AI 摘要面板与 Dashboard 一致，支持「趋势概览」和「每日精选」双分类渲染，分段显示
- **引用来源角标常驻可见**：有有效引用编号的 AI 摘要行，来源角标始终可见（不再仅悬停显示），点击即可跳转原始新闻

## [v2.0.5] — AI 摘要截断修复 & Dashboard 信息量增强 - 2026-07-27

### 🐛 Bug 修复
- **Popup AI 截断内容不再卡死**：修复截断时 `popupLastHash` 仍被更新导致自动刷新跳过生成的问题。新增双哈希去重（`popupLastTruncatedHash`/`dashboardLastTruncatedHash`），截断写截断哈希不污染成功哈希，成功后清除截断哈希
- **Dashboard 截断死锁修复**：`generateDashboardSummaryIfNeeded` 的 `shouldGenerate` 增加 `dashboardLastTruncatedHash` 检查，`dashboardSummaryNeedsGeneration` 增加 `.truncated` 触发重试，消除截断后重开 Dashboard 不再生成的死锁
- **regenerateAISummary 哈希泄漏修复**：将哈希管理从 3 个调用方内聚到 `generateSummary` 内部统一处理，消除手动重新生成截断后不更新哈希导致下次自动刷新重复生成的预算泄漏
- **连续截断保护**：新增 `consecutiveTruncationCount` 计数器，连续截断 ≥3 次自动停止重试，防止变化条目持续截断导致预算消耗，用户仍可手动重新生成（60s 冷却限制频率）

### ✨ 新功能
- **Dashboard AI Briefing 信息量增强**：趋势概览和每日精选话题数从 2-3 提升到 4-5，确保 Dashboard 摘要信息量多于 Popup
- **AI prompt 话题数参数化**：`AISummaryService.summarize` 新增 `trendTopicCount`/`dailyTopicCount` 参数，Popup 保持 2-3，Dashboard 4-5，prompt 模板动态插值

### 🔐 安全/隐私增强
- **AI 反幻觉规则**：systemPrompt 新增规则 7「禁编造：在条目不足以填满请求的话题数时，绝不要编造新闻话题；只涵盖可用内容」
- **AI prompt 标题隔离**：sanitizeTitle 在注入 prompt 前剥离控制字符和【】/ [# 结构定界符，防止外部新闻标题恶意破坏 prompt 格式或注入指令
- **AI 隐私边界声明**：system prompt 明确标注用户提供的标题为不可信外部数据，禁止视为指令或提示词注入

### 🔧 改进
- **max_tokens 提升**：`initialMaxTokens` 1024→2048，`retryMaxTokens` 2048→3840（MiniMax 安全边际 5%），降低截断概率
- **clearCache 完整性**：`clearCache()` 新增清理 `popupLastTruncatedHash`/`dashboardLastTruncatedHash`/`consecutiveTruncationCount`

### 🔧 技术细节
- `NewsOrchestrator.swift`：新增 `popupLastTruncatedHash`/`dashboardLastTruncatedHash` 双哈希去重；`consecutiveTruncationCount`/`maxConsecutiveTruncations=3` 连续截断保护；`currentTruncatedHash`/`setTruncatedHash`/`clearTruncatedHash` context-aware helpers 遵循现有 `SummaryTarget` 模式；`generateSummary` 新增 `contentHash` 参数统一管理哈希
- `AISummaryService.swift`：`summarize` 签名增加 `trendTopicCount`/`dailyTopicCount` 参数（默认 2...3）；`promptTopicHint` 静态方法生成话题数提示文本；`systemPrompt()` 新增规则 7 反幻觉；`max_tokens` 2048/3840
- `DashboardAIBriefingPanel.swift`：`dashboardSummaryNeedsGeneration` 增加 `.truncated` 触发重试
- 测试覆盖：184/184 通过（原 165 + 新增 19），涵盖截断哈希去重、连续截断保护、clearCache 清理、dashboardSummaryNeedsGeneration 状态机、prompt 话题数生成

---

## v2.0.0 — 原生 Dashboard & 双分类 AI 简报 - 2026-07-27

### ✨ 新功能
- **原生 Dashboard 窗口**：独立 NSWindow（1180×860，最小 960×720），侧边栏热点趋势卡片（微博/B站，可折叠展开）+ AI 简报面板，右侧按来源分卡的 RSS 固定双列网格区域
- **双分类 AI 简报**：AI 摘要升级为「趋势概览」（仅微博/B站引用）和「每日精选」（所有源）两个板块，Dashboard 中通过 segmented Picker 切换；Popover 保持单分类旧格式
- **Dashboard RSS 按源分卡**：所有已订阅 RSS 源在 Dashboard 主区以独立卡片排列，每卡内固定双列 LazyVGrid 布局，列间距 12pt，图文卡片异步加载图片，按源着色
- **可配置 AI 日调用上限**：新增 aiDailyCap 设置，白名单 20/50/100 次，超出后自动停止 AI 请求
- **Dashboard 状态反馈栏**：显示手动刷新警告和 RSS 批量刷新进度
- **独立 Popup/Dashboard AI 摘要**：Popup 在刷新时生成精简摘要（默认 120 字），Dashboard 在打开时惰性生成详细摘要（默认 360 字），两者各有独立字数预设（Popup: 80/120/160/200；Dashboard: 240/360/480/600）并共享每日 AI 调用上限
- **Dashboard RSS 固定双列网格**：Dashboard RSS 卡片区域改为固定双列 LazyVGrid（GridItem(.flexible(), spacing: 12) × 2），原生列管理，不再依赖 onGeometryChange

### 🔐 安全/隐私增强
- **AI prompt 标题隔离**：sanitizeTitle 在注入 prompt 前剥离控制字符和【】/ [# 结构定界符，防止外部新闻标题恶意破坏 prompt 格式或注入指令
- **AI 隐私边界声明**：system prompt 明确标注用户提供的标题为不可信外部数据，禁止视为指令或提示词注入
- **per-dispatch 预算记账**：每次 HTTP 请求前检查 baseline + attempts ≤ cap，重试也计入 attempts，确保总请求数不超限
- **并发生成锁**：OSAllocatedUnfairLock 防止并发 AI 请求，defer 确保释放
- **手动再生冷却**：60s 冷却窗口，阻止频繁手动再生

### 🔧 技术细节
- `DashboardWindow.swift`：新增，独立 Dashboard 窗口，侧边栏（热点卡片 + AI 简报）+ 按源分卡 RSS 主区，状态反馈栏，工具栏刷新/设置按钮
- `DashboardVisualComponents.swift`：新增，DashboardHotTrendCard（可折叠热点卡片，排名前三彩色徽章）、DashboardAdaptiveRSSMasonryFeed（固定双列 LazyVGrid，GridItem(.flexible(), spacing: 12) × 2，原生列管理）、DashboardRSSMasonryCard（图文卡片，ImageCache 异步加载，hover 高亮）
- `DashboardAIBriefingPanel.swift`：新增，双分类 Picker（trendOverview/dailyEssentials），状态驱动 UI，引用快照回溯，兼容旧格式回落
- `AISummaryParser.swift`：新增 parseDualSummary 双分类解析，按引用编号过滤趋势源，无标签时回落旧格式
- `AISummaryService.swift`：新增 initBudget/consumeAttemptBudget/readGenerationAttempts 预算系统；tryAcquireGenerationLock/releaseGenerationLock 并发生成锁；regenerationCooldownRemaining/recordManualRegeneration 冷却机制；sanitizeTitle 标题消毒
- `AppSettings.swift`：新增 aiDailyCap 字段 + validAICaps 白名单（20/50/100）；aiPopupMaxWords + validAIPopupMaxWords（80/120/160/200）；aiDashboardMaxWords + validAIDashboardMaxWords（240/360/480/600）；recordAIRequests 按实际请求次数记账
- `NewsOrchestrator.swift`：新增 aiParsedSummary/dashboardParsedSummary 双缓存；generateSummary 支持 SummaryTarget（popup/dashboard）区分生成；setSummaryItems/setSummaryState/setParsedSummary 按目标路由；popupLastHash/dashboardLastHash 独立 hash 追踪；Dashboard 打开时惰性触发 generateDashboardSummary
- `AppDelegate.swift`：新增 openDashboard/closeDashboard 窗口管理，dashboardSize/dashboardMinimumSize 常量
- `DashboardWindow.swift`：Dashboard 中 RSS 按源分卡（DashboardRSSSourceCard），Popover 保持每源独立 RSSWaterfallView 行为；Dashboard 打开时触发惰性 AI 摘要生成
- `AITab.swift`：新增 Popup/Dashboard 独立字数预设 Picker + 日调用上限 Picker
- 测试覆盖：165/165 通过，涵盖 Dashboard 组件、双分类解析、预算系统、生成锁、冷却机制

### 🐛 Bug 修复
- **Dashboard RSS 长标题不再撑宽卡片**：修复长标题导致卡片宽度被撑开、列间间隙消失的问题。卡片内容改为 `.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)`，确保所有卡片等宽，列间距稳定保持 12pt

## v1.5.0 — RSS 增强 & 通知推送 - 2026-07-17

### ✨ 新功能
- **RSS 显示计数统一管理**：新增 unifiedDisplayCount 开关，开启后 Popover 与 Dashboard 共享全局文本/图片显示条数；关闭后支持按数据源和显示模式分别设置条数，并提供"恢复默认"一键重置为全局值
- **移除 RSS 上限**：不再限制 3 个 RSS 源，支持任意数量
- **RSS 双列图片卡片**：LazyVGrid 瀑布流布局，自动提取 RSS 配图，16:9 比例裁剪
- **macOS 通知推送**：每小时自动推送最新新闻 + 每日定时摘要推送
- **流式刷新进度**：RSS 源分批 6 并发刷新，BottomBar 显示完成进度
- **已订阅/未订阅分组**：设置页 RSS 源列表按订阅状态分组，清晰区分已订阅与未订阅源
- **拖拽实时预览排序**：已订阅源支持拖拽调整顺序，松开前实时预览目标位置
- **串行可取消推荐验证**：逐源串行验证推荐可用性，支持取消、进度显示、失败重试，完成后汇总通过/失败/已取消统计

### 🔐 安全增强
- **RSS 图片 SSRF 防护**：图片 URL 使用 validateRSSURL 校验，防止内网 IP 探测
- **图片加载隔离**：ephemeral URLSession，不共享 cookie，防止认证信息泄露
- **推荐添加安全验证**：添加推荐源前通过 SecurityPolicies.validateRSSURL 校验，拦截内网/本地地址，警告私有网段

### 🔧 改进
- **差异化刷新**：定时刷新仅更新超过 15min 未变化的源，减少不必要的网络请求
- **单源超时控制**：RSS 请求 10s 超时，防止慢源阻塞批次
- **Popover 宽度 360→400px**：更宽敞的阅读体验
- **图片缓存**：NSCache + ephemeral URLSession，滚动时不重复下载

### 🔧 RSS 显示优化
- **RSS 双模式显示**：文本流(单列紧凑列表 LazyVStack) / 图片流(双列卡片 LazyVGrid)，Picker 标签同步为"文本流"/"图片流"
- **图片流分页加载**：展开后每批加载 4 条，滚动到底自动加载更多，sentinel guard 防无限循环
- **文字优先渲染**：文字即时显示，图片异步加载完成后 spring 动画过渡(.scale.combined(with: .opacity))
- **源级自动降级**：图片流模式下无图片源自动降级为文本流，会话内锁存避免刷新闪烁
- **多源同时展开**：支持多个 RSS 源同时展开，sticky 收起条快速折叠
- **DisplayMode 枚举重命名**：single→text, scroll→image，Codable 自定义 init(from:) 向后兼容旧值(含未知值 silent fallback)
- **RSS 源排序**：设置页支持上下按钮调整 RSS 源顺序，主面板与 Dashboard 同步反映新顺序

### 🔧 技术细节
- `RSSRecommendations.swift`：严格直连策略，10 个出版商自托管 HTTPS 源，覆盖 4 分类（科技/综合/财经/国际）
- `NewsOrchestrator.swift`：新增 batchProgress 字段 + lastSourceRefresh 差异化刷新追踪
- `RSSService.swift`：RSSParserDelegate 新增 enclosure/media namespace/content:encoded 图片解析；fetch 增加 10s 超时
- `SecurityPolicies.swift`：新增 extractFirstImageURL 函数（不修改 forbiddenTags）
- `NewsItem.swift`：新增 imageURL Optional 字段（Codable 向后兼容）
- `NotificationService.swift`：新增，每小时 + 每日通知推送
- `ImageCache.swift`：新增，actor 隔离 NSCache + ephemeral URLSession
- `RSSWaterfallView.swift`：重构为双模式视图(文本流 LazyVStack + 图片流 LazyVGrid) + ImageLoadState 枚举 + 源级自动降级(会话锁存) + 分页加载 + RSSTextRow 组件
- `NotificationTab.swift`：新增，设置页第 5 个 Tab
- `AppSettings.swift`：新增 5 个通知相关字段；DisplayMode 枚举重命名 single→text/scroll→image + 自定义 Codable init(from:) 兼容旧值
- `AppDelegate.swift`：通知权限请求 + 退出时清理 pending 通知
- `RSSTab.swift`：Picker 标签改为"文本流"/"图片流"；新增源默认 .text；新增上移/下移排序按钮 + 无障碍标签
- `PopoverContent.swift` / `DashboardWindow.swift`：新增 expandedRSSSourceIDs/rssLoadedCounts 状态 + sticky 折叠条 + RSSWaterfallView 传参；收起条顺序改为匹配 rssSources 数组顺序
- `DisplayModeMigrationTests.swift`：新增，覆盖旧值/新值/未知值/数组完整性测试
- `RSSTab.swift`：移除 maxSelected 上限逻辑 + 推荐列表按分类分段 + 已订阅/未订阅分组 + 拖拽实时预览排序 + 串行可取消推荐验证面板（进度/重试/汇总）
- `RSSValidationService.swift`：新增，串行可取消推荐验证引擎，区分 blocked/invalidURL/cancelled/networkError/notRSSFeed/success 六种结果，支持重试与汇总统计
- `BottomBar.swift`：新增 batchProgress 进度显示
- `NewsSection.swift`：padding 16→14 适配 400px 宽度

---

## v1.4.2 — Provider 连接修复 & 错误诊断增强

### 🔐 安全修复

- **IOPlatformUUID 日志泄露修复**：移除系统日志中的机器 UUID 明文输出，防止 AES 密钥派生材料泄露

### 🐛 Bug 修复

- **测试按钮保存后变灰修复**：保存 API Key 后测试按钮仍可点击，支持直接测试已保存的 key
- **测试连接 key 优先级修复**：测试连接时优先使用用户当前输入的 key，而非缓存中的旧 key
- **测试输入清理**：测试连接时对输入 key 调用 sanitizeUserInput，与保存流程保持一致
- **启动时 cachedAPIKey 竞态修复**：异步加载未完成时 fallback 读取加密文件，防止首次刷新跳过 AI 摘要；regenerateAISummary 同步修复
- **Opencode 响应格式自适应**：Anthropic 格式解码失败时自动回退到 OpenAI 格式，兼容代理端点格式差异

### 🔧 改进

- **错误诊断增强**：测试连接和 AI 总结失败时细分网络/解码/重试耗尽错误，显示具体提示信息（含 HTTP 状态码和重试次数）
- **安全日志**：所有错误路径添加 NSLog 输出（统一使用 localizedDescription，不泄漏敏感数据）

---

## v1.4.1 — 平台兼容 & 健壮性增强

### 🐛 Bug 修复

- **1Password Apple Silicon 兼容**：支持 `/opt/homebrew/bin/op` 路径，修复 M1/M2/M3 Mac 上 1Password 集成不可用
- **AI 摘要动画竞态修复**：状态变更时取消旧动画 Task，防止快速切换导致文本混合显示

### 🔧 改进

- **更新校验纵深防御**：删除 SHA256 回退路径，统一使用 GitHub API digest 字段
- **Markdown 剥离修正**：重写粗体/斜体正则，正确清理逐字动画中的 Markdown 标记
- **RSS 警告视觉区分**：私有 IP 警告显示橙色而非红色
- **版本兜底值同步**：AppVersion 硬编码兜底更新至 1.4.0

---

## v1.3.6 — Bug 修复 & 健壮性增强

### 🐛 Bug 修复

- **API Key 启动同步加载**：确保定时器触发时 API Key 已就绪，防止首次定时刷新时因 Key 未加载而跳过 AI 摘要
- **Dashboard force unwrap 修复**：修复 Dashboard 窗口中 `orchestrator` 的强制解包，消除潜在的崩溃风险
- **AI 摘要逐字动画取消支持**：将 `Task.isCancelled` 检测改为 `try/catch` 模式，正确响应 Task 取消信号
- **AI 摘要状态数据一致**：新增 `aiSummaryItems` 属性追踪摘要所用的新闻条目，替代实时计算，避免数据不一致

### 🔧 改进

- **AI 摘要重试指数退避**：重试间隔改为指数增长（1s → 2s → 4s），捕获最后一次 HTTP 错误并输出详细信息
- **AISummaryService 错误诊断增强**：在重试全部失败时返回具体 HTTP 状态码，便于定位问题
- **NewsOrchestrator 日志增强**：获取数据源失败时增加 `NSLog` 输出，方便调试

---

## v1.3.5 — 安全加固 & 架构优化

### 🔐 安全增强

- **SHA256 代理验证修复**：修复代理验证逻辑，确保下载完整性校验
- **SSRF 防护加固**：增强服务端请求伪造防护，限制内网访问
- **HTML on* 事件属性纵深防御**：清理 HTML 内容中的危险事件属性，防止 XSS 攻击

### 🏗️ 架构优化

- **HTTPClient 提取**：将网络请求逻辑抽取为独立 HTTPClient 模块，提升可测试性
- **AISummaryParser 拆分**：AI 摘要解析器独立封装，职责单一化
- **并行刷新支持**：多数据源（微博/B站/RSS）可并行请求，提升加载速度
- **SHA256 hash 校验**：下载文件完整性验证机制
- **测试框架搭建**：引入单元测试基础设施

### 🐛 稳定性修复

- **@MainActor 线程安全修复**：确保 UI 更新在主线程执行
- **@Published 线程问题修复**：修复属性发布器的线程竞争问题
- **[weak self] 循环引用修复**：消除潜在的内存泄漏
- **缓存清除逻辑优化**：改进缓存过期和清理策略
- **applyCachedState 状态管理**：优化启动时缓存状态恢复

### ♿ 无障碍

- **无障碍支持增强**：提升 VoiceOver 兼容性
- **动画优化**：改进过渡动画流畅度
- **Magic Numbers 提取**：将硬编码常量提取为可配置参数

---

## v1.3.2 — 自动刷新正文消失修复

### 🐛 Bug 修复

- **修复自动刷新时 AI 摘要只显示标题、不显示正文的问题**：部分 AI 模型会将标题和正文输出在同一行（`【标题】正文内容`），解析器未能正确提取 `】` 后的正文文本，导致段落内容被丢弃、新闻源角标也随之消失。现已修复为正确提取同行内的正文。
- **防止空段落产生**：恢复段落内容空白检查，避免在标题后紧接引用行时产生只有标题没有正文的无效段落。

---

## v1.3.1 — AI 摘要模板框架 & 引用编号源链接

### ✨ 新功能

- **AI 摘要模板框架**：将 AI prompt 从脆弱的 `##` Markdown 格式升级为 `【标题】` 固定模板框架。AI 只需往预设结构中填充内容，不再依赖不稳定的 Markdown 解析。标题用原生 SwiftUI 粗体渲染，正文仅保留内联加粗，版面更稳定。
- **引用编号源链接角标**：每段 AI 摘要末尾标注 `[#N]` 引用编号，100% 确定性地映射到原始新闻。鼠标悬停段落时右上角浮现毛玻璃胶囊角标，点击即可跳转源新闻链接。替代了原有概率性关键词匹配，准确率从不确定提升至完全可靠。
- **段落间分隔线**：不同主题之间有视觉分隔，层次清晰。
- **双语 README**：中英双语项目说明，带状态徽章、AI 提供商对比表格、搜索关键词区段，提升 GitHub 可发现性。
- **MIT 开源协议**：随附完整 LICENSE 文件。

### 🐛 Bug 修复

- 修复截断摘要（摘要可能不完整）时逐字动画首帧空白的问题
- 修复摘要无法解析时回落路径直接显示原始 `[#N]` 引用标记
- 修复鼠标悬停时多来源角标横向溢出布局
- 修复旧 `##` Markdown 缓存数据在升级为 `【】` 模板后无法解析的向后兼容问题

### 🔧 改进

- `AISummaryService.swift`: prompt 升级为 `【标题】` + `引用：[#N]` 模板框架；AI 自主挑选 3–5 个最重要话题，总字数 ≤ maxWords 硬约束
- `AISummaryCard.swift`: `parseSections` 按行扫描 `【` 和 `#` 标记，同时兼容新旧格式；`SectionRow` 改用原生 SwiftUI 控件替代 Markdown 布局
- `DashboardWindow.swift`: 消除约 90 行重复解析代码，复用共享解析函数
- `AboutTab.swift`: 新增 GitHub 链接、AI 提供商列表、项目元信息和搜索关键词
- `PopoverContent.swift`: 传入新闻条目列表以支持引用编号映射

---

## v1.3.0 — Dark Mode Fix & UI Polish

### 🐛 Bug Fixes

- **Fix dark mode appearance setting not applying**: Settings → General → Appearance → Dark/Light now correctly applies to all windows (popover, dashboard, settings).
- **Fix "Follow System" option**: Detects current macOS appearance immediately; switches in real-time without app restart.

### ✨ Improvements

- Use `NSApp.effectiveAppearance` instead of `@Environment(\.colorScheme)` for accurate system appearance detection.
- Add `AppleInterfaceThemeChangedNotification` listener for real-time system appearance changes.
- Extract `AdaptiveColorSchemeModifier` to unify dark mode across 3 views via `.adaptiveColorScheme()`.

### 🔧 Technical

- `AppSettings.swift`: Add `resolvedColorScheme: ColorScheme?` computed property mapping `"system"/"light"/"dark"` to SwiftUI enum.
- `View+Glass.swift`: Add `AdaptiveColorSchemeModifier` + `.adaptiveColorScheme()` extension.
- Branch: `feature/v1.3.0`
