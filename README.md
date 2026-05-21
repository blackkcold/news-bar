# NewsBar

> 一个安静的 macOS 菜单栏新闻聚合器 — 微博热搜、B站热搜、自定义 RSS，一目了然。

## 功能

- **🔥 微博热搜** — 实时获取微博热门话题
- **📺 B站热搜** — B 站热门内容即时查看
- **📡 RSS 订阅** — 支持自定义 RSS 源，自由扩展
- **🤖 AI 摘要** — 精选总结置顶展示，简要准确，自动生成
- **⏱ 定时刷新** — 启动自动获取，可开启每小时定时刷新
- **🔄 自动更新** — 自动检查 GitHub Release，手动一键下载最新版本
- **🔐 安全存储** — API Key 存储在 macOS Keychain，支持 1Password 读取
- **🪟 毛玻璃 UI** — 原生 SwiftUI 毛玻璃效果，与系统风格统一
- **📦 零依赖** — 纯 Swift 实现，无第三方库依赖

## 安装

从 [Releases](../../releases) 下载最新 DMG 文件，拖入 Applications 即可。

> 要求 macOS 15.0+

## 使用

1. 点击菜单栏图标，展开新闻面板
2. 点击任意新闻条目，在浏览器中打开
3. 点击面板顶部的「检查更新」按钮，可手动检查是否有新版本
4. 点击面板底部的 ⚙️ 进入设置，配置 RSS 源和 AI 摘要
5. 点击 📊 打开 Dashboard 视图，浏览全部新闻
6. 在设置面板底部可退出 NewsBar

### 启用 AI 摘要

在设置 → AI 标签页中选择 AI 提供商并填入 API Key，开启 AI 摘要功能。支持 DeepSeek、MiniMax、Opencode Go/Zen、Google AI Studio 等多种 AI API。

## 开发

```bash
# 构建
swift build -c release --arch arm64

# 或使用打包脚本
scripts/build.sh
```

### 发布流程

```bash
scripts/bump-version.sh          # 升级版本号并打 tag
scripts/bump-version.sh 1.1.0    # 或指定版本号
scripts/build.sh                 # 构建 DMG
scripts/release.sh               # 创建 GitHub Release 并上传 DMG
```

## 项目结构

```text
Sources/NewsBar/
├── main.swift              # 入口，单实例检查
├── AppDelegate.swift       # 状态栏、弹窗、窗口管理
├── Models/
│   ├── AIProvider.swift      # 多 AI 提供商定义
│   ├── NewsItem.swift      # 新闻条目模型
│   ├── NewsSource.swift    # 新闻源枚举（微博/B站/RSS）
│   ├── AppSettings.swift   # 用户设置
│   └── UpdateInfo.swift    # 版本/更新数据模型
├── Services/
│   ├── NewsOrchestrator.swift   # 刷新调度与缓存协调
│   ├── UpdateChecker.swift      # GitHub 更新检查与下载
│   ├── WeiboHotService.swift    # 微博热搜抓取
│   ├── BilibiliHotService.swift # B站热搜抓取
│   ├── RSSService.swift         # RSS 解析
│   ├── AISummaryService.swift   # AI 摘要（多提供商）
│   ├── CacheManager.swift       # 本地缓存
│   ├── KeychainManager.swift    # Keychain 存储
│   └── RateLimiter.swift        # 频率限制
└── Views/
    ├── MenuBar/            # 菜单栏弹窗组件 (含 UpdateBadge)
    ├── Settings/           # 设置窗口
    └── Dashboard/          # 仪表盘窗口
```

## 技术栈

- **Swift 5.9** + **SwiftUI**
- **AppKit** (NSStatusBar, NSPopover)
- **多种 AI API**（DeepSeek / MiniMax / Opencode / Google AI Studio）(AI 摘要)
- 零外部依赖

## License

MIT
