# 设置页信息架构重构设计

- 日期：2026-11-24
- 状态：待评审（本文档只描述目标与步骤，尚未改代码）
- 范围：`Sources/NewsBar/Views/Settings/`、`Sources/NewsBar/Models/AppSettings.swift`、`Sources/NewsBar/Models/Localized.swift`、`Tests/NewsBarTests/SettingsWindow*`、`Tests/NewsBarTests/AISettingsRenderingTests.swift`
- 建议节奏：v3.7.0 起分四批落地（P0–P3），P4 可选

## 0. 摘要

设置窗口现有 8 个页签、约 80 个区块、约 120 个持久化属性。页签数量不是主要问题；问题在于：

1. **四个重页签平铺 9–17 个区块**：通知展开后 15+ 段、AI 17 段、隐私 11 段约 30 个按钮、微博 8 段 13 个开关。
2. **同一件事散在 2–3 个页签**：AI 用量 3 处、开机自启 2 处、学习/个性化 3 个开关、搜索设置 3 页、阅读器设置 3 页。
3. **开发者与一次性迁移 UI 与正式设置同级**：高级页 9 段里 5 段是调试；爆款测试模式还是持久化开关，忘了关会改变运行链路。
4. **11 项死设置/假开关**：其中独立 AI 配额整条链（`aiBudgetMode` + 两个日上限 + 两个计数器 + usageText）只被测试消费。

方案不改页签数量，改三件事：重页签加页内子页、跨页设置归位、开发者项收起 + 死设置删除。目标是让每个设置只有一个人人可预测的入口，并且删掉所有「改了也没用」的控件。

## 1. 设计目标

### Goals

- 每个用户可见设置只有一个主入口；快捷入口（阅读器内排版控件）保留但与主入口同源。
- 任一页签首屏不超过 6 个区块；超过则必须有页内子页。
- 开发者、诊断、一次性迁移项不再与日常设置混排。
- 删除全部零消费者设置与假开关，且不破坏已有用户的磁盘值。
- 设置窗口的既有测试（渲染、交互、本地化）继续通过，并补上新的页签断言。

### Non-goals

- 不重写 `AppSettings` 的存储模型，不引入 schema 版本号。
- 不改设置窗口的视觉皮肤（现代材质 / 复古报刊）。
- 不删阅读器内的快捷排版控件。
- 不动微博监控、RSS、AI 的功能逻辑，只动视图归属。
- 不把设置窗口改成 macOS System Settings 那种全局搜索优先的形态（P4 只加一个轻量搜索）。

### Anti-goals（做了就算失败）

- 通过合并页签把 8 个抽屉变成 4 个大杂烩。
- 搬迁时顺手改默认值或存储语义。
- 为了「整齐」删掉仍被功能读取的 legacy 开关（如 `aiDisableDeepSeekThinking`）。
- 删除属性后复用同名 UserDefaults key 给新语义。

## 2. 现状基线

### 2.1 页签负载

| 页签 | 顶层区块 | 展开后 | Toggle | Picker | Button/链接 | 主要问题 |
|---|---|---|---|---|---|---|
| 通用 | 4 | 4 | 3 | 2 | 2 | 基本健康；RSS 标题翻译不属于这里 |
| 阅读（RSS） | 10 + 6 推荐分类 | 16 | 2 | 2 | 16 | 源管理、推荐、开发者验收面板混在一起 |
| AI | 17（3 子页） | 17 | 10 | 15 | 12 | 三层结构；用量出现 3 次；研究设置塞在「功能」里 |
| 通知 | 7 | 15+ | 14 | 2 | 8 | 事件兴趣 9 段、研究自动化 6 项住在这里 |
| 微博监控 | 8 + 2 折叠 | 10 | 13 | 6 | 16 | 与通用重复开机自启；高级项与日常项混排 |
| 隐私与数据 | 11 | 11 | 7 | 4 | 约 30 | 兴趣画像与数据清理混住；4 个破坏性入口 |
| 高级 | 9 | 9 | 5 | 2 | 4 | 9 段里 5 段是调试 |
| 关于 | 5 | 5 | 0 | 0 | 1 | 内容健康；但托管了别的页的 5 个 EnvironmentKey |

### 2.2 持久化机制（三套并存）

| 机制 | 位置 | key 数 | 问题 |
|---|---|---|---|
| `AppSettings` | `Models/AppSettings.swift` | 约 120 | 主模型，`didSet` 直接写 UserDefaults，无版本号 |
| `@AppStorage` | `ResearchSettingsSection`、`ResearchAutomationSection` | 3 | 绕开模型，测试与迁移都看不到 |
| `ReaderProxyController` 自管 | `Services/ReaderProxyController.swift` | 3 | 服务私有，UI 只在高级页 |
| 迁移残留 | `AppSettings` | 3+ | `firecrawlAPIKey`、`todayBurstResearchCount`、`onePasswordRef` |
| 调试开关 | `KeychainManager` 等 | 2 | `debugDisableKeychainAccess`、`debugDisableEncryptedStore`，只在 `defaults write` 时用 |

### 2.3 重复与冲突（全量）

1. 开机自启：通用页 + 微博高级（同一个 `LaunchAtLoginRow`、同一个 `settings.launchAtLogin`，两个 label key）。
2. AI 用量：AI「用量」、高级「刷新状态」、研究「今日预算」三处；唯一的重置按钮在「今日预算」。
3. 学习/个性化：`InterestController.learningEnabled`、`researchUsePersonalization`、`newsEventInterestSettings.learningEnabled` 三个不同开关。
4. 搜索：AI「阅读器 AI 搜索」、AI「联网研究」、隐私「AI 搜索档案」三页。
5. 通知摘要：`researchNotificationShowsSummary`（假开关）与 `@AppStorage("researchNotificationDetailedPreviewEnabled")` 语义重叠。
6. 关键词：通知页「关键词监控」（新闻）与微博高级「P1 关键词通知」（博主）两套，标签相近。
7. 测试推送：高级页「发送测试推送」与「模拟爆款推送」两个入口。
8. RSS 展示数量：全局统一 Picker + 每源 Picker，同页两层。
9. 破坏性清理：隐私页 5 个入口（Cookie / 历史 / AI 档案 / 研究历史 / 缓存）。
10. 阅读器：高级（网页缩放、代理）、隐私（Cookie、历史）、微博（评论与互动）、阅读器内（排版）四处。
11. 侧栏「通知」与页头「提醒」两个名字（`settings.group.notifications` vs `settings.reminder`）。

### 2.4 死设置与假开关（全量）

| 属性 / 项 | 默认 | 证据 | 处置 |
|---|---|---|---|
| `aiPopupMaxWords` | 120 | 全仓库仅声明、初始化、白名单；无 UI、无消费者 | 删属性 + `validAIPopupMaxWords` |
| `aiMaxWords` | 150 | 同上 | 删属性 |
| `burstDailyCap` | 20 | 已并入全局 AI 配额；仅声明与初始化 | 删属性 + `validBurstCaps` |
| `aiBudgetMode` | `.shared` | 无 UI，永远 shared；唯一读者 `NewsOrchestrator.budgetBaseline` 恒为真分支 | 删，基线固定为 shared |
| `aiPopupDailyCap` | 200 | 只被 `effectiveDailyCap` 读；后者只喂死字符串 | 删 |
| `aiDashboardDailyCap` | 200 | 同上 | 删 |
| `todayPopupAIRequestCount` | 0 | 只被 `recordAIRequests(_:for:)` 写，读者是死字符串 | 删 |
| `todayDashboardAIRequestCount` | 0 | 同上 | 删 |
| `aiPopupUsageText` / `aiDashboardUsageText` | — | 全仓库零调用 | 删 |
| `effectiveDailyCap(for:)` / `todayAIRequestCount(for:)` | — | 仅被上述死代码与测试调用 | 删 |
| `recordAIRequests(_:for:)` | — | 无生产调用；测试专用 | 删，保留 `recordAIRequests(_:)` |
| `researchNotificationShowsSummary` | true | 有 UI 开关，全仓库零消费者；代码注释已写「regardless of this value」 | 删 UI + 属性 |
| `NotificationTab.swift` | — | 只有两行 import 的空壳 | 删文件 |
| `onePasswordRef` | "" | 仅作 AppDelegate legacy fallback；`loadStoredCredentialsIfNeeded()` 无调用者 | 下一版删属性与方法 |
| `firecrawlAPIKey` | "" | 单向迁移到加密存储后清空 | 保留读取，移出 UI |
| `todayBurstResearchCount` | 0 | 仅 `ResearchMaintenance` 一次性迁移 | 保留读取，移出 UI |

### 2.5 开发者与迁移 UI（现状）

| 位置 | 项 | 风险 |
|---|---|---|
| 高级 | 阅读模式自检（TextEditor + 运行） | 纯开发者诊断；URL 列表不持久化，容易被误认为设置 |
| 高级 | 爆款推送测试模式 + Topic + 两个按钮 | 持久化开关，开启时改变 `NewsOrchestrator` 运行链路 |
| 高级 | 显示全部 AI 模型 | 开发者项，无门槛 |
| 高级 | 诊断日志（复制 / 清空） | 诊断，可保留但要与其他调试项分开 |
| 高级 | 发送测试推送 | 诊断，可保留 |
| AI · 连接 | 旧版密钥绑定 | 一次性迁移补丁，条件极窄 |
| AI · 连接 | 关闭 DeepSeek 思考（legacy） | 仍驱动研究 / 分类 / 划词；不能直接删 |
| AI · 研究 | Firecrawl 旧 Key 迁移 | 隐藏迁移，仅一行 caption |
| 通知 | 事件兴趣「通用规则（兼容旧设置）」 | 显式 legacy，与新 scoped 规则并存 |
| 阅读 | 推荐验证面板（批量串行校验） | 开发者验收工具 |
| 阅读 | Agent 接口（命令行写订阅） | 开发者接口 |
| 高级 | 代理默认值 `192.168.0.14` / `nikki` / `7890` | 个人环境写死，应清空 |

### 2.6 一致性问题

- 通知 / 提醒两个名字。
- 事件兴趣表单是唯一「必须点保存」的表单；其余即时生效，用户无法预判。
- 5 个文件用硬编码 `english ? …` 而非 `L10n`：`ReaderProxySettingsSection`（25 处）、`InterestPrivacySection`（39）、`BrowserDataTab`（29）、`AdvancedTab` 自检段（8）、`RecommendationExplanation*`（约 170）。
- `AboutTab` 声明了 5 个 `EnvironmentKey`，但自己的视图一个都不用；真正的消费者在隐私 / AI / RSS。
- 旧页签残留的孤立 L10n key：`settings.developer`、`settings.developer.subtitle`、`settings.refresh`、`settings.refresh.subtitle`。
- 过期注释：`SettingsWindow.swift:3` 写「seven settings groups」但枚举有 8 个；`ResearchDataSection` 顶部仍写「关于 → 研究数据」；`weiboCommentInteractionsEnabled` 注释写「不在设置里暴露」但已经暴露。

## 3. 目标信息架构

### 3.1 侧栏

保留 8 个页签，侧栏分三段，用分隔线表达层级：

```
日常  通用 · 阅读 · 关注 · AI · 通知
数据  隐私与数据
系统  高级 · 关于
```

不做「合并成 4 个大页签」：那只会把可预测的入口变成不可预测的入口。

### 3.2 逐页定义

#### 通用（4 区块，无子页）

| 区块 | 内容 | 绑定 |
|---|---|---|
| 语言与地区 | 语言 Picker；语言重启提示 | `appLanguage` |
| 外观 | 复古主题 Toggle；主题色卡；明暗 Picker | `appTheme`、`colorScheme` |
| 启动与刷新 | 开机自启；智能定时刷新（从高级迁入） | `launchAtLogin`、`autoRefreshEnabled` |
| 更新 | 自动检查、自动下载、检查按钮、版本与状态 | Sparkle |

#### 阅读（3 子页）

| 子页 | 内容 |
|---|---|
| 订阅 | 订阅列表（勾选、拖拽排序、每源文本/图片流、每源数量、删除）、未订阅源、空态引导、添加源、订阅健康（仅异常展开）、推荐源列表（分类折叠）、导入（OPML / Google News）、导出（OPML 已选/全部、JSON）、RSS 标题翻译 |
| 展示 | 统一展示数量、文本流条数、图片流条数 |
| 阅读器 | 字号（小/标准/大/特大）、行距（紧凑/标准/宽松）、栏宽 620–760、页面主题（自动/纸张/深色）、网页缩放（适宽/实际/放大） |

说明：阅读器内的快捷控件保留，绑定同一组 `readerMode*` 值；设置页是「默认值」入口，阅读器是「临时调整」入口，两端双向一致。

#### 关注（原「微博监控」，5 区块）

| 区块 | 内容 |
|---|---|
| 账号 | 启用开关、登录状态、监控/未读计数、立即全部检查、账号列表（优先级、通知模式、启用、上次/下次、7 天条数、漏抓提示、行操作菜单）、添加账号 |
| 提醒与角标 | 系统通知、弹窗关注入口、未读角标总开关、菜单栏 / Dashboard / 弹窗三个子角标 |
| 内容过滤 | 过滤开关、过滤强度、统计行、AI 校正、优先本机 Ollama |
| 高级（默认折叠） | 自动加载评论、阅读器点赞回复、P0/P1/P2 间隔、夜间降频与时段、P1 关键词通知、单账号/全局小时上限、首次补推 |
| 诊断（默认折叠） | 最近事件、复制诊断信息 |

#### AI（4 子页）

| 子页 | 内容 |
|---|---|
| 连接 | 启用 AI 总结、提供商、API Key、1Password、模型（目录/手动 ID）、自定义提供商编辑器、旧版密钥绑定（条件渲染）、兼容（legacy DeepSeek 思考） |
| 用量与限额 | 费用说明与价目表、今日用量/花费/tokens、限制方式、金额上限与预设、次数上限、研究预算账本与「重置今日用量」 |
| 功能 | 阅读器 AI 搜索（开关/联网/页数/核验/模型）、页面概览、思考强度（概览/搜索/总结）、划词解释、共享摘要长度 |
| 研究 | 自动收录、每轮评估数、弹窗研究入口、打开标记已读、参考个性化、自动搜索日上限、研究深度、默认时间窗、每日任务上限、并发、搜索服务网格、Parallel MCP 备援 |

#### 通知（6 区块，无子页）

| 区块 | 内容 |
|---|---|
| 权限 | 授权状态、前往系统设置 |
| 定时推送 | 每小时、每日摘要、推送时间、每次条数 |
| 爆款推送 | 爆款实时推送 |
| 关键词监控 | 开关、关键词编辑器 |
| 新闻事件 | 监控与追踪、事件通知、预算卡、打开研究工作台 |
| 研究提醒 | 研究结果提醒、通知中显示已核验摘要（两个 `@AppStorage` 迁入 `AppSettings`） |

#### 隐私与数据（3 子页）

| 子页 | 内容 |
|---|---|
| 兴趣与推荐 | 本地个性化、暂停学习、隐私阅读、关注主题、推荐原理入口、已保存偏好、清空画像；「编辑事件兴趣规则…」打开 sheet |
| 浏览数据 | 记住登录 Cookie、阅读历史、AI 搜索档案，三组列表与各自清理 |
| 存储与清理 | 研究记录/缓存占用、历史保留条数与天数、缓存上限与有效期、三个清理动作 |

事件兴趣表单（9 段）从通知页移出，改成 sheet：既保留「草稿 + 保存」语义，又不再撑大任何页签。

#### 高级（3 区块）

| 区块 | 内容 |
|---|---|
| 诊断 | 刷新状态（今日刷新/AI 调用/预估花费/最后刷新）、刷新日志（复制/清空）、发送测试推送 |
| 网络 | 阅读器网络模式、Fake-IP 检测与阻止、受信任代理配置 |
| 开发者 | 「显示开发者选项」开关；开启后显示：显示全部 AI 模型、爆款测试模式与 Topic、阅读模式自检、Agent 接口、RSS 推荐验证 |

#### 关于（5 区块）

现有内容保留。5 个 `EnvironmentKey` 移到独立文件 `Settings/SettingsEnvironmentActions.swift`，不改变注入点（`AppDelegate` 仍在 SettingsWindow 根注入）。

## 4. 全量搬迁映射

### 4.1 通用

| 现区块 / 控件 | 目标 | 动作 |
|---|---|---|
| 语言 Picker | 通用 · 语言与地区 | 保留 |
| RSS 标题翻译 | 阅读 · 订阅 | 移动 |
| 开机自启 | 通用 · 启动与刷新 | 保留 |
| 更新（3 控件 + 状态） | 通用 · 更新 | 保留 |
| 复古主题 / 色卡 / 明暗 | 通用 · 外观 | 保留 |

### 4.2 阅读

| 现区块 / 控件 | 目标 | 动作 |
|---|---|---|
| 展示数量（统一 + 两条 Picker） | 阅读 · 展示 | 保留 |
| 已订阅源列表 | 阅读 · 订阅 | 保留 |
| 未订阅源 | 阅读 · 订阅 | 保留 |
| 未勾选提示 | 阅读 · 订阅 | 保留 |
| 推荐源分类列表 | 阅读 · 订阅 | 保留（分类折叠） |
| 推荐验证进度面板 | 高级 · 开发者 | 移动 |
| 添加 RSS 源 | 阅读 · 订阅 | 保留 |
| 订阅健康 | 阅读 · 订阅 | 保留（仅异常时展开） |
| 批量导入 / 导出 | 阅读 · 订阅 | 保留 |
| Agent 接口 | 高级 · 开发者 | 移动 |
| 阅读器字号 / 行距 / 栏宽 / 主题 | 阅读 · 阅读器 | 新增设置页控件（与阅读器同源） |
| 网页缩放 | 阅读 · 阅读器 | 从高级移入 |

### 4.3 AI

| 现区块 / 控件 | 目标 | 动作 |
|---|---|---|
| 启用 AI 总结 | AI · 连接 | 保留 |
| 旧版密钥绑定 | AI · 连接 | 保留（条件渲染） |
| 提供商 | AI · 连接 | 保留 |
| API Key | AI · 连接 | 保留 |
| 1Password | AI · 连接 | 保留 |
| 模型设置 | AI · 连接 | 保留 |
| 关闭 DeepSeek 思考 | AI · 连接 · 兼容 | 折叠 |
| 费用说明 / 价目表 | AI · 用量与限额 | 保留 |
| 今日用量 | AI · 用量与限额 | 保留 |
| 限额 | AI · 用量与限额 | 保留 |
| 今日预算账本 + 重置 | AI · 用量与限额 | 从「研究」移入 |
| 阅读器 AI 搜索（5 项） | AI · 功能 | 保留 |
| 页面概览 | AI · 功能 | 保留 |
| 思考强度（3 项） | AI · 功能 | 保留 |
| 划词解释 | AI · 功能 | 保留 |
| 共享摘要长度 | AI · 功能 | 保留 |
| 隐私说明 | AI · 连接 footer | 保留为静态说明 |
| 联网研究（6 项） | AI · 研究 | 保留 |
| 搜索服务网格 + Parallel | AI · 研究 | 保留 |

### 4.4 通知（原「提醒」）

| 现区块 / 控件 | 目标 | 动作 |
|---|---|---|
| 权限状态 | 通知 · 权限 | 保留 |
| 定时推送（4 项） | 通知 · 定时推送 | 保留 |
| 爆款推送 | 通知 · 爆款推送 | 保留 |
| 关键词监控 | 通知 · 关键词监控 | 保留 |
| 新闻事件（监控 / 通知 / 预算） | 通知 · 新闻事件 | 保留 |
| 研究自动化（5 项） | AI · 研究 | 移动 |
| 研究通知两个 `@AppStorage` | 通知 · 研究提醒 | 移动并迁入 AppSettings（P3） |
| 通知摘要开关（假开关） | — | 删除 |
| 事件兴趣规则（9 段） | 隐私 · 兴趣与推荐（sheet） | 移动 |

### 4.5 关注（原「微博监控」）

| 现区块 / 控件 | 目标 | 动作 |
|---|---|---|
| 启用 / 登录状态 / 计数 / 立即检查 | 关注 · 账号 | 保留 |
| 登录失效等 banner | 关注 · 账号 | 保留 |
| 账号列表 | 关注 · 账号 | 保留 |
| 添加账号 | 关注 · 账号 | 保留 |
| 关注提醒（6 个 Toggle） | 关注 · 提醒与角标 | 保留 |
| 内容过滤（4 项 + 统计） | 关注 · 内容过滤 | 保留 |
| 高级（评论 / 间隔 / 夜间 / 关键词 / 上限 / 补推） | 关注 · 高级 | 保留（折叠） |
| 开机自启 | — | 删除（通用已有） |
| 最近事件 + 复制诊断 | 关注 · 诊断 | 移入独立折叠 |

### 4.6 隐私与数据

| 现区块 / 控件 | 目标 | 动作 |
|---|---|---|
| 本地个性化 / 暂停 / 隐私阅读 / 关注主题 / 推荐原理 / 已保存偏好 / 清空画像 | 隐私 · 兴趣与推荐 | 保留 |
| 事件兴趣规则（来自通知） | 隐私 · 兴趣与推荐（sheet） | 移入 |
| 记住 Cookie / 阅读历史 / AI 搜索档案 | 隐私 · 浏览数据 | 保留 |
| Cookie 列表与清理 | 隐私 · 浏览数据 | 保留 |
| 历史列表与清理 | 隐私 · 浏览数据 | 保留 |
| AI 档案计数与清空 | 隐私 · 浏览数据 | 保留 |
| 存储占用 / 历史保留 / 缓存 / 清理 | 隐私 · 存储与清理 | 保留 |

### 4.7 高级

| 现区块 / 控件 | 目标 | 动作 |
|---|---|---|
| 智能定时刷新 | 通用 · 启动与刷新 | 移动 |
| 刷新状态 | 高级 · 诊断 | 保留 |
| 刷新日志 | 高级 · 诊断 | 保留 |
| 阅读器代理（含 Fake-IP） | 高级 · 网络 | 保留 |
| 网页缩放 | 阅读 · 阅读器 | 移动 |
| 发送测试推送 | 高级 · 诊断 | 保留 |
| 显示全部 AI 模型 | 高级 · 开发者 | 收纳 |
| 爆款测试模式 | 高级 · 开发者 | 收纳 + 开启时警示 |
| 阅读模式自检 | 高级 · 开发者 | 收纳 |
| Agent 接口（来自阅读） | 高级 · 开发者 | 移入 |
| 推荐验证（来自阅读） | 高级 · 开发者 | 移入 |

### 4.8 关于

| 项 | 目标 | 动作 |
|---|---|---|
| 5 个区块 | 关于 | 保留 |
| 5 个 `EnvironmentKey` | `SettingsEnvironmentActions.swift` | 迁出（无行为变化） |

## 5. 交互与文案规范

### 5.1 页内子页

复用 `AITab` 的 `EditorialChips` 分页器，放到通知 / 隐私 / 关注 / 阅读。子页切换不重建父视图，保留各子页的 `@State`；子页 id 要能通过 `.id(pane)` 记录到渲染快照，便于测试。

### 5.2 保存语义

- 除事件兴趣表单外，全部即时生效。
- 事件兴趣表单保持「草稿 + 保存」，但必须：标题旁显示「未保存」徽章；切换页签 / 关闭窗口时确认；保存成功后清掉徽章。
- 事件兴趣表单从页内 Section 改成 sheet 后，`@State` 生命周期跟随 sheet，每次打开都从当前 `newsEventInterestSettings` 重新建 draft。

### 5.3 危险操作

- 隐私页的 5 个破坏性入口按「对象」分组到三个子页，每组最多一个「清除全部」按钮，且都需要二次确认。
- 删除 RSS 源、删除账号、清空研究历史、清空缓存保持现有确认文案，不改语义。

### 5.4 开发者开关

- 新增 `showDeveloperSettings: Bool`，默认 `false`。
- 开关放在「高级 · 开发者」区块内，始终可见；关闭时该区块只显示开关与一句说明。
- 开启后显示：显示全部 AI 模型、爆款测试模式、阅读模式自检、Agent 接口、RSS 推荐验证。
- 爆款测试模式开启时，在高级页顶部显示常驻警告条（不是一次性提示），避免忘记关闭。

### 5.5 空态与条件渲染

搬迁时必须保留原条件：

- 更新区块仅在 `updater != nil` 时渲染。
- 旧版密钥绑定仅在自定义提供商且 `keyStatus == .unbound` 时渲染。
- 思考强度按 provider 能力在 Picker / 文本之间切换。
- 限额方式仅在 `aiCostEstimateAvailable` 时出现。
- 通知开关在未授权时禁用。
- 微博整页在 `monitor == nil` 时显示占位符。
- RSS 推荐验证仅在开发者模式且推荐列表打开时出现。

### 5.6 命名统一

| 现状 | 目标 |
|---|---|
| 侧栏「通知」/ 页头「提醒」 | 统一「通知」 |
| 侧栏「阅读」/ 页头「RSS 新闻源」 | 统一「阅读」 |
| 「微博监控」 | 「关注」 |
| `settings.developer` 等孤立 key | 删除 |
| 「通用 / 外观 / 主题设置」 | 统一「通用 / 外观」 |

### 5.7 i18n

- 新增文案一律走 `L10n`，禁止新增 `english ? …` 三元式。
- P3 分批把 5 个文件的硬编码文案迁到 `Localized.swift`；迁移时保持中英文案逐字一致，只换存取方式。
- `SettingsWindowLayoutTests.testEveryPaneAndAIPageIsLocalized` 扩展为同时检查新增子页标题。

## 6. 实施计划

### P0 — 清死（0.5 天）

改动：

1. `AppSettings`：删 `aiPopupMaxWords`、`aiMaxWords`、`burstDailyCap`、`researchNotificationShowsSummary` 及对应初始化、白名单。
2. `ResearchAutomationSection`：删「通知中显示一句话摘要」Toggle。
3. 删除 `Views/Settings/NotificationTab.swift`。
4. `WeiboMonitorTab`：删高级里的 `LaunchAtLoginRow`。
5. `ReaderProxySettingsSection`：清空 `host` / `port` / `username` 的个人默认值。
6. 修 4 处过期注释（7 groups、ResearchDataSection 位置、weiboCommentInteractions、AboutTab 环境键说明）。

验收：

- `swift test --filter SettingsWindowLayoutTests` 通过。
- `swift test` 全绿。
- 设置窗口可见变化仅：研究自动化少一个开关、微博高级少一行开机自启。

### P1 — 分层与搬迁（1–2 天）

改动：

1. `ReminderTab.swift` 重命名为 `NotificationTab.swift`，内部改 6 区块。
2. `PrivacyTab` 加 3 子页；事件兴趣表单改为 sheet（新增 `EventInterestRulesSheet`）。
3. `WeiboMonitorTab` 改名 `FollowingTab`（类型可保留 `WeiboMonitorTab`，只改导航名与文件注释，降低风险）。
4. `AITab` 增加第 4 个子页「研究」；`ResearchLedgerView` 移入「用量与限额」。
5. 新增 `ReaderTypographySection`，绑定 `readerMode*` 四项 + 网页缩放。
6. 新增 `ResearchNotificationSettingsSection`，承接两个 `@AppStorage`。
7. `AdvancedTab` 拆出「诊断 / 网络 / 开发者」三块（开发者先只放开关，工具 P2 再搬）。
8. 删除 AI 独立配额链（`aiBudgetMode` 等 11 项），同步简化 `AISummaryService` 与 `NewsOrchestrator.budgetBaseline`。
9. 更新 `SettingsPane` 文案与 `L10n`；删除孤立 key。

验收：

- 8 个页签全部可渲染；通知页首屏 ≤ 6 区块；AI 4 个子页可切换。
- `SettingsWindowLayoutTests`、`SettingsWindowInteractionTests`、`AISettingsRenderingTests` 通过。
- 删除配额链后 `AISummaryTests` 更新并通过。
- 手动走查：每个原设置都能在新位置找到，条件渲染不丢。

### P2 — 开发者收纳（1 天）

改动：

1. `AppSettings` 新增 `showDeveloperSettings`（默认 false）。
2. `AdvancedTab` 开发者区块：开关 + 工具列表。
3. 搬入：显示全部 AI 模型、爆款测试模式、阅读模式自检、Agent 接口、RSS 推荐验证。
4. 爆款测试模式开启时显示常驻警示条。

验收：

- 默认关闭时，「高级」只有诊断、网络、开发者开关三块。
- 开启后工具全部可用；关闭不改变任何运行状态（除测试模式本身的值）。
- 全量 `swift test` 通过。

### P3 — 一致性（2–3 天）

改动：

1. 3 个 `@AppStorage` 改为 `AppSettings` 属性，沿用原 key，无需迁移脚本。
2. 5 个文件的硬编码 i18n 迁到 `L10n`（可分 5 个提交）。
3. `AboutTab` 的 5 个 `EnvironmentKey` 迁到 `SettingsEnvironmentActions.swift`。
4. `weiboMonitorRelevanceModeRaw` 的存储 key 迁移：读旧 key → 写新 key → 旧 key 保留一版只读。
5. 删除 `onePasswordRef` 与 `loadStoredCredentialsIfNeeded()`（确认无调用后）。

验收：

- 中英文切换后，原来硬编码的 5 个页面文案完整。
- 设置读写测试覆盖 3 个迁入属性。
- 全量 `swift test` 通过。

### P4 — 可选：设置搜索

- 侧栏顶部搜索框，索引「页签 + 子页 + 区块标题 + 关键词」。
- 选中结果后跳转到对应页签/子页，并用 `ScrollViewReader` 滚动到区块、短暂高亮。
- 工作量约 1–2 天；不阻塞 P0–P3。

## 7. 风险与回滚

| 风险 | 影响 | 缓解 |
|---|---|---|
| 搬迁丢失条件渲染 | 某些设置在不该出现时出现，或反之 | 每个 Section 搬迁时保留原 `if`；渲染快照逐页对比 |
| 事件兴趣 sheet 拿不到 Environment | 保存/重算失败 | sheet 继承 presenter 环境；补一个渲染测试 |
| 删除配额链改动服务签名 | AI 限额行为回归 | 单独提交；先删属性再改签名；跑 `AISummaryTests` |
| 删除 UserDefaults 属性 | 旧值残留 | 只删读取，不复用同名 key；文档记录 |
| `@AppStorage` 迁入 AppSettings | 值丢失 | 沿用原 key；不新增 key |
| 阅读器排版双入口漂移 | 两处值不一致 | 两端都绑 `AppSettings`；不引入本地副本 |
| 页签重命名影响通知路由 | `.switchToReminder` 失效 | `SettingsPane` rawValue 保持不变，只改显示名 |
| 测试断言 8 个页签 | 改名/增页失败 | 同步更新 `SettingsWindowLayoutTests` 的计数与本地化断言 |

回滚：P0–P2 都是视图与属性级改动，按阶段独立提交；任一步失败可单独 revert，不影响存储数据。

## 8. 未决问题

1. 「关于」是否保留独立页签？建议保留（侧栏底部独立）。
2. 事件兴趣规则用 sheet 还是独立子页？建议 sheet（保留草稿语义，不撑大页签）。
3. 研究通知放「通知」还是「AI · 研究」？建议放「通知 · 研究提醒」，按「投递渠道」归类。
4. 开发者开关是否常显？建议常显在高级底部，避免隐藏入口不可发现。
5. 设置搜索是否本期做？建议 P4，可选。

## 9. 附录：新增 / 删除 / 迁移一览

### 新增

- `showDeveloperSettings`（Bool，默认 false）
- `ReaderTypographySection`（视图）
- `ResearchNotificationSettingsSection`（视图）
- `EventInterestRulesSheet`（视图）
- `SettingsEnvironmentActions.swift`（EnvironmentKey 声明）
- 4 个新子页标题 L10n key（阅读 / 关注 / AI / 隐私）

### 删除

- 属性：`aiPopupMaxWords`、`aiMaxWords`、`burstDailyCap`、`researchNotificationShowsSummary`、`aiBudgetMode`、`aiPopupDailyCap`、`aiDashboardDailyCap`、`todayPopupAIRequestCount`、`todayDashboardAIRequestCount`
- 计算属性 / 方法：`aiPopupUsageText`、`aiDashboardUsageText`、`effectiveDailyCap(for:)`、`todayAIRequestCount(for:)`、`recordAIRequests(_:for:)`
- 类型：`AISummaryBudgetMode`
- 文件：`NotificationTab.swift`（空壳）
- UI：研究自动化里的摘要 Toggle、微博高级里的开机自启行
- L10n：`settings.developer`、`settings.developer.subtitle`、`settings.refresh`、`settings.refresh.subtitle`

### 迁移

- `researchNotificationsEnabled`、`researchNotificationDetailedPreviewEnabled`、`researchReadingEnabled`：`@AppStorage` → `AppSettings`（同 key，P1 第一步执行）
- 事件兴趣 9 段：通知 → 隐私 · 兴趣与推荐（sheet）
- 研究自动化 5 项：通知 → AI · 研究
- 今日预算：AI · 研究 → AI · 用量与限额
- 阅读器排版 4 项 + 网页缩放：阅读器内 / 高级 → 阅读 · 阅读器
- RSS 标题翻译：通用 → 阅读 · 订阅
- 智能定时刷新：高级 → 通用 · 启动与刷新
- Agent 接口、推荐验证、调试工具：阅读 / 高级 → 高级 · 开发者
- `AboutTab` 的 5 个 EnvironmentKey → `SettingsEnvironmentActions.swift`

## 10. 复核后的修订（2026-11-24）

双审结论已并入执行，以下条款优先于前文冲突处：

1. 侧栏保持平铺 8 行，不做三段分组与分组标题。UX：分组只增加噪声（「数据」仅 1 项）；技术：新增行会破坏 `SettingsWindowInteractionTests` 依赖的 NSTableView 行号。
2. 页内子页只给阅读（订阅/展示/阅读器）、AI（连接/用量与限额/功能/研究）、隐私（兴趣与推荐/浏览数据/存储与清理）。通用/通知/关注/高级/关于保持单页滚动。
3. 子页切换不用 `EditorialChips`（与动作按钮同款，语义混淆），改为下划线页签条：选中项主色文字 + 2pt 底线，整组 tab 语义，⌘1…⌘n；所有页签保留同高条目，避免切换时首屏基线跳动。
4. 事件兴趣规则从「通知 · 新闻事件」底部的一行摘要入口打开 sheet，不放入隐私页（避免与「清空画像」混淆，两者是不同引擎）。sheet 固定底部「取消 / 保存」，9 段折叠为 5 个可见块，未变更时保存禁用。
5. 阅读：新增「添加源」sheet（含推荐分类）；订阅页只留已订阅/未订阅/健康/导入导出/标题翻译。推荐验证面板留在阅读页，用开发者开关隐藏，不搬到高级（其状态与取消逻辑属于 RSSTab，搬走会断）。
6. AI 子页为连接/用量与限额/功能/研究：新增 `features` 承载 AI 搜索、概览、思考、划词、摘要长度；`research` 承载联网研究与自动收录。`ResearchLedgerView` 先从 `ResearchSettingsSection` 抽出，再移入用量页。
7. 不删除 `AISummaryBudgetMode` 类型与 `mode:` 形参（6 个测试文件 110 处引用）；只删 `AppSettings` 侧配额属性、死字符串与 `NewsOrchestrator.budgetBaseline`。
8. 三个 `@AppStorage` 迁入 `AppSettings` 提前到 P1 第一步；`QuickSearchContent` 显式注入 `AppSettings`。key 不变，无需迁移。
9. 阅读器外观：承认只有一份持久偏好，设置页命名「阅读器外观」并注明「与阅读器内 Aa 菜单同步」；字号/行距/栏宽/主题沿用阅读器现有档位，不新增第二套口径。
10. 开发者工具放 `DisclosureGroup`（默认收起）；爆款测试模式开启时，masthead 的「设置」徽章换成橙色「测试模式」全局可见。
11. 退出按钮从共享页脚移到「关于」；页脚不再常驻红色破坏性按钮。
12. 高级·诊断只留刷新次数、最后刷新、日志、测试推送；AI 调用与花费从诊断移除，避免与 AI 用量重复。
13. 8 条页签副标题重写为内容清单，作为最便宜的可发现性杠杆。
14. 取消 P4 设置搜索：13 个目的地且标签与用户口语差距大，搜索会掩盖 IA 问题；预算转投密度、副标题与跨页互链。
15. `onePasswordRef` 保留（`AppDelegate` legacy fallback 仍在读），本期只移出 UI。
16. `ReminderTab` 类型名与文件名保留，只改 UI 文案与结构，避免测试构造点改动。
17. `ReminderTab` 里的第 6 个 `EnvironmentKey`（通知授权状态）与 AboutTab 的 5 个一并迁出。
18. 密度验收：首屏可交互行 ≤ 8，单 Section 交互行 ≤ 5；不按 Section 计数。

## 11. 实施状态（2026-11-24）

- 分支：`feat/settings-ia-refactor`
- 工作树：`news-bar-settings-ia`
- 状态：已实施，未提交

### 已落地

- **P0**：删除 `aiPopupMaxWords`、`aiMaxWords`、`burstDailyCap`、`researchNotificationShowsSummary`；删除空壳 `NotificationTab.swift`；删除微博高级里重复的开机自启；清空代理个人默认值；修 4 处过期注释；删 2 个孤立 L10n key。
- **P1**：8 个页签保留；阅读（订阅/展示/阅读器）、AI（连接/用量与限额/功能/研究）、隐私（兴趣与推荐/浏览数据/存储与清理）加页内页签；通知页重排为 7 块；事件兴趣规则改为「通知 · 新闻事件」入口 + sheet，保存栏固定在底部；「微博监控」更名「关注」；高级拆为诊断/网络/开发者；阅读器外观迁入阅读；三个 `@AppStorage` 迁入 `AppSettings`；今日预算移入 AI 用量页；退出按钮移到关于。
- **P2**：新增 `showDeveloperSettings`（默认关闭）；显示全部模型、爆款测试、阅读模式自检、Agent 接口收进高级 · 开发者；RSS 推荐验证仅在开发者模式显示；爆款测试开启时 masthead 显示橙色「测试模式」。
- **P3**：6 个 `EnvironmentKey` 迁到 `SettingsEnvironmentActions.swift`；`AppTheme` 名称按语言本地化；清理过期状态页脚与孤立 key。
- **P1.4**：删除 AI 独立配额链（`aiBudgetMode`、`aiPopupDailyCap`、`aiDashboardDailyCap`、两个 per-target 计数器、`aiPopupUsageText`/`aiDashboardUsageText`、`effectiveDailyCap`、`todayAIRequestCount(for:)`、`recordAIRequests(_:for:)`、`NewsOrchestrator.budgetBaseline`）及对应测试；保留 `AISummaryBudgetMode` 类型与 `mode:` 形参（服务层与 6 个测试文件仍在使用）。

### 偏差（有意为之）

- **i18n 存量未批量迁移**：`ReaderProxySettingsSection`（25）、`InterestPrivacySection`（39）、`BrowserDataTab`（29）、`AdvancedTab` 自检段（8）、`RecommendationExplanation*`（约 170）仍使用 `english ? …` 三元式。这些文案已经按语言正确切换，迁移只改代码组织，不改用户可见结果；为避免 280 处机械改动引入格式串风险，留作后续独立提交。
- **RSS「添加源」仍是页内表单**：订阅页已从 12+ 块降到可接受密度；抽 sheet 需要搬迁校验状态与错误处理，风险高于收益，留作后续密度优化。
- **`onePasswordRef` 保留**：`AppDelegate` 的 legacy fallback 仍在读取，只移出 UI，不做删除。
- **P4 设置搜索取消**：13 个目的地且标签与用户口语差距大，搜索会掩盖 IA 问题；预算转投副标题、密度与跨页互链。
- **`AISummaryBudgetMode` 类型保留**：删除它需要改 110 处服务调用与测试签名，收益仅是删一个枚举；本期只删 AppSettings 侧的无效状态。

### 验证

- `swift build`：通过。
- `swift test --filter SettingsWindowLayoutTests`：4/4 通过（8 个页签 + 4 个 AI 子页全部渲染）。
- 全量 `swift test`（配额链删除前）：2047 通过 / 6 跳过 / 0 失败。
- 配额链删除后：`swift build` 通过；全量 `swift test` 2029 通过 / 6 跳过 / 0 失败（EXIT 0）。

## 12. RSS 首次使用优化（2026-11-24）

### 现状

- `showRecommendations` 默认 `false`：空源只看到 3 个起步推荐 + 「查看全部 22 个推荐源」。
- 自定义添加表单在页面底部，首次使用要滚过整页；`isAdding` 是未使用状态。

### 方案

- **空态默认展开**：`@AppStorage("rss.recommendations.state")` 三态 `auto / expanded / collapsed`。`auto` 仅在无源时展开；用户手动收起后保持；首次添加源后保持展开，避免刚加完一个就收起目录。用 `AppStorage` 而不是 `SceneStorage`：设置窗口是 AppKit 托管的 `NSHostingView`，没有 SwiftUI Scene。
- **顶部自定义入口**：`RSSOnboardingCard` 在标题下增加 `[添加自定义源…]`（主按钮）+ `[导入 OPML…]`；空态和非空态都能在首屏找到添加动作。
- **添加源 sheet**：`AddRSSSourceSheet` 自持名称/URL、重复检查、安全校验、异步 `RSSService.validate`、错误/警告、固定底部 `取消 / 添加并验证`、Enter 提交、Esc 取消、打开即聚焦名称。非阻塞安全警告改为二次确认「仍然添加」，避免警告一闪而过。
- **订阅页收敛**：删除底部内联表单；非空态标题栏固定 `[添加源…]` + `[推荐/收起]`；推荐源的错误/警告在列表下方显示。
- **安全文案共享**：`RSSSecurityCopy` 统一映射 `SecurityPolicies` 的英文 reason，添加 sheet 与推荐路径使用同一份本地化文案。
- **分类标签**：起步推荐的分类标签改用 `category.title(language:)`，英文界面不再出现中文分类。

### 状态规则

| 场景 | 推荐目录 | 自定义入口 |
|---|---|---|
| 空源 · 首次进入 | 展开 | 卡片顶部主按钮 |
| 空源 · 用户收起 | 收起 | 卡片顶部主按钮 |
| 有源 · 首次进入 | 收起 | 订阅区标题栏 |
| 有源 · 用户展开 | 展开 | 订阅区标题栏 |
| 首次添加后 | 保持展开 | 订阅区标题栏 |

### 验证

- `RSSFirstRunTests`：2/2 通过（auto 仅空源展开；显式状态优先）。
- `SettingsWindowLayoutTests`：6/6 通过，新增 `rss-add-source-sheet.png` 与 `rss-with-source.png` 两张快照。
- 空态快照确认：推荐目录默认展开，[添加自定义源…] 在首屏。
- 非空态快照确认：标题栏 [添加源…] + [推荐列表]，底部无内联表单。
- 全量 `swift test`：2033 通过 / 6 跳过 / 0 失败（EXIT 0）。
- `git diff --check`：无空白错误。

### 执行后复核修复

- `@SceneStorage` → `@AppStorage(..., store: TestIsolation.defaults)`：设置窗口由 AppKit `NSHostingView` 托管，没有 SwiftUI Scene。
- sheet 关闭时取消在途验证：`validationTask?.cancel()` + `Task.isCancelled` 守卫，取消不会把源偷偷加进去。
- 推荐源反馈从页尾移到订阅卡下方：错误/警告在触发点附近可见。
- `submit()` 增加 `canSubmit` 守卫：回车不会绕过禁用状态添加空名称源。
- 两个输入框补 `accessibilityLabel`。
