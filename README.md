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
- **🤖 AI Summary** · AI 摘要 — One shared dual-category briefing (趋势概览 / 每日精选) serves Popup and Dashboard; cited rows open the original source. Dashboard shows the full briefing while Popup limits each category to two rows. Global refresh and the independent AI refresh action both update the shared result.
- **📊 Editorial Dashboard** · 编辑式仪表盘 — Responsive masthead, shared AI briefing, redesigned trend cards and per-source RSS layout with individual source refresh actions
- **⏱ Auto Refresh** · 定时刷新 — Startup fetch + optional hourly timer
- **🔄 Auto Update** · 自动更新 — Check GitHub Releases, one-click download
- **🔐 Secure Storage** · 安全存储 — API Key encrypted with AES-256-GCM, machine-bound
- **📰 Retro Editorial Theme** · 复古报刊主题 — Optional 1960s editorial design with paper texture, brick-red accents, square clipping cards and print-style source marks across Dashboard, Popup and Settings
- **🪟 Modern Material Theme** · 现代材质主题 — Native SwiftUI material appearance with the same clearer editorial page headings
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
3. Cited AI summary rows show a persistent source badge; click to open original · 有引用的 AI 摘要行显示常驻来源角标，点击跳转原始新闻
4. Click "Check Update" at top to manually check for new versions · 点击面板顶部「检查更新」手动检查新版本
5. Click ⚙️ at bottom to open settings, configure RSS and AI · 点击底部 ⚙️ 进入设置，配置 RSS 源和 AI 摘要
6. Click 📊 to open Dashboard for full news view: sidebar with hot-trend cards and AI briefing panel, plus per-source RSS card region with fixed two-column grid · 点击 📊 打开 Dashboard：侧边栏热点趋势卡片和 AI 简报面板，右侧按来源分卡的 RSS 固定双列网格区域
7. Choose Modern Material or Retro Editorial under Settings → General → Theme · 在「设置 → 通用 → 主题」切换现代材质或复古报刊主题
8. Quit from the settings panel bottom · 在设置面板底部退出

> Popup and Dashboard reuse one detailed AI briefing generated after global refresh. Popup displays at most two rows per category; Dashboard displays the full result. Dashboard also provides an independent AI refresh button.
> Popup 与 Dashboard 复用全局刷新后生成的一份详细 AI 简报。Popup 每类最多显示两条，Dashboard 显示完整结果，并提供 AI 独立刷新按钮。

### Enable AI Summary · 启用 AI 摘要

Settings → AI tab: select a provider and fill in API Key. Supports DeepSeek, MiniMax, Opencode Go/Zen, Google AI Studio.

设置 → AI 标签页：选择 AI 提供商并填入 API Key。支持 DeepSeek、MiniMax、Opencode Go/Zen、Google AI Studio 等。

Popup and Dashboard share one summary length preset (default 360 words) and one daily request cap (default 50, configurable 20/50/100). A global refresh regenerates the shared summary after source updates; the Dashboard AI button regenerates only the summary.

Popup 和 Dashboard 共用一个摘要长度预设（默认 360 字）和每日 AI 调用上限（默认 50，可选 20/50/100）。全局刷新会在新闻源更新后重建共享摘要；Dashboard 的 AI 按钮只刷新摘要。

## Supported AI Providers · 支持的 AI 提供商

| Provider | Endpoint | Models |
|---|---|---|
| DeepSeek | api.deepseek.com | deepseek-v4-flash, deepseek-v4-pro |
| MiniMax | api.minimaxi.com | MiniMax-M3, MiniMax-M2.7, MiniMax-M2.7-highspeed, MiniMax-M2.5, MiniMax-M2.1 |
| Opencode Go | open-code-go.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Opencode Zen | open-code-zen.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Google AI Studio | generativelanguage.googleapis.com | gemini-3.6-flash, gemini-2.5-flash, gemini-2.5-pro, gemini-3.5-flash, gemini-3.5-flash-lite |

## Develop · 开发

```bash
# Build · 构建
swift build -c release --arch arm64

# Or use the official packaging script · 或使用官方打包脚本
bash scripts/build.sh
```

### Release Workflow · 发布流程

```bash
# Update version.txt and RELEASE_NOTES.md on release/vX.Y.Z first
swift test                       # Run the full test suite · 运行全量测试
bash scripts/build.sh            # Official app + DMG packaging · 官方 App 与 DMG 打包
# Open a PR to main, wait for required CI, then merge
git tag -a vX.Y.Z -m "vX.Y.Z — summary"
git push origin vX.Y.Z
bash scripts/release.sh          # GitHub Release + DMG/SHA256 upload
```

See [docs/release-conventions.md](docs/release-conventions.md) for the complete PR, CI, merge, tagging and verification workflow.

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
│   ├── NewsOrchestrator.swift  # Core coordinator: refresh, cache, shared AI state machine, per-source RSS refresh
│   ├── UpdateChecker.swift     # GitHub update check + DMG download
│   ├── WeiboHotService.swift   # Weibo trending fetcher
│   ├── BilibiliHotService.swift# Bilibili trending fetcher
│   ├── RSSService.swift        # RSS/Atom parser
│   ├── AISummaryService.swift  # AI summary (multi-provider)
│   ├── CacheManager.swift      # File cache (actor)
│   ├── KeychainManager.swift   # Deprecated — retained for one-time migration only
│   ├── EncryptedKeyStore.swift  # AES-256-GCM encrypted file storage (replaces Keychain)
│   ├── RateLimiter.swift       # Rate limiter (actor)
│   ├── RefreshLog.swift        # Refresh log (actor, ring buffer)
│   └── SecurityPolicies.swift  # URL/sanitize/XML safety
├── Views/
│   ├── MenuBar/                # Reused popover components with compact shared AI briefing
│   ├── Settings/               # Settings window tabs
│   ├── Dashboard/              # Dashboard window, full shared AI briefing and per-source refresh controls
│   └── Theme/                  # Shared Modern Material / Retro Editorial primitives
└── Extensions/
    ├── URLOpener.swift          # Safe URL opening
    └── View+Glass.swift         # Glass effect + adaptive color scheme
```

## Tech Stack · 技术栈

- **Swift 5.9** + **SwiftUI** (macOS 15.0+)
- **AppKit**: NSStatusBar, NSPopover
- **AI APIs**: DeepSeek / MiniMax / Opencode / Google AI Studio
- **Storage**: Encrypted file (AES-256-GCM, CryptoKit), UserDefaults, File-based cache (actor)
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
