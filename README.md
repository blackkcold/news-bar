# NewsBar

> A quiet macOS menu bar news aggregator — Weibo trending, Bilibili trending, and custom RSS feeds, all at a glance.

<p align="center">
  <strong>🌐 Languages</strong> ·
  <a href="#-languages">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/macOS-15.0%2B-blue" alt="macOS 15.0+">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License">
  <img src="https://img.shields.io/badge/Platforms-macOS-lightgrey" alt="Platforms: macOS">
</p>

**NewsBar** is a **native macOS menu bar / status bar news app** built with SwiftUI. It brings **Weibo trending**, **Bilibili trending**, and your own **RSS feeds** together into one quiet, glanceable menu bar panel. Optional **AI-powered summaries** turn the day's noise into a curated briefing with citations.

Zero dependencies. Pure Swift. Free & open source (MIT).

---

## ✨ Features

- **🔥 Weibo Trending** — Real-time Weibo hot search topics
- **📺 Bilibili Trending** — Bilibili popular & trending content
- **📡 Custom RSS Feeds** — Add any RSS/Atom source; fully extensible
- **🤖 AI Summary** — One shared dual-category briefing (Trend Overview / Daily Essentials) served across Popup and Dashboard; cited rows open the original source. **Two-layer smart triggering**: a regular 1-hour baseline, plus an **immediate trigger when a Weibo "爆" (burst) label appears**, which forces the burst topic into the Trend Overview and prioritises it. Burst summaries are throttled to once per 15 minutes.
- **📊 Editorial Dashboard** — Responsive masthead, shared AI briefing, redesigned trend cards, and per-source RSS layout with individual refresh actions
- **⏱ Adaptive Smart Refresh** — Startup fetch + visibility-aware hot-trend polling + adaptive RSS cadence
- **🔄 Auto Update** — Check GitHub Releases, one-click download
- **🔐 Secure Storage** — API Key encrypted with AES-256-GCM, machine-bound
- **📰 Retro Editorial Theme** — Optional 1960s editorial design with paper texture, brick-red accents, square clipping cards, and print-style source marks
- **🪟 Modern Material Theme** — Native SwiftUI material appearance with clear editorial page headings
- **🌓 Dark Mode** — Light / Dark / System auto, real-time switching
- **📦 Zero Dependencies** — Pure Swift, no third-party libraries

---

## 📦 Install

Download the latest DMG from [Releases](../../releases) and drag it to **Applications**.

> Requires **macOS 15.0+**

## 🚀 Usage

1. Click the **menu bar icon** to expand the news panel
2. Click any news item to open it in your browser
3. **Cited AI summary rows** show a persistent source badge; click to open the original
4. Click **Check Update** at the top to manually check for new versions
5. Click ⚙️ at the bottom to open Settings and configure RSS sources and AI
6. Click 📊 to open the **Dashboard** for the full news view: hot-trend cards, the AI briefing panel, and a per-source RSS region in a fixed two-column grid
7. Choose **Modern Material** or **Retro Editorial** under Settings → General → Theme
8. Quit from the bottom of the Settings panel

> Popup and Dashboard reuse one detailed AI briefing generated after a global refresh. Popup shows at most two rows per category; Dashboard shows the full result. The Dashboard also provides an independent AI refresh button.

---

## 🤖 Enable AI Summary

Settings → **AI** tab: pick a provider and enter your API Key. Supported providers: **DeepSeek**, **MiniMax**, **Opencode Go/Zen**, **Google AI Studio**, **Ollama Cloud**, plus **user-defined custom providers** (endpoint, model IDs, auth header).

Popup and Dashboard share one summary length preset (default 360 words) and one daily request cap (default 50, configurable 20/50/100). Automatic summaries use 12/24-hour trend history and only regenerate after meaningful changes and cooldown checks; the Dashboard AI button still forces an independent summary regeneration.

### Supported AI Providers

| Provider | Endpoint | Models |
|---|---|---|
| DeepSeek | api.deepseek.com | deepseek-v4-flash, deepseek-v4-pro |
| MiniMax | api.minimaxi.com | MiniMax-M3, MiniMax-M2.7, MiniMax-M2.7-highspeed, MiniMax-M2.5, MiniMax-M2.5-highspeed, MiniMax-M2.1, MiniMax-M2.1-highspeed, MiniMax-M2 |
| Opencode Go | open-code-go.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Opencode Zen | open-code-zen.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Google AI Studio | generativelanguage.googleapis.com | gemini-3.6-flash, gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.1-flash-lite, gemini-3.1-pro-preview, gemini-3-flash-preview, gemini-2.5-pro, gemini-2.5-flash, gemini-2.5-flash-lite |
| Ollama Cloud | ollama.com | deepseek-v4-flash:cloud, deepseek-v4-pro:cloud, gpt-oss:20b-cloud, gpt-oss:120b-cloud, kimi-k3:cloud, minimax-m3:cloud, ... |
| Custom | Your own | Custom endpoint / model IDs |

> **Model folding**: by default only DeepSeek-family models are shown for each provider (where available); enable **Show All AI Models** under General → Developer Options to see the full official model list.

---

## 🛠 Develop

```bash
# Build
swift build -c release --arch arm64

# Or use the official packaging script (builds app + DMG)
bash scripts/build.sh
```

### Release Workflow

```bash
# 1. Update version.txt and RELEASE_NOTES.md on release/vX.Y.Z first
swift test                    # Run the full test suite
bash scripts/build.sh         # Official app + DMG packaging
# 2. Open a PR to main, wait for required CI, then merge
git tag -a vX.Y.Z -m "vX.Y.Z — summary"
git push origin vX.Y.Z
bash scripts/release.sh       # GitHub Release + DMG/SHA256 upload
```

See [docs/release-conventions.md](docs/release-conventions.md) for the complete PR, CI, merge, tagging and verification workflow.

---

## 📂 Project Structure

```text
Sources/NewsBar/
├── main.swift              # Entry point, single-instance check
├── AppDelegate.swift       # Status bar, popover, window management
├── Models/
│   ├── AIProvider.swift        # Multi-provider AI definitions
│   ├── NewsItem.swift          # News item model (incl. Weibo hot label)
│   ├── NewsSource.swift        # Source enum (Weibo/Bilibili/RSS)
│   ├── AppSettings.swift       # User settings (Observable)
│   ├── CacheEntry.swift        # Cache entry
│   └── UpdateInfo.swift        # Release/version models
├── Services/
│   ├── NewsOrchestrator.swift  # Core coordinator: refresh, cache, shared AI state machine
│   ├── UpdateChecker.swift     # GitHub update check + DMG download
│   ├── WeiboHotService.swift   # Weibo trending fetcher
│   ├── BilibiliHotService.swift# Bilibili trending fetcher
│   ├── RSSService.swift        # RSS/Atom parser
│   ├── AISummaryService.swift  # AI summary (multi-provider)
│   ├── CacheManager.swift      # File cache (actor)
│   ├── KeychainManager.swift   # Deprecated — retained for one-time migration only
│   ├── EncryptedKeyStore.swift # AES-256-GCM encrypted file storage
│   ├── RateLimiter.swift       # Rate limiter (actor)
│   ├── RefreshLog.swift        # Refresh log (actor, ring buffer)
│   └── SecurityPolicies.swift  # URL/sanitize/XML safety
├── Views/
│   ├── MenuBar/                # Popover components with compact shared AI briefing
│   ├── Settings/               # Settings window tabs
│   ├── Dashboard/              # Dashboard window, full AI briefing + per-source refresh
│   └── Theme/                  # Modern Material / Retro Editorial primitives
└── Extensions/
    ├── URLOpener.swift          # Safe URL opening
    └── View+Glass.swift         # Glass effect + adaptive color scheme
```

---

## ⚙️ Tech Stack

- **Swift 5.9** + **SwiftUI** (macOS 15.0+)
- **AppKit**: NSStatusBar, NSPopover
- **AI APIs**: DeepSeek / MiniMax / Opencode / Google AI Studio / Ollama Cloud / Custom
- **Storage**: Encrypted file (AES-256-GCM, CryptoKit), UserDefaults, file-based cache (actor)
- **Zero external dependencies**

---

## 🔍 Keywords

`macOS menu bar app` · `status bar app` · `menu bar news` · `news aggregator` · `SwiftUI` · `Swift` · `native macOS app` · `AI summary` · `Weibo trending` · `Weibo hot search` · `Bilibili trending` · `RSS reader` · `RSS feed aggregator` · `trending topics` · `DeepSeek` · `Gemini` · `MiniMax` · `Ollama` · `menu bar` · `menubar app` · `open source`

---

## 🔗 Related Links

- [Releases](../../releases)
- [Weibo Trending API](https://s.weibo.com)
- [Bilibili Trending API](https://www.bilibili.com)
- [DeepSeek Platform](https://platform.deepseek.com)
- [MiniMax Platform](https://platform.minimaxi.com)
- [Google AI Studio](https://aistudio.google.com)
- [Ollama Cloud](https://ollama.com)

---

## 📄 License

MIT © 2024-2026 [blackkcold](https://github.com/blackkcold) and contributors.
See [LICENSE](LICENSE) for details.

---

## 🌐 Languages

- **English** — this file
- [简体中文](README.zh-CN.md)
- [繁體中文](README.zh-TW.md)
- [日本語](README.ja.md)
- [한국어](README.ko.md)
