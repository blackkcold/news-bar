# NewsBar — Project Bootstrap

## Overview

macOS 菜单栏即时新闻聚合器。状态栏图标点击弹出 Popover，展示微博/B站热搜 + RSS 源 + AI 总结。

**当前开发分支**: `feature/v1.5.0` · **最新发版**: v1.5.0

## Architecture

```
Sources/NewsBar/
├── main.swift              # 入口：单实例检测 → NSApp 启动
├── AppDelegate.swift        # 生命周期：statusItem、popover、延迟 keychain 读取、通知监听、通知权限请求
├── Models/
│   ├── AIProvider.swift       # 多 AI 提供商枚举（6 providers）
│   ├── NewsItem.swift       # 新闻条目模型 (Identifiable, Codable, + imageURL Optional)
│   ├── NewsSource.swift     # 数据源枚举 (weibo/bilibili/rss)
│   ├── AppSettings.swift    # @Observable 全局设置 (UserDefaults 持久化 + resolvedColorScheme + cachedAPIKey + 通知设置 5 字段)
│   ├── CacheEntry.swift     # 缓存条目 (items + hash + timestamp)
│   └── UpdateInfo.swift     # GitHub Release 模型 + 版本比对
├── Services/
│   ├── NewsOrchestrator.swift  # 核心调度器：刷新、缓存、每源加载状态、AI 总结状态机、batchProgress、差异化刷新、通知触发
│   ├── UpdateChecker.swift     # 更新检查：GitHub API → 版本比对 → DMG 下载
│   ├── WeiboHotService.swift   # 微博热搜 (多级策略: ajax/side/hotSearch → s.weibo.com 降级)
│   ├── BilibiliHotService.swift # B站热搜 (bilibili.com API)
│   ├── RSSService.swift        # RSS/Atom Feed 解析 (XMLParser + enclosure/media namespace 图片解析 + 10s 超时)
│   ├── RSSRecommendations.swift # RSS 推荐源 (6 分类 25 源)
│   ├── AISummaryService.swift   # AI 总结（多提供商：OpenAI/Anthropic 格式分发）
│   ├── OnePasswordService.swift # 1Password CLI 集成 (op read)
│   ├── KeychainManager.swift   # 已废弃 — 仅保留用于一次性迁移读取旧 Keychain 数据
│   ├── EncryptedKeyStore.swift  # AES-256-GCM 加密文件存储（替代 Keychain，actor 隔离，机器绑定，无弹窗）
│   ├── CacheManager.swift      # actor 隔离的文件缓存
│   ├── ImageCache.swift        # actor 隔离 NSCache + ephemeral URLSession (图片缓存，不共享 cookie)
│   ├── NotificationService.swift # macOS 通知推送 (每小时 + 每日 UNCalendarNotificationTrigger)
│   ├── RefreshLog.swift         # actor 环形缓冲刷新日志 (最近 10 次，可选落盘)
│   ├── RateLimiter.swift        # actor 隔离的手动刷新频率控制
│   └── SecurityPolicies.swift   # 输入消毒、URL 校验、XML 安全配置、extractFirstImageURL (SSRF 防护)
├── Views/
│   ├── MenuBar/
│   │   ├── PopoverContent.swift  # 主弹窗：Header + AI 状态卡 + 新闻列表 + BottomBar (400px 宽)
│   │   ├── NewsSection.swift     # 新闻区段 (微博/B站用，padding 14)
│   │   ├── NewsItemRow.swift     # 单条新闻行
│   │   ├── RSSWaterfallView.swift # RSS 双模式视图 (文本流 LazyVStack + 图片流 LazyVGrid) + 源级自动降级(会话锁存) + 分页加载(每批4条) + sticky 折叠条
│   │   ├── AISummaryCard.swift   # AI 总结卡片（状态驱动 + 逐字动画 + 模板框架 + [#N] 引用编号）
│   │   ├── UpdateBadge.swift     # 更新状态按钮（检查→下载→打开，7 态胶囊按钮）
│   │   └── BottomBar.swift       # 底部工具栏 (+ batchProgress 进度显示)
│   ├── Dashboard/
│   │   └── DashboardWindow.swift # 独立 Dashboard 窗口（同步 AI 状态，RSS 用 RSSWaterfallView）
│   └── Settings/
│       ├── SettingsWindow.swift   # 设置窗口 (TabView 5 标签：通用/RSS/AI/通知/关于)
│       ├── GeneralTab.swift       # 通用设置
│       ├── RSSTab.swift           # RSS 源管理 (无上限 + 分类分段推荐)
│       ├── AITab.swift            # AI 配置 + 1Password
│       ├── NotificationTab.swift  # 通知设置 (每小时/每日推送 + 权限状态)
│       └── AboutTab.swift         # 关于
└── Extensions/
    ├── URLOpener.swift    # URL 安全打开
    └── View+Glass.swift   # 毛玻璃 UI 修饰符 + AdaptiveColorSchemeModifier
```

## Build & Run

```bash
# Debug
swift build && swift run

# Release (app bundle + DMG)
scripts/build.sh

# Version bump + git tag
scripts/bump-version.sh           # 1.0.1 → 1.0.2
scripts/bump-version.sh 2.0.0     # 指定版本

# GitHub Release (after build)
scripts/release.sh                # 自动生成 release notes + 创建 GitHub Release
```

Output: `release/{version}/NewsBar.app` + `NewsBar-{version}.dmg`

## Key Patterns

### Data Flow
```
App 启动
  → EncryptedKeyStore.migrateFromKeychainIfNeeded() — 从 Keychain 迁移到加密文件（一次性，崩溃安全）
  → AppSettings 初始化（从加密文件异步加载 onePasswordRef）
  → statusItem / popover 就绪
  → loadAPIKeyFromFile() — 异步从加密文件读取 API Key（无弹窗、无延迟）
  → 若没有 key 且 AI 已开启 → NSAlert 提示前往设置；"稍后再说" 后不再提示
  → 2s 自动刷新 NewsOrchestrator.refreshIfNeeded() → 每源 SourceLoadState 标记 loading/loaded/failed；无 cachedAPIKey 时 AI 状态为 .noKey（后台）
  → 10s 自动更新检查 UpdateChecker.autoCheck() → GitHub API → 有新版则 UpdateBadge 显示「更新」按钮
  → User opens popover → loadAPIKeyFromKeychainIfNeeded() → check flag || 兜底 checkAPIKeyExistence() → readAPIKey(allowUI:false) 静默读 Keychain secret（系统授权弹窗仅在用户 AITab 中主动保存 Key 时出现）
  → 读 key 成功 → 写 cachedAPIKey → manualRefresh() 抓取所有源 → AI 总结
  → AISummaryService.summarize(provider:) → 首次 max_tokens=1024 → 若截断则 max_tokens=2048 重试 1 次
  → AI 总结成功后才写 lastBatchHash，并按实际请求次数计入今日 AI 调用；idle/noKey/error/fetching 可触发恢复总结；manualRefresh 强制总结
   → 结果通过 AISummaryState 驱动 UI：noKey / fetching / summarizing / done / truncated / error
   → 结果文本首次渲染直接显示（.onAppear），状态转变时逐字动画（.onChange(of:)）
   → 动画完成后按「【标题】」模板拆分 section，通过 [#N] 引用编号确定性映射到 NewsItem
   → 标题用原生 .bold() 渲染，正文用 AttributedString(markdown:) 仅处理内联加粗
  → 若 autoRefreshEnabled，Timer(3600s) 定时刷新
User opens popover
  → PopoverContent.task { loadCached(settings) } 显示缓存数据（内存优先：若内存已有数据则跳过加载）
  → 缓存过期 >15min 且内存空时状态为 idle/暂无数据；刷新失败时按源显示"加载失败"或"更新失败，显示缓存"
  → SwiftUI 自动刷新 UI
User clicks 重新生成
  → PopoverContent → NewsOrchestrator.regenerateAISummary(settings) → 重新总结
```

### Adding a New Data Source
1. `NewsSource.swift` — 添加新 case
2. `Services/XxxService.swift` — 实现 `fetch() async throws -> [NewsItem]`
3. `NewsOrchestrator.swift` — 在 `refreshIfNeeded()` / `manualRefresh()` 中调用
4. `PopoverContent.swift` + `DashboardWindow.swift` — 添加 `NewsSection`

### Adding a Setting
1. `AppSettings.swift` — 添加 `@Observable` 属性
2. 敏感数据用 `EncryptedKeyStore` 存储（参考 `apiKey` / `onePasswordRef` 模式）
3. 非敏感数据用 `UserDefaults` 持久化（didSet 自动同步）
4. `Views/Settings/XxxTab.swift` — 添加 UI 绑定
5. 如需全局生效（如外观设置），通过 `.adaptiveColorScheme()` 修饰符应用到所有窗口根部 (SettingsWindow / PopoverContent / DashboardWindow)

### Security Rules
- **API Key**: EncryptedKeyStore 加密文件存储（AES-256-GCM + HKDF-SHA256 密钥派生，绑定 IOPlatformUUID；文件权限 0600，Time Machine 排除；actor 隔离保证线程安全；原子写入 temp→F_fullFSYNC→rename→verify）；每个 AI Provider 独立 account (`"ai-key-{provider}"`)；旧 Keychain 数据首次启动自动迁移（逐 item 原子策略，崩溃安全）；`AppSettings.cachedAPIKey` 内存缓存，切换 provider 时自动清除；1Password ref 共用 `"one-password-ref"` account，不受 provider 切换影响；UI 不在渲染期间读文件（`cachedAPIKey` 已在上次保存时设置）
- **AI 总结**: `AISummaryState` 驱动 UI；`finish_reason="length"` 截断时自动重试 1 次（扩大 max_tokens），仍截断则 UI 提示并显示「重新生成」按钮；`lastBatchHash` 仅在总结成功后更新，避免无 key/失败污染 hash；手动刷新强制总结，自动刷新在 idle/noKey/error/fetching 时允许恢复；AISummaryCard 用 `.onAppear` 直接显示已有文本，`.onChange(of:)` 触发逐字动画
- **1Password**: `op read` 通过 `Process` 调用（数组传参，非 shell 拼接，无注入风险）；`onePasswordRef` 存储在 Keychain（`account: "one-password-ref"`），首次启动自动从 UserDefaults 迁移
- **更新检查**: 仅访问 GitHub 公开 API（`api.github.com/repos/blackkcold/news-bar/releases/latest`），无认证；DMG 下载到 `~/Library/Caches/<bundleID>/Updates/`，下载后校验文件大小，不自动挂载或执行
- **URL 打开**: 必须通过 `SecurityPolicies.validateURL()` 校验 (HTTPS only)
- **用户输入**: 必须通过 `SecurityPolicies.sanitizeUserInput()` 处理（移除控制字符 + `.whitespacesAndNewlines` 防 copy-paste 换行符污染）
- **XML 解析**: 必须设置 `shouldResolveExternalEntities = false`
- **RSS 图片**: `extractFirstImageURL` 独立函数（不修改 `forbiddenTags`，保留 `img` 在安全策略中）；URL 经 `validateRSSURL` 校验（SSRF 防护，杜绝内网 IP）；`ImageCache` 用 `ephemeral URLSession`（不共享 cookie，防止认证信息泄露）
- **通知内容**: 所有通知 body 经 `sanitizeHTMLContent` 净化；每小时推送在 `doRefresh` 后触发（内容实时）；每日推送通过 `rescheduleDailyPush` 在每次刷新后更新 pending 内容

### Refresh State / Rate Limiting
- 自动刷新：启动时 2s 延迟执行一次 + 可选每小时定时刷新；`refreshIfNeeded` 与 `manualRefresh` 都会统一计入今日刷新次数
- 每源状态：`SourceLoadState.idle/loading/loaded/failed` 驱动 `NewsSection`，避免失败或超时后继续显示"加载中"
- 手动刷新：每小时连续手动刷新 3 次触发警告
- AI 用量：仅成功 AI 总结按实际请求次数计入今日 AI 调用；设置页显示本地预估花费（微博/B站/RSS 不计费）
- 缓存过期阈值：15 分钟（超过则 `loadCached` 仅在内存无数据时从缓存加载；内存有数据时保留不覆盖，避免 stale 缓存清除自动刷新刚填入的新数据）
- `applyCachedState` 在 `.loaded` 状态下不退回到 `.idle`（防止打开弹窗时状态闪烁）
- `RateLimiter` 是 actor，线程安全

### Refresh Log
- `RefreshLog` 是 actor 隔离的环形缓冲，最多保留 10 条记录
- 触发点：启动自动刷新 (`.startup`)、定时器 (`.timer1h`)、手动刷新 (`.manual`)、弹窗打开时 `loadCached` (`.popoverOpen`)
- 每条记录包含：每源结果（ok/N、failed/原因、cache/N、skipped/N）、AI 状态前后对比
- 日志落盘到 `~/Library/Caches/<bundleID>/refresh.log`（每次写后截断至最新 10 条）
- UI：设置 → 通用 → 诊断 → "刷新日志"，折叠表格 + 复制按钮，不含 API Key、密码等敏感数据

## Dependencies

无外部依赖。微博 JSON API 失败时降级到 HTML 页面正则解析（不需要 SwiftSoup）。

## Notifications

| Name | Sender | Receiver | Purpose |
|------|--------|----------|---------|
| `.rssSourceAdded` | `RSSTab` | `AppDelegate` | RSS 添加后立即刷新该源 |
| `.switchToAITab` | `AppDelegate` | `SettingsWindow` | 打开设置时切换到 AI 标签 |
| `.apiKeyConfigured` | `AITab` | `AppDelegate` | 保存 API Key 后自动刷新 AI 总结 |

## Push Notifications (macOS UserNotifications)

- **每小时推送**: `doRefresh` 完成后（仅自动刷新，非手动）调用 `NotificationService.sendHourlyPush`，内容为最新 `allActiveItems` 前 N 条（N = `pushCount`）
- **每日推送**: `UNCalendarNotificationTrigger` 预定时间触发；每次 `doRefresh` 后调用 `rescheduleDailyPush` 更新 pending 通知内容（确保用户收到的是最近一次刷新结果）
- **退出清理**: `applicationWillTerminate` 调用 `clearAllPending`

## Code Conventions

- **异步**: 所有网络请求使用 `async/await`，无回调嵌套
- **线程安全**: `CacheManager`、`RateLimiter` 使用 `actor`
- **错误处理**: 统一使用 `NewsBarError` enum
- **UI**: SwiftUI `@Observable` (macOS 15+) + `@ObservedObject` (NewsOrchestrator)
- **命名**: 中文注释用于面向用户的功能说明，代码标识符全英文
