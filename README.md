# NewsBar

> A quiet macOS menu bar news aggregator — Weibo trending, Bilibili trending, custom RSS feeds, all at a glance.
> 安静的 macOS 菜单栏新闻聚合器 — 微博热搜、B站热搜、自定义 RSS，一目了然。

[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-15.0%2B-blue)](https://apple.com/macos)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## Features · 功能

- **🔥 Weibo Trending** · 微博热搜 — Real-time Weibo hot topics
- **📺 Bilibili Trending** · B站热搜 — Bilibili popular content
- **📡 RSS Feeds** · RSS 订阅 — Custom RSS sources, freely extensible
- **🤖 AI Summary** · AI 摘要 — Template-framework briefings with section layout; hover section to reveal source badge linking to original news
- **⏱ Auto Refresh** · 定时刷新 — Startup fetch + optional hourly timer
- **🔄 Auto Update** · 自动更新 — Check GitHub Releases, one-click download
- **🔐 Secure Storage** · 安全存储 — API Key in macOS Keychain, 1Password integration
- **🪟 Glass UI** · 毛玻璃 UI — Native SwiftUI frosted glass, consistent with system style
- **🌓 Dark Mode** · 暗色模式 — Light / Dark / System auto, real-time switching
- **📦 Zero Dependencies** · 零依赖 — Pure Swift, no third-party libraries
- **🆓 Free & Open Source** · 免费开源 — MIT License

## Install · 安装

Download the latest DMG from [Releases](../../releases) and drag to Applications.

从 [Releases](../../releases) 下载最新 DMG，拖入 Applications 即可。

> Requires macOS 15.0+ · 要求 macOS 15.0+

## Usage · 使用

1. Click the menu bar icon to expand the news panel · 点击菜单栏图标展开新闻面板
2. Click any news item to open in browser · 点击任意新闻条目在浏览器中打开
3. Hover over AI summary sections to reveal source badge; click to jump to original · 鼠标悬停 AI 摘要段落，点击角标跳转原始新闻
4. Click "Check Update" at top to manually check for new versions · 点击面板顶部「检查更新」手动检查新版本
5. Click ⚙️ at bottom to open settings, configure RSS and AI · 点击底部 ⚙️ 进入设置，配置 RSS 源和 AI 摘要
6. Click 📊 to open Dashboard for full news view · 点击 📊 打开 Dashboard 浏览全部新闻
7. Quit from the settings panel bottom · 在设置面板底部退出

### Enable AI Summary · 启用 AI 摘要

Settings → AI tab: select a provider and fill in API Key. Supports DeepSeek, MiniMax, Opencode Go/Zen, Google AI Studio.

设置 → AI 标签页：选择 AI 提供商并填入 API Key。支持 DeepSeek、MiniMax、Opencode Go/Zen、Google AI Studio 等。

## Supported AI Providers · 支持的 AI 提供商

| Provider | Endpoint | Models |
|---|---|---|
| DeepSeek | api.deepseek.com | deepseek-v4-flash, deepseek-v4-pro |
| MiniMax | api.minimaxi.com | MiniMax-M2.7, MiniMax-M2.5, MiniMax-M2.1 |
| Opencode Go | open-code-go.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Opencode Zen | open-code-zen.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Google AI Studio | generativelanguage.googleapis.com | gemini-2.5-flash, gemini-2.5-pro |

## Develop · 开发

```bash
# Build · 构建
swift build -c release --arch arm64

# Or use the build script · 或使用打包脚本
scripts/build.sh
```

### Release Workflow · 发布流程

```bash
scripts/bump-version.sh          # Bump version + tag · 升级版本号并打 tag
scripts/bump-version.sh 1.1.0    # Or specify version · 或指定版本号
scripts/build.sh                 # Build DMG · 构建 DMG
scripts/release.sh               # GitHub Release + upload DMG · 创建发布并上传
```

## Project Structure · 项目结构

```text
Sources/NewsBar/
├── main.swift              # Entry point, single-instance check
├── AppDelegate.swift       # Status bar, popover, window management
├── Models/
│   ├── AIProvider.swift        # Multi-provider AI definitions
│   ├── NewsItem.swift          # News item model
│   ├── NewsSource.swift        # Source enum (Weibo/Bilibili/RSS)
│   ├── AppSettings.swift       # User settings (Observable)
│   ├── CacheEntry.swift        # Cache entry
│   └── UpdateInfo.swift        # Release/version models
├── Services/
│   ├── NewsOrchestrator.swift  # Core coordinator: refresh, cache, AI state machine
│   ├── UpdateChecker.swift     # GitHub update check + DMG download
│   ├── WeiboHotService.swift   # Weibo trending fetcher
│   ├── BilibiliHotService.swift# Bilibili trending fetcher
│   ├── RSSService.swift        # RSS/Atom parser
│   ├── AISummaryService.swift  # AI summary (multi-provider)
│   ├── CacheManager.swift      # File cache (actor)
│   ├── KeychainManager.swift   # Keychain storage
│   ├── RateLimiter.swift       # Rate limiter (actor)
│   ├── RefreshLog.swift        # Refresh log (actor, ring buffer)
│   └── SecurityPolicies.swift  # URL/sanitize/XML safety
├── Views/
│   ├── MenuBar/                # Popover components (AISummaryCard, NewsSection, SourceBadge)
│   ├── Settings/               # Settings window tabs
│   └── Dashboard/              # Dashboard window
└── Extensions/
    ├── URLOpener.swift          # Safe URL opening
    └── View+Glass.swift         # Glass effect + adaptive color scheme
```

## Tech Stack · 技术栈

- **Swift 5.9** + **SwiftUI** (macOS 15.0+)
- **AppKit**: NSStatusBar, NSPopover
- **AI APIs**: DeepSeek / MiniMax / Opencode / Google AI Studio
- **Storage**: macOS Keychain, UserDefaults, File-based cache (actor)
- **Zero external dependencies** · 零外部依赖

## Keywords

`macOS menu bar` · `news aggregator` · `SwiftUI` · `AI summary` · `Weibo trending` · `Bilibili trending` · `RSS reader` · `menu bar app` · `status bar` · `DeepSeek` · `Gemini` · `MiniMax` · `Keychain` · `native macOS app` · `open source`

## Related Links · 相关链接

- [Releases](../../releases)
- [Weibo Trending API](https://s.weibo.com)
- [Bilibili Trending API](https://www.bilibili.com)
- [DeepSeek Platform](https://platform.deepseek.com)
- [MiniMax Platform](https://platform.minimaxi.com)
- [Google AI Studio](https://aistudio.google.com)

## License

MIT © 2024-2026 [blackkcold](https://github.com/blackkcold) and contributors.
See [LICENSE](LICENSE) for details.
