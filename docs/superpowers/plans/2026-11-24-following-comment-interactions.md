# Following Comment Interactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `subagent-driven-development` or `executing-plans`. Steps use checkbox syntax for tracking.

**Goal:** 在关注阅读器里补上评论点赞、评论回复和评论图片；点赞/回复必须等真实桌面请求抓包后才能进入生产代码，评论图片必须先确认桌面评论 payload 带 `pic_ids`。

**Architecture:** 读侧沿用现有 `FollowingReaderPane` / `WeiboCommentController`；写侧新增独立 `WeiboInteractionService`（独立 session、XSRF 轮换、写失败分类）和 `WeiboWriteGate`（串行、间隔、配额、冷却），通过独立 `WeiboCommentActing` 协议注入控制器，避免污染读测试。评论图片复用 `FollowingReaderImageSheet`。popover 的关注入口改为「有账号即显示」，未读只决定数字和蓝点。

**Tech Stack:** Swift 5.9、SwiftUI、macOS 15、SwiftPM、XCTest。

**Baseline:** `v3.5.1` / `11fb2e2`，分支 `feat/comment-interactions`。

**Decision log (user-approved):**

- 范围：评论点赞 + 评论回复；不含博文点赞/转发。
- 互动默认关闭 + 首次确认。
- 评论图片仅在 `pic_ids` 验证通过后做；否则降级「打开原网页」。
- 发版：`v3.6.0`（minor）。

---

## 0. 当前状态（2026-11-24）

### 已完成并有代码

- [x] popover 关注入口：`weiboMonitorShowPopoverChip` 开启且至少一个监控账号时，未读 0 也显示中性「关注」；未读 > 0 且角标开启显示「关注 N」+ 蓝点；角标关闭无数字/蓝点。
- [x] `WeiboWriteCapability`：`ready` / `missingXSRF` / `mobileOnly` / `signedOut`，基于桌面 `SUB` + `XSRF-TOKEN` 的纯 header 判定；不发起请求、不打印 Cookie。
- [x] 设置字段：`weiboCommentInteractionsEnabled` 默认 false、`weiboCommentInteractionsAckAt` 默认 nil；**未**在设置 UI 暴露开关。
- [x] 抓包清单：`docs/following-comment-interactions-capture.zh-CN.md`。
- [x] 评论图片只读核查：仓库内没有桌面评论 payload 的 `pic_ids` / `pic_infos` / `pics` 证据；缓存只存解析后的 `WeiboComment`，无法回答该问题。**未实现评论图片**，不猜字段。

### 未完成，被硬闸门挡住

- [ ] Phase 1：真实点赞/取消赞 + 回复请求抓包。
- [ ] Phase 2：评论图片解析 + 缩略图 + 灯箱（取决于 Phase 1 的 payload 验证）。
- [ ] Phase 3：写服务 + 频控 + 评论点赞。
- [ ] Phase 4：回复 composer + 回显/草稿。
- [ ] Phase 5：动作条、composer、可访问性、渲染矩阵。
- [ ] Phase 6：全量测试 + v3.6.0 发版。

### 本轮证据

- `swift test --filter "WeiboWriteCapabilityTests|WeiboCommentInteractionSettingsTests|PopoverLayoutRenderingTests"` → 16 tests / 0 failures。
- 全量 `swift build` / `swift test` / agent render 结果见本文件末尾「本轮验证记录」。

### 本轮未做（明确原因）

- 点赞/回复：没有真实请求证据；读 session `ephemeral` + `httpShouldSetCookies = false`，写响应的 `Set-Cookie`/XSRF 轮换会被丢弃；`WeiboRiskSignal` 把 403 判成 `rateLimited`，写侧不能复用。
- 评论图片：没有桌面评论 payload 的 `pic_ids` 证据；`WeiboCommentParser` 当前只解析作者/正文/likeCount/runs，缓存也只有解析后字段。

---

## 1. 范围

### In

- 评论点赞/取消赞。
- 回复博文 / 回复某条评论。
- 评论图片（仅验证通过后）。
- 评论行动作条、composer、草稿、回显、错误态。
- 设置、首次确认、能力状态、频控说明。
- popover 中性关注入口。
- 单测、渲染测试、Agent CLI 验收。

### Out

- 博文点赞/转发（不同端点）。
- 子回复层级（无数据源）。
- 评论编辑/删除、图片上传。
- 后台自动点赞/回复、失败自动重试。
- 频控参数开放编辑。

---

## 2. 分期与闸门

| 阶段 | 内容 | 人日 | 状态 |
|---|---|---|---|
| Phase 0 | 能力探测 + popover 中性入口 + 设置骨架 | 0.5 | 本轮完成 |
| Phase 1 | 抓真实点赞/取消赞 + 回复 + 含图评论 payload | 1.5 | **待用户提供** |
| Phase 2 | 评论图片解析 + 缩略图 + 灯箱 | 2.0 | 等 Phase 1 |
| Phase 3 | 写服务 + 频控 + 评论点赞 | 3.0 | 等 Phase 1 |
| Phase 4 | 回复 composer + 回显/草稿 | 3.5 | 等 Phase 3 |
| Phase 5 | UI/可访问性/渲染矩阵 | 1.5 | 等 Phase 4 |
| Phase 6 | 全量测试 + v3.6.0 发版 | 1.5 | 等 Phase 5 |

**Phase 1 是硬闸门。** 抓不到就不写点赞/回复代码；只交付 Phase 0 和可验证的读侧改动。

---

## 3. 技术方案

### 3.1 写能力（本轮已实现）

`Sources/NewsBar/Models/WeiboWriteCapability.swift`

```swift
enum WeiboWriteCapability: String, Equatable, Sendable, CaseIterable {
    case ready
    case missingXSRF
    case mobileOnly
    case signedOut
}
```

- 桌面 `SUB` + `XSRF-TOKEN` 都存在 → `.ready`。
- 有 `SUB`、无 `XSRF-TOKEN` → `.missingXSRF`。
- 只有 `m.weibo.cn` 的 `SUB` → `.mobileOnly`。
- 否则 `.signedOut`。
- header 是事实来源；`hasDesktopLogin` 只作为展示状态，不再单独决定写能力。
- `WeiboCookieHeader.value(named:in:)` 只判断存在性和取非空值，不记录值。

### 3.2 写服务（未实现，等抓包）

`Sources/NewsBar/Services/WeiboMonitor/WeiboInteractionService.swift`（新增）

- 独立 `URLSessionConfiguration.ephemeral`，`httpShouldSetCookies = false`，`httpMaximumConnectionsPerHost = 1`。
- 每次响应解析 `Set-Cookie`，维护 `xsrfOverride`；请求头 `x-xsrf-token` 优先级 `override > vault`。
- 独立 `WeiboCommentActing` 协议，**不扩展** `WeiboCommentFetching`，避免读测试实现写方法。
- 候选端点（**抓包前全部 unverified**）：
  - `POST https://weibo.com/ajax/comments/like`
  - `POST https://weibo.com/ajax/comments/create`
- 请求头：`Cookie`、`x-xsrf-token`、`Referer`（`https://weibo.com/{uid}/{bid}`）、`Origin`、`X-Requested-With: XMLHttpRequest`。
- 写失败分类：
  - 403 → `.csrfRejected`
  - 418/429/432 → `.rateLimited(retryAfter)`
  - 200 + HTML → `.challenge`
  - `ok:-100` / login URL → `.notSignedIn`
  - 5xx/网络 → `.transient`（只手动重试）

### 3.3 频控闸门（未实现）

`Sources/NewsBar/Services/WeiboMonitor/WeiboWriteGate.swift`（新增）

| 项 | 值 |
|---|---|
| 并发 | 1 |
| 最小间隔 | 2.5s |
| 点赞 | 12 次/小时 |
| 回复 | 6 次/小时 |
| 全局 | 15 次/小时 |
| 连续失败 ≥2 | 10 分钟冷却 |
| 限流 | max(Retry-After, 30 分钟) |
| challenge | 24 小时 |

`now` 可注入；参数硬编码，不进设置。

### 3.4 模型与控制器（未实现）

`WeiboComment` 只加 Optional：

```swift
var imageURLs: [String]?     // nil = 未知，[] = 明确无图
```

`WeiboCommentThread` 会话内字段（不落缓存）：

```swift
var likeOverlay: [String: Bool] = [:]
var likeBusy: Set<String> = []
var echoes: [WeiboCommentEcho] = []
var draft: String = ""
var draftTargetCommentID: String?
var writeIssue: WeiboWriteIssue?
```

`WeiboCommentController` 新增：

- `toggleLike(comment:post:)`
- `submitReply(text:targetCommentID:post:)`
- `setDraft` / `cancelComposer`
- `postWriteQuietUntil`（写成功后 15s 内跳过强制刷新）

点赞：乐观翻转 + 计数；成功用服务端值；网络失败保留乐观值 +「未确认」；CSRF/未登录回滚 + 只读；限流/challenge 回滚 + 冷却；不自动重试。

回复：`echo(.sending)` → 成功有评论对象则插入；成功无对象则「已发送，刷新可见」；失败恢复草稿 + 错误；不自动重试。

**overlay / echo / draft 不写入缓存**；缓存 schema 不变。

### 3.5 UI（未实现）

- 评论行动作条：点赞常显（`hand.thumbsup` + 计数，已赞 accent）；回复在 hover/键盘焦点/右键菜单可达；更多菜单保留复制/打开原网页。
- 评论行不包在 `Button` 里（链接必须可点）；可访问性 `.contain`，不 `.combine`。
- Composer：讨论区标题「写评论」打开顶部 composer；评论「回复」打开该评论下方就地 composer；140 字、计数、`⌘↩`、取消/发送、错误内联；草稿按 `mid` + 目标评论保存。
- 回复回显：发送中 / 已发送，刷新可见 / 失败 + 草稿恢复。
- 不可写状态：按钮禁用 + 帮助文案 + 设置入口；缺 XSRF 时提示「在阅读器打开 weibo.com 刷新登录」。

### 3.6 评论图片（未实现，先验证）

- 解析 `pic_ids` / `pic_infos` / `pics`；只接受 `https` + `sinaimg.cn`；最多 9 张。
- `<img>` 继续只取 `alt` 当表情文本。
- 1–3 张缩略图 + `+N`；复用 `FollowingReaderImageSheet`。
- **Gate 0**：先抓一页真实桌面评论 JSON，确认字段；没有就砍掉，降级「打开原网页」。

### 3.7 popover 关注入口（本轮已实现）

- `PopoverWeiboFollowChip.shouldShowEntry(settingEnabled:accountCount:)`：设置开启且账号数 > 0 才显示。
- 未读 0 → 中性「关注」，无数字/蓝点。
- 未读 > 0 且角标开启 → 「关注 N」+ 蓝点。
- 角标关闭 → 中性「关注」，无数字/蓝点。
- 保留原有打开关注流动作；modern/retro/compact 沿用现有材质。

### 3.8 设置（本轮只加模型字段）

- `weiboCommentInteractionsEnabled` 默认 false。
- `weiboCommentInteractionsAckAt` 默认 nil。
- **不暴露 UI 开关**，直到写服务可用。
- 后续设置组：允许点赞/回复、首次确认、能力状态（ready / missingXSRF / mobileOnly / signedOut）、频控说明。

---

## 4. 文件级改动

**本轮已改**

| 文件 | 改动 |
|---|---|
| `Sources/NewsBar/Views/MenuBar/PopoverWeiboFollowChip.swift` | 有账号即显示；未读 0 中性；`shouldShowEntry` |
| `Sources/NewsBar/Views/MenuBar/PopoverContent.swift` | 入口条件改为设置 + 账号数 |
| `Sources/NewsBar/Models/WeiboWriteCapability.swift` | **新增** 能力判定 |
| `Sources/NewsBar/Models/AppSettings.swift` | 两个默认关闭字段 |
| `Tests/NewsBarTests/PopoverLayoutRenderingTests.swift` | 中性入口、0 未读、可见性测试 |
| `Tests/NewsBarTests/WeiboWriteCapabilityTests.swift` | **新增** |
| `Tests/NewsBarTests/WeiboCommentInteractionSettingsTests.swift` | **新增** |
| `docs/following-comment-interactions-capture.zh-CN.md` | **新增** 抓包清单 |

**后续（等闸门）**

- `Services/WeiboMonitor/WeiboInteractionService.swift`（新）
- `Services/WeiboMonitor/WeiboWriteGate.swift`（新）
- `Services/WeiboMonitor/WeiboCommentController.swift`
- `Services/WeiboMonitor/WeiboMonitorViewModel.swift`
- `Models/WeiboComment.swift`
- `Services/WeiboMonitor/WeiboCommentParser.swift`
- `Views/Dashboard/FollowingReaderPane.swift`
- `Views/Dashboard/FollowingCommentComposer.swift`（新）
- `Views/Settings/WeiboMonitorTab.swift`
- `Models/Localized.swift`
- 对应测试与渲染 fixture

---

## 5. 测试与验收

### 本轮已跑

- `swift test --filter "WeiboWriteCapabilityTests|WeiboCommentInteractionSettingsTests|PopoverLayoutRenderingTests"` → 16 / 0 failures。
- 全量 build/test/agent render 结果见「本轮验证记录」。

### 后续

- 解析：`runs`、`sinaurl`、`<img>` alt、评论图片（如启用）、旧缓存缺新字段可解码。
- 写服务：`URLProtocol` 必须读 `httpBodyStream`（`httpBody` 为 nil）；XSRF `%3D` 解码；`Set-Cookie` 轮换；403 / 418 / 429 / 200 HTML；`Retry-After`。
- Gate：假时钟下的间隔、配额、冷却、连续失败。
- Controller：重复点击只发一次、成功/失败回滚、网络未确认、回复草稿/回显/失败恢复、overlay/echo 不落缓存。
- 渲染：未赞/已赞/未确认/限流禁用；composer 空/输入/超限/发送中/失败；图片 0/1/3/9；720/900/1180；现代/暗色/复古；reduce motion；键盘。
- Agent CLI：扩展 `render-reader` fixture；`check` / `store-summary` 保持通过。

### 发版前

- `swift build`、`swift test` 全量 0 失败。
- `scripts/agent-test.sh --tier all` 全绿。
- 签名构建、DMG、appcast、差分、Release 验收（v3.6.0 minor）。

---

## 6. 风险与回滚

| 风险 | 处理 |
|---|---|
| 写端点抓不到 | Phase 1 停止；只交付 Phase 0 + 可验证读侧 |
| 账号被验证/限流 | 默认关闭、首次确认、串行、2.5s、配额、无自动重试、24h challenge 冷却 |
| XSRF 轮换 | 写服务解析 `Set-Cookie`；缺失禁用写并引导刷新登录 |
| 回复响应无对象 | echo「已发送，刷新可见」，不伪造评论 ID |
| 评论图片无 `pic_ids` | 砍掉图片，降级打开原网页 |
| 缓存兼容 | 只加 Optional；overlay/echo 不落盘；旧 JSON 解码测试 |
| UI 链接/按钮冲突 | 评论行不包 Button；`.contain` 可访问性 |
| 性能 | 解析在 actor；`LazyVStack`；图片共享缓存 |

**回滚：** `weiboCommentInteractionsEnabled = false` 关闭写入口；读侧、图片、链接不受影响；无 store migration。

---

## 7. 下一步需要用户提供

1. 按 `docs/following-comment-interactions-capture.zh-CN.md` 抓一次：
   - 评论点赞 + 取消赞；
   - 回复博文/评论；
   - 含图评论列表 payload。
2. 交付脱敏后的 HAR 或最小 JSON（不要 Cookie 值）。
3. 抓包通过后进入 Phase 2/3；失败则只合并 Phase 0。

---

## 8. 本轮验证记录

- **目标测试**：
  `swift test --filter "WeiboWriteCapabilityTests|WeiboCommentInteractionSettingsTests|PopoverLayoutRenderingTests"`
  → 16 tests / 0 failures。
- **构建**：`swift build` → `Build complete! (4.13s)`。
- **全量测试**：`swift test` → **2036 tests / 6 skipped / 0 failures**（最近一次 105.60s；早前冷构建 380.38s 同样 0 失败）；本轮无既有抖动，无需单独复跑。
- **Agent render**：`bash scripts/agent-test.sh --tier render --no-build` → `Result: PASS`（5 render tests；render-modern / render-retro / render-narrow 全通过）。
  - 日志目录：`.build/agent-test/20261124-114142/`
  - 截图：
    - `.build/agent-test/20261124-114142/reader-modern-zh.png`
    - `.build/agent-test/20261124-114142/reader-retro-zh.png`
    - `.build/agent-test/20261124-114142/reader-960-modern-zh.png`
- **工作区**：未 commit / 未 push / 未 release；`git status` 为 4 个修改 + 5 个新增文件（实现、测试、两份文档）。
- **未验证**：点赞/回复写请求、评论图片 `pic_ids` 的真实桌面 payload；原因见第 0 节与抓包清单。

