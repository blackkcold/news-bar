# NewsBar — Project Bootstrap

## Overview

macOS 菜单栏即时新闻聚合器。状态栏图标点击弹出 Popover，展示微博/B站热搜 + RSS 源 + AI 总结。

## Architecture

```
Sources/NewsBar/
├── main.swift              # 入口：单实例检测 → NSApp 启动
├── AppDelegate.swift        # 生命周期：statusItem、popover、延迟 keychain 读取、通知监听
├── Models/
│   ├── AIProvider.swift       # 多 AI 提供商枚举（6 providers）
│   ├── NewsItem.swift       # 新闻条目模型 (Identifiable, Codable)
│   ├── NewsSource.swift     # 数据源枚举 (weibo/bilibili/rss)
│   ├── AppSettings.swift    # @Observable 全局设置 (UserDefaults 持久化 + cachedAPIKey 内存缓存；onePasswordRef 走 Keychain)
│   ├── CacheEntry.swift     # 缓存条目 (items + hash + timestamp)
│   └── UpdateInfo.swift     # GitHub Release 模型 + 版本比对
├── Services/
│   ├── NewsOrchestrator.swift  # 核心调度器：刷新、缓存、AI 总结状态机
│   ├── UpdateChecker.swift     # 更新检查：GitHub API → 版本比对 → DMG 下载
│   ├── WeiboHotService.swift   # 微博热搜 (多级策略: ajax/side/hotSearch → s.weibo.com 降级；URL 由 word 字段构造 https://s.weibo.com/weibo?q=关键词&Refer=top)
│   ├── BilibiliHotService.swift # B站热搜 (bilibili.com API)
│   ├── RSSService.swift        # RSS/Atom Feed 解析 (XMLParser)
│   ├── AISummaryService.swift   # AI 总结（多提供商：OpenAI/Anthropic 格式分发；DeepSeek/MiniMax/Opencode/Google 等；含 finish_reason/stop_reason 截断检测 + 1 次自动重试）
│   ├── OnePasswordService.swift # 1Password CLI 集成 (op read)
│   ├── KeychainManager.swift   # 钥匙串读写 (account 参数化支持多 provider；双重 NoUI 保护；写入 SecItemDelete+SecItemAdd 策略；DEBUG mode KeychainAccessGate 开发开关)
│   ├── CacheManager.swift      # actor 隔离的文件缓存
│       ├── RateLimiter.swift       # actor 隔离的手动刷新频率控制
│   └── SecurityPolicies.swift  # 输入消毒、URL 校验、XML 安全配置
├── Views/
│   ├── MenuBar/
│   │   ├── PopoverContent.swift  # 主弹窗：Header + AI 状态卡 + 新闻列表 + BottomBar
│   │   ├── NewsSection.swift     # 新闻区段 (支持折叠/展开)
│   │   ├── NewsItemRow.swift     # 单条新闻行
│   │   ├── AISummaryCard.swift   # AI 总结卡片（状态驱动 + 逐字动画）
│   │   ├── UpdateBadge.swift     # 更新状态按钮（检查→下载→打开，7 态胶囊按钮）
│   │   └── BottomBar.swift       # 底部工具栏
│   ├── Dashboard/
│   │   └── DashboardWindow.swift # 独立 Dashboard 窗口（同步 AI 状态）
│   └── Settings/
│       ├── SettingsWindow.swift   # 设置窗口 (TabView，可切换到 AI 标签)
│       ├── GeneralTab.swift       # 通用设置
│       ├── RSSTab.swift           # RSS 源管理
│       ├── AITab.swift            # AI 配置 + 1Password
│       └── AboutTab.swift         # 关于
└── Extensions/
    ├── URLOpener.swift    # URL 安全打开
    └── View+Glass.swift   # 毛玻璃 UI 修饰符
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
  → statusItem / popover 就绪
  → 延迟 1.5s 用 kSecUseAuthenticationUIFail 做三态预检：
      notFound + AI 开启 → NSAlert 提示配置（仅一次）；existsAccessible/existsNeedsAuth → 自动设 hasAIKey-{provider} flag，不读 secret
  → 若没有 key 且 AI 已开启 → NSAlert 提示前往设置；"稍后再说" 后不再提示
  → 2s 自动刷新 NewsOrchestrator.refreshIfNeeded() → 无 cachedAPIKey 时状态为 .noKey（后台）
  → 10s 自动更新检查 UpdateChecker.autoCheck() → GitHub API → 有新版则 UpdateBadge 显示「更新」按钮
  → User opens popover → loadAPIKeyFromKeychainIfNeeded() → check flag || 兜底 checkAPIKeyExistence() → readAPIKey(allowUI:false) 静默读 Keychain secret（系统授权弹窗仅在用户 AITab 中主动保存 Key 时出现）
  → 读 key 成功 → 写 cachedAPIKey → manualRefresh() 抓取所有源 → AI 总结
  → AISummaryService.summarize(provider:) → 首次 max_tokens=1024 → 若截断则 max_tokens=2048 重试 1 次
  → AI 总结成功后才写 lastBatchHash；idle/noKey/error/fetching 可触发恢复总结；manualRefresh 强制总结
  → 结果通过 AISummaryState 驱动 UI：noKey / fetching / summarizing / done / truncated / error
  → 结果文本首次渲染直接显示（.onAppear），状态转变时逐字动画（.onChange(of:)）
  → 若 autoRefreshEnabled，Timer(3600s) 定时刷新
User opens popover
  → PopoverContent.task { loadCached() } 显示缓存数据（过期缓存 >15min 不加载，显示加载中）
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
2. 敏感数据用 `KeychainManager` 存储（参考 `apiKey` / `onePasswordRef` 模式）
3. 非敏感数据用 `UserDefaults` 持久化（didSet 自动同步）
4. `Views/Settings/XxxTab.swift` — 添加 UI 绑定

### Security Rules
- **API Key**: Keychain 存储（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）；每个 AI Provider 独立 Keychain account (`"ai-key-{provider}"`)；所有读取使用双重 NoUI 保护；写入使用 SecItemDelete+SecItemAdd 策略；`AppSettings.cachedAPIKey` 内存缓存，切换 provider 时自动清除；旧 DeepSeek account 首次启动自动迁移；1Password ref 共用 `"one-password-ref"` account，不受 provider 切换影响
- **AI 总结**: `AISummaryState` 驱动 UI；`finish_reason="length"` 截断时自动重试 1 次（扩大 max_tokens），仍截断则 UI 提示并显示「重新生成」按钮；`lastBatchHash` 仅在总结成功后更新，避免无 key/失败污染 hash；手动刷新强制总结，自动刷新在 idle/noKey/error/fetching 时允许恢复；AISummaryCard 用 `.onAppear` 直接显示已有文本，`.onChange(of:)` 触发逐字动画
- **1Password**: `op read` 通过 `Process` 调用（数组传参，非 shell 拼接，无注入风险）；`onePasswordRef` 存储在 Keychain（`account: "one-password-ref"`），首次启动自动从 UserDefaults 迁移
- **更新检查**: 仅访问 GitHub 公开 API（`api.github.com/repos/blackkcold/news-bar/releases/latest`），无认证；DMG 下载到 `~/Library/Caches/<bundleID>/Updates/`，下载后校验文件大小，不自动挂载或执行
- **URL 打开**: 必须通过 `SecurityPolicies.validateURL()` 校验 (HTTPS only)
- **用户输入**: 必须通过 `SecurityPolicies.sanitizeUserInput()` 处理（移除控制字符 + `.whitespacesAndNewlines` 防 copy-paste 换行符污染）
- **XML 解析**: 必须设置 `shouldResolveExternalEntities = false`

### Rate Limiting
- 自动刷新：启动时 2s 延迟执行一次 + 可选每小时定时刷新
- 手动刷新：每小时连续手动刷新 3 次触发警告
- 缓存过期阈值：15 分钟（超过则 loadCached 返回空，等自动/手动刷新填充）
- `RateLimiter` 是 actor，线程安全

## Dependencies

无外部依赖。微博 JSON API 失败时降级到 HTML 页面正则解析（不需要 SwiftSoup）。

## Notifications

| Name | Sender | Receiver | Purpose |
|------|--------|----------|---------|
| `.rssSourceAdded` | `RSSTab` | `AppDelegate` | RSS 添加后立即刷新该源 |
| `.switchToAITab` | `AppDelegate` | `SettingsWindow` | 打开设置时切换到 AI 标签 |
| `.apiKeyConfigured` | `AITab` | `AppDelegate` | 保存 API Key 后自动刷新 AI 总结 |

## Code Conventions

- **异步**: 所有网络请求使用 `async/await`，无回调嵌套
- **线程安全**: `CacheManager`、`RateLimiter` 使用 `actor`
- **错误处理**: 统一使用 `NewsBarError` enum
- **UI**: SwiftUI `@Observable` (macOS 15+) + `@ObservedObject` (NewsOrchestrator)
- **命名**: 中文注释用于面向用户的功能说明，代码标识符全英文
