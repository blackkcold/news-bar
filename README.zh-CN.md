# NewsBar

> 一款安静的 macOS 菜单栏新闻聚合器 — 微博热搜、B站热搜、自定义 RSS，一目了然。

<p align="center">
  <strong>🌐 语言</strong> ·
  <a href="README.md">English</a> ·
  <a href="#-语言">简体中文</a> ·
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

**NewsBar** 是一款基于 SwiftUI 的**原生 macOS 菜单栏 / 状态栏新闻应用**。它将**微博热搜**、**B站热搜**和**你自己的 RSS 订阅源**汇聚到一个安静、一目了然的菜单栏面板中。可选**AI 智能摘要**将一天的信息噪音整理成带引用的精读简报。

零依赖。纯 Swift。免费开源（MIT）。

---

## ✨ 功能特性

- **🔥 微博热搜** — 实时微博热搜话题
- **📺 B站热搜** — B站热门内容与热搜
- **📡 自定义 RSS 订阅** — 添加任意 RSS/Atom 源，完全可扩展
- **🤖 AI 摘要** — 一份共享的双分类简报（趋势概览 / 每日精选），同时服务于 Popup 与 Dashboard；带引用的行点击可打开原文。**两层智能触发**：常态以「距上次总结 ≥ 1 小时」为基准，识别到微博「爆」标签话题时**立即触发**总结，并强制将爆标签话题纳入【趋势概览】优先展示；爆标签成功总结后 15 分钟内不重复触发。
- **📊 编辑式仪表盘** — 响应式抬头、共享 AI 简报、重制的趋势卡片，以及带独立刷新操作的按来源 RSS 布局
- **⏱ 自适应智能刷新** — 启动抓取 + 可见性感知的热搜轮询 + 自适应 RSS 节奏
- **🔄 自动更新** — 检查 GitHub Releases，一键下载
- **🔐 安全存储** — API Key 使用 AES-256-GCM 加密，绑定设备
- **📰 复古报刊主题** — 可选 1960 年代编辑风设计：纸张纹理、砖红点缀、方形剪报卡片、印刷风来源徽记
- **🪟 现代材质主题** — 原生 SwiftUI 材质外观，搭配清晰的编辑式页面抬头
- **🌓 暗色模式** — 浅色 / 深色 / 跟随系统，实时切换
- **📦 零依赖** — 纯 Swift，无第三方库

---

## 📦 安装

从 [Releases](../../releases) 下载最新 DMG，拖入 **Applications** 即可。

> 需要 **macOS 15.0+**

## 🚀 使用说明

1. 点击**菜单栏图标**展开新闻面板
2. 点击任意新闻条目在浏览器中打开
3. **带引用的 AI 摘要行**显示常驻来源角标，点击跳转原文
4. 点击顶部**检查更新**手动检查新版本
5. 点击底部 ⚙️ 打开设置，配置 RSS 源与 AI 摘要
6. 点击 📊 打开 **Dashboard** 查看完整新闻视图：热点趋势卡片、AI 简报面板，以及固定双列网格的按来源 RSS 区域
7. 在「设置 → 通用 → 主题」切换**现代材质**或**复古报刊**主题
8. 在设置面板底部退出

> Popup 与 Dashboard 复用全局刷新后生成的一份详细 AI 简报。Popup 每类最多显示两条，Dashboard 显示完整结果。Dashboard 还提供独立的 AI 刷新按钮。

---

## 🤖 启用 AI 摘要

设置 → **AI** 标签页：选择 AI 提供商并填入 API Key。支持 **DeepSeek**、**MiniMax**、**Opencode Go/Zen**、**Google AI Studio**、**Ollama Cloud**，以及**用户自定义提供商**（端点、模型 ID、认证头）。

Popup 和 Dashboard 共用一个摘要长度预设（默认 360 字）和每日 AI 调用上限（默认 50，可选 20/50/100）。自动总结结合近 12/24 小时趋势历史，仅在显著变化及冷却条件满足时重建；Dashboard 的 AI 按钮仍可强制独立刷新摘要。

### 支持的 AI 提供商

| Provider | Endpoint | Models |
|---|---|---|
| DeepSeek | api.deepseek.com | deepseek-v4-flash, deepseek-v4-pro |
| MiniMax | api.minimaxi.com | MiniMax-M3, MiniMax-M2.7, MiniMax-M2.7-highspeed, MiniMax-M2.5, MiniMax-M2.5-highspeed, MiniMax-M2.1, MiniMax-M2.1-highspeed, MiniMax-M2 |
| Opencode Go | open-code-go.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Opencode Zen | open-code-zen.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Google AI Studio | generativelanguage.googleapis.com | gemini-3.6-flash, gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.1-flash-lite, gemini-3.1-pro-preview, gemini-3-flash-preview, gemini-2.5-pro, gemini-2.5-flash, gemini-2.5-flash-lite |
| Ollama Cloud | ollama.com | deepseek-v4-flash:cloud, deepseek-v4-pro:cloud, gpt-oss:20b-cloud, gpt-oss:120b-cloud, kimi-k3:cloud, minimax-m3:cloud, ... |
| Custom | 用户自定义 | 自定义端点 / 模型 ID |

> **模型折叠**：默认仅显示各供应商的 DeepSeek 系模型（若有）；在「通用 → 开发者选项」开启「显示全部 AI 模型」可查看该供应商全部官方模型。

---

## 🛠 开发

```bash
# 构建
swift build -c release --arch arm64

# 或使用官方打包脚本（构建 App + DMG）
bash scripts/build.sh
```

### 发布流程

```bash
# 1. 先在 release/vX.Y.Z 更新 version.txt 与 RELEASE_NOTES.md
swift test                    # 运行全量测试
bash scripts/build.sh         # 官方 App 与 DMG 打包
# 2. 向 main 提交 PR，等待必需 CI 通过后合并
git tag -a vX.Y.Z -m "vX.Y.Z — summary"
git push origin vX.Y.Z
bash scripts/release.sh       # GitHub Release + DMG/SHA256 上传
```

完整的 PR、CI、合并、打标签与验证流程见 [docs/release-conventions.md](docs/release-conventions.md)。

---

## 📂 项目结构

```text
Sources/NewsBar/
├── main.swift              # 入口点、单实例检查
├── AppDelegate.swift       # 状态栏、popover、窗口管理
├── Models/
│   ├── AIProvider.swift        # 多提供商 AI 定义
│   ├── NewsItem.swift          # 新闻条目模型（含微博热搜标签）
│   ├── NewsSource.swift        # 来源枚举（微博/B站/RSS）
│   ├── AppSettings.swift       # 用户设置（Observable）
│   ├── CacheEntry.swift        # 缓存条目
│   └── UpdateInfo.swift        # Release/版本模型
├── Services/
│   ├── NewsOrchestrator.swift  # 核心协调器：刷新、缓存、共享 AI 状态机
│   ├── UpdateChecker.swift     # GitHub 更新检查 + DMG 下载
│   ├── WeiboHotService.swift   # 微博热搜抓取
│   ├── BilibiliHotService.swift# B站热搜抓取
│   ├── RSSService.swift        # RSS/Atom 解析
│   ├── AISummaryService.swift  # AI 摘要（多提供商）
│   ├── CacheManager.swift      # 文件缓存（actor）
│   ├── KeychainManager.swift   # 已弃用 — 仅用于一次性迁移
│   ├── EncryptedKeyStore.swift # AES-256-GCM 加密文件存储
│   ├── RateLimiter.swift       # 限速器（actor）
│   ├── RefreshLog.swift        # 刷新日志（actor，环形缓冲）
│   └── SecurityPolicies.swift  # URL/清洗/XML 安全
├── Views/
│   ├── MenuBar/                # 复用 popover 组件，紧凑共享 AI 简报
│   ├── Settings/               # 设置窗口标签页
│   ├── Dashboard/              # Dashboard 窗口、完整 AI 简报 + 按来源刷新
│   └── Theme/                  # 现代材质 / 复古报刊原语
└── Extensions/
    ├── URLOpener.swift          # 安全 URL 打开
    └── View+Glass.swift         # 玻璃效果 + 自适应配色
```

---

## ⚙️ 技术栈

- **Swift 5.9** + **SwiftUI** (macOS 15.0+)
- **AppKit**: NSStatusBar, NSPopover
- **AI APIs**: DeepSeek / MiniMax / Opencode / Google AI Studio / Ollama Cloud / 自定义
- **存储**: 加密文件（AES-256-GCM, CryptoKit）、UserDefaults、文件缓存（actor）
- **零外部依赖**

---

## 🔍 关键词

`macOS 菜单栏应用` · `状态栏应用` · `菜单栏新闻` · `新闻聚合器` · `SwiftUI` · `Swift` · `原生 macOS 应用` · `AI 摘要` · `微博热搜` · `B站热搜` · `RSS 阅读器` · `RSS 聚合` · `热搜话题` · `DeepSeek` · `Gemini` · `MiniMax` · `Ollama` · `菜单栏` · `开源`

---

## 🔗 相关链接

- [Releases](../../releases)
- [微博热搜 API](https://s.weibo.com)
- [B站热搜 API](https://www.bilibili.com)
- [DeepSeek Platform](https://platform.deepseek.com)
- [MiniMax Platform](https://platform.minimaxi.com)
- [Google AI Studio](https://aistudio.google.com)
- [Ollama Cloud](https://ollama.com)

---

## 📄 许可证

MIT © 2024-2026 [blackkcold](https://github.com/blackkcold) and contributors.
详见 [LICENSE](LICENSE)。

---

## 🌐 语言

- [English](README.md)
- **简体中文** — 本文件
- [繁體中文](README.zh-TW.md)
- [日本語](README.ja.md)
- [한국어](README.ko.md)
