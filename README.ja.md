# NewsBar

> 静かな macOS メニューバーニュースアグリゲーター — 微博（Weibo）トレンド、B站（Bilibili）トレンド、カスタム RSS フィードを一目で確認。

<p align="center">
  <strong>🌐 言語</strong> ·
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
  <a href="#-言語">日本語</a> ·
  <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/macOS-15.0%2B-blue" alt="macOS 15.0+">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License">
  <img src="https://img.shields.io/badge/Platforms-macOS-lightgrey" alt="Platforms: macOS">
</p>

**NewsBar** は SwiftUI で作られた**ネイティブ macOS メニューバー / ステータスバーニュースアプリ**です。**微博（Weibo）トレンド**、**B站（Bilibili）トレンド**、**独自の RSS フィード**を、静かで一目でわかるメニューバーパネルに集約します。オプションの**AI 要約**が、一日の情報ノイズを引用付きの精読ブリーフィングに変えます。

依存ゼロ。純 Swift。無料・オープンソース（MIT）。

---

## ✨ 機能

- **🔥 Weibo トレンド** — リアルタイムの微博ホット検索トピック
- **📺 Bilibili トレンド** — Bilibili の人気・トレンドコンテンツ
- **📡 カスタム RSS フィード** — 任意の RSS/Atom ソースを追加、完全に拡張可能
- **🤖 AI 要約** — Popup と Dashboard で共有される二カテゴリのブリーフィング（トレンド概要 / デイリーエッセンシャル）。引用付きの行をクリックすると元記事を開きます。**二層スマートトリガー**：通常は「前回の要約から ≥ 1 時間」を基準とし、微博に「爆」ラベルのトピックが現れると**即時に要約を生成**し、その爆ラベルトピックを【トレンド概要】に優先表示します。爆ラベル要約は 15 分に 1 回までに抑制されます。
- **📊 エディトリアルダッシュボード** — レスポンシブヘッダー、共有 AI ブリーフィング、刷新したトレンドカード、個別更新操作付きのソース別 RSS レイアウト
- **⏱ 適応型スマート更新** — 起動時フェッチ + 可視性に応じたトレンドポーリング + 適応型 RSS 間隔
- **🔄 自動更新** — GitHub Releases のチェック、ワンクリックダウンロード
- **🔐 安全な保存** — API キーは AES-256-GCM で暗号化され、デバイスに紐付け
- **📰 レトロ新聞テーマ** — 1960 年代のエディトリアルデザイン：紙の質感、赤煉瓦色のアクセント、スクエアな切り抜きカード、印刷風のソースマーク
- **🪟 モダンマテリアルテーマ** — ネイティブ SwiftUI マテリアル外観と明確なエディトリアルページヘッダー
- **🌓 ダークモード** — ライト / ダーク / システム追従、リアルタイム切替
- **📦 依存ゼロ** — 純 Swift、サードパーティライブラリなし

---

## 📦 インストール

[Releases](../../releases) から最新の DMG をダウンロードし、**Applications** にドラッグします。

> **macOS 15.0+** が必要

## 🚀 使い方

1. **メニューバーアイコン**をクリックしてニュースパネルを開く
2. 任意のニュース項目をクリックしてブラウザで開く
3. **引用付き AI 要約の行**は常駐のソースバッジを表示し、クリックで元記事を開く
4. 上部の**更新を確認**をクリックして手動で新バージョンをチェック
5. 下部の ⚙️ をクリックして設定を開き、RSS ソースと AI を設定
6. 📊 をクリックして **Dashboard** を開き、完全なニュースビューを表示：トレンドカード、AI ブリーフィングパネル、固定二段グリッドのソース別 RSS 領域
7. 「設定 → 一般 → テーマ」で**モダンマテリアル**または**レトロ新聞**テーマを切替
8. 設定パネル下部で終了

> Popup と Dashboard は、グローバル更新後に生成される 1 つの詳細な AI ブリーフィングを共有します。Popup は各カテゴリ最大 2 行、Dashboard は全結果を表示します。Dashboard には独立した AI 更新ボタンもあります。

---

## 🤖 AI 要約を有効にする

設定 → **AI** タブ：プロバイダーを選択し API キーを入力。対応プロバイダー：**DeepSeek**、**MiniMax**、**Opencode Go/Zen**、**Google AI Studio**、**Ollama Cloud**、および**ユーザー定義プロバイダー**（エンドポイント、モデル ID、認証ヘッダー）。

Popup と Dashboard は要約長プリセット（デフォルト 360 語）と 1 日あたりのリクエスト上限（デフォルト 50、20/50/100 から選択）を共有します。自動要約は 12/24 時間のトレンド履歴を使用し、有意な変化とクールダウン条件を満たした場合のみ再生成します。Dashboard の AI ボタンで強制的に独立再生成できます。

### 対応 AI プロバイダー

| Provider | Endpoint | Models |
|---|---|---|
| DeepSeek | api.deepseek.com | deepseek-v4-flash, deepseek-v4-pro |
| MiniMax | api.minimaxi.com | MiniMax-M3, MiniMax-M2.7, MiniMax-M2.7-highspeed, MiniMax-M2.5, MiniMax-M2.5-highspeed, MiniMax-M2.1, MiniMax-M2.1-highspeed, MiniMax-M2 |
| Opencode Go | open-code-go.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Opencode Zen | open-code-zen.aiizhi.com | deepseek-v4-flash, deepseek-v4-pro |
| Google AI Studio | generativelanguage.googleapis.com | gemini-3.6-flash, gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.1-flash-lite, gemini-3.1-pro-preview, gemini-3-flash-preview, gemini-2.5-pro, gemini-2.5-flash, gemini-2.5-flash-lite |
| Ollama Cloud | ollama.com | deepseek-v4-flash:cloud, deepseek-v4-pro:cloud, gpt-oss:20b-cloud, gpt-oss:120b-cloud, kimi-k3:cloud, minimax-m3:cloud, ... |
| Custom | ユーザー定義 | カスタムエンドポイント / モデル ID |

> **モデル折りたたみ**：デフォルトでは各プロバイダーの DeepSeek 系モデルのみ表示（あれば）。「一般 → 開発者オプション」で「すべての AI モデルを表示」を有効にすると全公式モデルを確認できます。

---

## 🛠 開発

```bash
# ビルド
swift build -c release --arch arm64

# または公式パッケージスクリプト（App + DMG をビルド）
bash scripts/build.sh
```

### リリース手順

```bash
# 1. まず release/vX.Y.Z で version.txt と RELEASE_NOTES.md を更新
swift test                    # 全テストスイートを実行
bash scripts/build.sh         # 公式 App と DMG をパッケージ
# 2. main に PR を提出し、必要な CI が通るまで待ってマージ
git tag -a vX.Y.Z -m "vX.Y.Z — summary"
git push origin vX.Y.Z
bash scripts/release.sh       # GitHub Release + DMG/SHA256 アップロード
```

PR・CI・マージ・タグ付け・検証の完全なワークフローは [docs/release-conventions.md](docs/release-conventions.md) を参照してください。

---

## 📂 プロジェクト構造

```text
Sources/NewsBar/
├── main.swift              # エントリポイント、単一インスタンスチェック
├── AppDelegate.swift       # ステータスバー、popover、ウィンドウ管理
├── Models/
│   ├── AIProvider.swift        # マルチプロバイダー AI 定義
│   ├── NewsItem.swift          # ニュース項目モデル（微博ホットラベル含む）
│   ├── NewsSource.swift        # ソース列挙（微博/B站/RSS）
│   ├── AppSettings.swift       # ユーザー設定（Observable）
│   ├── CacheEntry.swift        # キャッシュエントリ
│   └── UpdateInfo.swift        # Release/バージョンモデル
├── Services/
│   ├── NewsOrchestrator.swift  # 中核コーディネーター：更新・キャッシュ・共有 AI ステートマシン
│   ├── UpdateChecker.swift     # GitHub 更新チェック + DMG ダウンロード
│   ├── WeiboHotService.swift   # 微博トレンドフェッチャー
│   ├── BilibiliHotService.swift# B站トレンドフェッチャー
│   ├── RSSService.swift        # RSS/Atom パーサー
│   ├── AISummaryService.swift  # AI 要約（マルチプロバイダー）
│   ├── CacheManager.swift      # ファイルキャッシュ（actor）
│   ├── KeychainManager.swift   # 非推奨 — ワンタイム移行用のみ
│   ├── EncryptedKeyStore.swift # AES-256-GCM 暗号化ファイルストレージ
│   ├── RateLimiter.swift       # レートリミッター（actor）
│   ├── RefreshLog.swift        # 更新ログ（actor、リングバッファ）
│   └── SecurityPolicies.swift  # URL/サニタイズ/XML 安全性
├── Views/
│   ├── MenuBar/                # popover コンポーネント（コンパクトな共有 AI ブリーフィング）
│   ├── Settings/               # 設定ウィンドウタブ
│   ├── Dashboard/              # Dashboard ウィンドウ、完全 AI ブリーフィング + ソース別更新
│   └── Theme/                  # モダンマテリアル / レトロ新聞プリミティブ
└── Extensions/
    ├── URLOpener.swift          # 安全な URL オープン
    └── View+Glass.swift         # ガラス効果 + 適応型カラースキーム
```

---

## ⚙️ 技術スタック

- **Swift 5.9** + **SwiftUI** (macOS 15.0+)
- **AppKit**: NSStatusBar, NSPopover
- **AI APIs**: DeepSeek / MiniMax / Opencode / Google AI Studio / Ollama Cloud / カスタム
- **ストレージ**: 暗号化ファイル（AES-256-GCM, CryptoKit）、UserDefaults、ファイルキャッシュ（actor）
- **外部依存ゼロ**

---

## 🔍 キーワード

`macOS メニューバーアプリ` · `ステータスバーアプリ` · `メニューバーニュース` · `ニュースアグリゲーター` · `SwiftUI` · `Swift` · `ネイティブ macOS アプリ` · `AI 要約` · `微博トレンド` · `B站トレンド` · `RSS リーダー` · `RSS アグリゲーター` · `トレンドトピック` · `DeepSeek` · `Gemini` · `MiniMax` · `Ollama` · `メニューバー` · `オープンソース`

---

## 🔗 関連リンク

- [Releases](../../releases)
- [微博トレンド API](https://s.weibo.com)
- [B站トレンド API](https://www.bilibili.com)
- [DeepSeek Platform](https://platform.deepseek.com)
- [MiniMax Platform](https://platform.minimaxi.com)
- [Google AI Studio](https://aistudio.google.com)
- [Ollama Cloud](https://ollama.com)

---

## 📄 ライセンス

MIT © 2024-2026 [blackkcold](https://github.com/blackkcold) and contributors.
詳細は [LICENSE](LICENSE) を参照してください。

---

## 🌐 言語

- [English](README.md)
- [简体中文](README.zh-CN.md)
- [繁體中文](README.zh-TW.md)
- **日本語** — このファイル
- [한국어](README.ko.md)
