# NewsBar

> 一款安靜的 macOS 選單列新聞聚合器 — 微博熱搜、B站熱搜、自訂 RSS，一目了然。

<p align="center">
  <strong>🌐 語言</strong> ·
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="#-語言">繁體中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/macOS-15.0%2B-blue" alt="macOS 15.0+">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License">
  <img src="https://img.shields.io/badge/Platforms-macOS-lightgrey" alt="Platforms: macOS">
</p>

**NewsBar** 是一款基於 SwiftUI 的**原生 macOS 選單列 / 狀態列新聞應用**。它將**微博熱搜**、**B站熱搜**與**你自己的 RSS 訂閱源**匯聚到一個安靜、一目瞭然的選單列面板中。可選**AI 智慧摘要**將一天的資訊噪音整理成帶引用的精讀簡報。

零依賴。純 Swift。免費開源（MIT）。

---

## ✨ 功能特色

- **🔥 微博熱搜** — 即時微博熱搜話題
- **📺 B站熱搜** — B站熱門內容與熱搜
- **📡 自訂 RSS 訂閱** — 添加任意 RSS/Atom 源，完全可擴展
- **🤖 AI 摘要** — 一份共享的雙分類簡報（趨勢概覽 / 每日精選），同時服務於 Popup 與 Dashboard；帶引用的列點擊可開啟原文。**兩層智慧觸發**：常態以「距上次總結 ≥ 1 小時」為基準，識別到微博「爆」標籤話題時**立即觸發**總結，並強制將爆標籤話題納入【趨勢概覽】優先展示；爆標籤成功總結後 15 分鐘內不重複觸發。
- **📊 編輯式儀表板** — 響應式抬頭、共享 AI 簡報、重製的趨勢卡片，以及帶獨立重新整理操作的按來源 RSS 版面
- **⏱ 自適應智慧重新整理** — 啟動抓取 + 可見性感知的熱搜輪詢 + 自適應 RSS 節奏
- **🔄 自動更新** — 檢查 GitHub Releases，一鍵下載
- **🔐 安全儲存** — API Key 使用 AES-256-GCM 加密，綁定裝置
- **📰 復古報刊主題** — 可選 1960 年代編輯風設計：紙張紋理、磚紅點綴、方形剪報卡片、印刷風來源徽記
- **🪟 現代材質主題** — 原生 SwiftUI 材質外觀，搭配清晰的編輯式頁面抬頭
- **🌓 深色模式** — 淺色 / 深色 / 跟隨系統，即時切換
- **📦 零依賴** — 純 Swift，無第三方函式庫

---

## 📦 安裝

從 [Releases](../../releases) 下載最新 DMG，拖入 **Applications** 即可。

> 需要 **macOS 15.0+**

## 🚀 使用說明

1. 點擊**選單列圖示**展開新聞面板
2. 點擊任意新聞條目在瀏覽器中開啟
3. **帶引用的 AI 摘要列**顯示常駐來源角標，點擊跳轉原文
4. 點擊頂部**檢查更新**手動檢查新版本
5. 點擊底部 ⚙️ 開啟設定，設定 RSS 源與 AI 摘要
6. 點擊 📊 開啟 **Dashboard** 檢視完整新聞：熱點趨勢卡片、AI 簡報面板，以及固定雙欄網格的按來源 RSS 區域
7. 在「設定 → 一般 → 主題」切換**現代材質**或**復古報刊**主題
8. 在設定面板底部結束

> Popup 與 Dashboard 複用全域重新整理後產生的一份詳細 AI 簡報。Popup 每類最多顯示兩條，Dashboard 顯示完整結果。Dashboard 另提供獨立的 AI 重新整理按鈕。

---

## 🤖 啟用 AI 摘要

設定 → **AI** 標籤頁：選擇 AI 供應商並填入 API Key。支援 **DeepSeek**、**MiniMax**、**Opencode Go/Zen**、**Google AI Studio**、**Ollama Cloud**，以及**使用者自訂供應商**（端點、模型 ID、認證標頭）。

Popup 和 Dashboard 共用一個摘要長度預設（預設 360 字）與每日 AI 呼叫上限（預設 50，可選 20/50/100）。自動總結結合近 12/24 小時趨勢歷史，僅在顯著變化及冷卻條件滿足時重建；Dashboard 的 AI 按鈕仍可強制獨立重新整理摘要。

### 支援的 AI 供應商

| Provider | Endpoint | Models |
|---|---|---|
| DeepSeek | api.deepseek.com | deepseek-v4-flash, deepseek-v4-pro |
| MiniMax | api.minimaxi.com | MiniMax-M3, MiniMax-M2.7, MiniMax-M2.7-highspeed, MiniMax-M2.5, MiniMax-M2.5-highspeed, MiniMax-M2.1, MiniMax-M2.1-highspeed, MiniMax-M2 |
| Opencode Go | open-code-go.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Opencode Zen | open-code-zen.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Google AI Studio | generativelanguage.googleapis.com | gemini-3.6-flash, gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.1-flash-lite, gemini-3.1-pro-preview, gemini-3-flash-preview, gemini-2.5-pro, gemini-2.5-flash, gemini-2.5-flash-lite |
| Ollama Cloud | ollama.com | deepseek-v4-flash:cloud, deepseek-v4-pro:cloud, gpt-oss:20b-cloud, gpt-oss:120b-cloud, kimi-k3:cloud, minimax-m3:cloud, ... |
| Custom | 使用者自訂 | 自訂端點 / 模型 ID |

> **模型摺疊**：預設僅顯示各供應商的 DeepSeek 系模型（若有）；在「一般 → 開發者選項」開啟「顯示全部 AI 模型」可檢視該供應商全部官方模型。

---

## 🛠 開發

```bash
# 建置
swift build -c release --arch arm64

# 或使用官方打包腳本（建置 App + DMG）
bash scripts/build.sh
```

### 發布流程

```bash
# 1. 先在 release/vX.Y.Z 更新 version.txt 與 RELEASE_NOTES.md
swift test                    # 執行全量測試
bash scripts/build.sh         # 官方 App 與 DMG 打包
# 2. 向 main 提交 PR，等待必需 CI 通過後合併
git tag -a vX.Y.Z -m "vX.Y.Z — summary"
git push origin vX.Y.Z
bash scripts/release.sh       # GitHub Release + DMG/SHA256 上傳
```

完整的 PR、CI、合併、打標籤與驗證流程見 [docs/release-conventions.md](docs/release-conventions.md)。

---

## 📂 專案結構

```text
Sources/NewsBar/
├── main.swift              # 入口點、單實例檢查
├── AppDelegate.swift       # 狀態列、popover、視窗管理
├── Models/
│   ├── AIProvider.swift        # 多供應商 AI 定義
│   ├── NewsItem.swift          # 新聞條目模型（含微博熱搜標籤）
│   ├── NewsSource.swift        # 來源列舉（微博/B站/RSS）
│   ├── AppSettings.swift       # 使用者設定（Observable）
│   ├── CacheEntry.swift        # 快取條目
│   └── UpdateInfo.swift        # Release/版本模型
├── Services/
│   ├── NewsOrchestrator.swift  # 核心協調器：重新整理、快取、共享 AI 狀態機
│   ├── UpdateChecker.swift     # GitHub 更新檢查 + DMG 下載
│   ├── WeiboHotService.swift   # 微博熱搜抓取
│   ├── BilibiliHotService.swift# B站熱搜抓取
│   ├── RSSService.swift        # RSS/Atom 解析
│   ├── AISummaryService.swift  # AI 摘要（多供應商）
│   ├── CacheManager.swift      # 檔案快取（actor）
│   ├── KeychainManager.swift   # 已棄用 — 僅用於一次性遷移
│   ├── EncryptedKeyStore.swift # AES-256-GCM 加密檔案儲存
│   ├── RateLimiter.swift       # 限速器（actor）
│   ├── RefreshLog.swift        # 重新整理日誌（actor，環形緩衝）
│   └── SecurityPolicies.swift  # URL/清洗/XML 安全
├── Views/
│   ├── MenuBar/                # 複用 popover 元件，緊湊共享 AI 簡報
│   ├── Settings/               # 設定視窗標籤頁
│   ├── Dashboard/              # Dashboard 視窗、完整 AI 簡報 + 按來源重新整理
│   └── Theme/                  # 現代材質 / 復古報刊原語
└── Extensions/
    ├── URLOpener.swift          # 安全 URL 開啟
    └── View+Glass.swift         # 玻璃效果 + 自適應配色
```

---

## ⚙️ 技術堆疊

- **Swift 5.9** + **SwiftUI** (macOS 15.0+)
- **AppKit**: NSStatusBar, NSPopover
- **AI APIs**: DeepSeek / MiniMax / Opencode / Google AI Studio / Ollama Cloud / 自訂
- **儲存**: 加密檔案（AES-256-GCM, CryptoKit）、UserDefaults、檔案快取（actor）
- **零外部依賴**

---

## 🔍 關鍵字

`macOS 選單列應用` · `狀態列應用` · `選單列新聞` · `新聞聚合器` · `SwiftUI` · `Swift` · `原生 macOS 應用` · `AI 摘要` · `微博熱搜` · `B站熱搜` · `RSS 閱讀器` · `RSS 聚合` · `熱搜話題` · `DeepSeek` · `Gemini` · `MiniMax` · `Ollama` · `選單列` · `開源`

---

## 🔗 相關連結

- [Releases](../../releases)
- [微博熱搜 API](https://s.weibo.com)
- [B站熱搜 API](https://www.bilibili.com)
- [DeepSeek Platform](https://platform.deepseek.com)
- [MiniMax Platform](https://platform.minimaxi.com)
- [Google AI Studio](https://aistudio.google.com)
- [Ollama Cloud](https://ollama.com)

---

## 📄 授權

MIT © 2024-2026 [blackkcold](https://github.com/blackkcold) and contributors.
詳見 [LICENSE](LICENSE)。

---

## 🌐 語言

- [English](README.md)
- [简体中文](README.zh-CN.md)
- **繁體中文** — 本檔案
- [日本語](README.ja.md)
- [한국어](README.ko.md)
