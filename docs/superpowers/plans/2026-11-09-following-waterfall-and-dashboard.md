# Dashboard 关注瀑布流与首页看板增强 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让关注内容同时出现在“为你推荐”瀑布流和独立关注页，独立关注页支持筛选，首页右栏增加“关注最近消息”卡片，提醒角标只挂在“关注”页签上；同时修复浏览模式切换器的位置回归。

**Architecture:** 关注数据仍由 `WeiboMonitorViewModel` / `WeiboMonitorSnapshot` 持有；新增纯模型 `FollowingFeedModel` 负责扁平化、筛选、未读计数和最近消息选择；新增 `FollowingPostCard` + `FollowingMasonryFeed` 复用现有 `WaterfallLayout`。首页推荐流增加“关注动态”瀑布流区块，不混入兴趣排序；右栏新增 `FollowingRecentMessagesCard`。模式切换器改为自定义分段控件，把未读数做成“关注”段内角标。

**Tech Stack:** SwiftUI (macOS 15+), Swift Observation, SwiftPM, XCTest, existing `WaterfallLayout` / `RecommendationMasonryLayout` / `newsCardSurface` / `DashboardMotion`.

**Spec:** 本对话中的四条需求与上一轮 Dashboard 位置复核结论；无独立 spec 文件。

## Global Constraints

- 平台：macOS 15.0+；零新外部依赖。
- 不发版、不合并 PR #87，直到本计划确认并完成；当前 PR #87 为 draft，本机仍是 2.17.2。
- 不改 `WeiboMonitorService` 的抓取/存储/预算逻辑；只消费 `WeiboMonitorSnapshot`。
- 关注内容不进入 `InterestController` 的推荐排序，避免污染本地学习模型；推荐页用独立“关注动态”区块。
- 尊重三主题：modern light/dark、retroEditorial；所有新卡片必须走 `newsCardSurface` / `floatingPanelSurface` 或既有 editorial 组件。
- 可访问性：每张关注卡可被 VoiceOver 作为整体朗读；未读角标有 accessibility label；自定义分段控件保留键盘/选中语义。
- Reduce Motion：瀑布流与卡片 hover 走 `DashboardMotion` / `reduceMotion` 分支。
- 渲染测试只写 `.build/<area>-ui-validation/`，不提交 PNG；离屏不采样材质。
- 发版仍走 `release/vX.Y.Z` → PR → CI → 合并 → tag → `scripts/build.sh --adhoc` → `scripts/release.sh --allow-adhoc`。

## Review Focus

- 关注帖子很多、图片很多时的首屏性能：一次只渲染有限数量，图片走 `AsyncImage`/缓存，瀑布流用 LazyVStack。
- 空/未配置/未登录/暂停的关注监控：右栏卡片与独立关注页必须给出可理解的空态，不崩、不无限加载。
- 长文本、长英文单词、无图/多图/转发帖：瀑布流列宽不被撑破，卡片高度估算不导致明显错列。
- 760pt 阅读窗 / reader compact / 320–480pt 列表宽度：关注瀑布流退化为 1 列，模式切换器仍可达。
- 未读数语义：角标只在“关注”段；打开帖子/全部已读后计数下降；菜单栏与 Dashboard 角标分别可关闭（默认开启）。

---

## 设计决策（已确认）

| 主题 | 最终决策 |
|---|---|
| 关注内容进入推荐 | 独立“关注动态”瀑布流区块，放在“为你推荐”之前（6 条 + 查看全部），不混入兴趣排序 |
| 独立关注页 | 账号分组列表改为按时间倒序的全量瀑布流；每张卡自带账号身份；保留“被过滤”折叠区 |
| 关注页筛选 | 搜索 + 账号菜单 + 全部/未读/P0；第一版不加媒体/时间窗 |
| 右栏结构 | 01 AI 简报 → 02 热搜（微博 + B站 整合为一张卡）→ 03 关注最近消息；研究侧栏移除，研究入口保留在工具栏 |
| 热搜整合 | 一张“热搜”卡，卡内“微博 / B站”二段切换；保留 5 条折叠与展开全部；不再渲染两张独立热搜卡 |
| 右栏关注卡 | 5 条最近消息 + 未读 tag + “显示更多”；“显示更多”切到关注页并回到顶部 |
| 提醒角标 | 自定义三段控件；“关注”段内未读角标；其他模式也可见；不再有独立红色胶囊 |
| 角标开关 | 菜单栏角标、Dashboard 角标分开设置，均可关闭；默认开启 |
| 模式切换器位置 | 搜索栏下方：`DashboardFilterBar` 内，搜索框与来源 chips 之间；关注页放在其搜索框下方；不再有 ScrollView 外顶部常驻切换器 |
| 版本 | 补进 **2.17.3**（不新开 2.18.0） |

### 布局图示（文字线框）

```text
Dashboard 宽屏
┌──────────────────────────────────────────────────────────────────────┐
│ toolbar:  DASHBOARD · 趋势 / RSS / AI         刷新  AI  设置        │
├───────────────────────────────────────────────┬──────────────────────┤
│  NewsBar masthead                             │ 01 AI 简报           │
│  [ 搜索微博、B站热搜与 RSS 标题… ]             │                      │
│  [ 为你推荐 | 按源浏览 | 关注 ]  ← 角标只挂关注 │ 02 热搜              │
│  [ 全部 ][ 微博热搜 ][ B站热搜 ][ RSS ]        │  [ 微博 | B站 ]      │
│                                               │  … 5 行              │
│  关注动态                         [查看全部]  │  [展开全部]          │
│  ┌─────────┐ ┌─────────┐                      │                      │
│  │ 关注卡  │ │ 关注卡  │  ← 瀑布流 6 条        │ 03 关注最近消息      │
│  └─────────┘ └─────────┘                      │  … 5 行              │
│                                               │  [显示更多]          │
│  为你推荐                                     │                      │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐          │                      │
│  │ 推荐卡  │ │ 推荐卡  │ │ 推荐卡  │          │                      │
│  └─────────┘ └─────────┘ └─────────┘          │                      │
└───────────────────────────────────────────────┴──────────────────────┘

独立关注页
┌──────────────────────────────────────────────────────────────┐
│ 关注  监控 N 人 · 未读 M      [暂停] [全部已读] [检查全部]   │
│ [ 搜索关注动态… ]                                            │
│ [ 为你推荐 | 按源浏览 | 关注 ]  ← 搜索框下方                 │
│ [ 全部 ][ 未读 ][ 只看 P0 ]   [账号 ▾]   [N 条]             │
│ [被过滤的 N 条 ▸]                                            │
│ ┌─────────┐ ┌─────────┐ ┌─────────┐  ← 1–3 列瀑布流         │
│ │ 关注卡  │ │ 关注卡  │ │ 关注卡  │                          │
│ └─────────┘ └─────────┘ └─────────┘                          │
└──────────────────────────────────────────────────────────────┘

设置 → 关注监控 → 角标
[✓] 菜单栏未读角标
[✓] Dashboard 关注角标
```

### 数据流

```text
WeiboMonitorSnapshot
  ├─ postsByUID + users ──► FollowingFeedModel
  │     ├─ recentEntries(5) ──► FollowingRecentMessagesCard（右栏 03）
  │     ├─ recentEntries(6) ──► FollowingHighlightsSection（推荐页）
  │     └─ entries(query)  ──► FollowingMasonryFeed（独立关注页）
  └─ unreadCount ──► DashboardModeSegmentedControl（关注段角标）
                └──► WeiboMenuBarBadge（菜单栏，受独立开关控制）
```

---

## File Structure

**新增**
- `Sources/NewsBar/Models/FollowingFeedModel.swift` — 纯模型：扁平化、筛选、未读计数、最近消息。
- `Sources/NewsBar/Views/Dashboard/FollowingMasonryLayout.swift` — 关注卡片高度估算 + 列分配（可复用 `WaterfallLayout`）。
- `Sources/NewsBar/Views/Dashboard/FollowingPostCard.swift` — 关注帖子瀑布流卡片。
- `Sources/NewsBar/Views/Dashboard/FollowingMasonryFeed.swift` — 可复用瀑布流容器（推荐页区块 / 独立关注页）。
- `Sources/NewsBar/Views/Dashboard/FollowingHighlightsSection.swift` — 推荐页“关注动态”区块（6 条 + 查看全部）。
- `Sources/NewsBar/Views/Dashboard/FollowingRecentMessagesCard.swift` — 右栏“关注最近消息”卡片。
- `Sources/NewsBar/Views/Dashboard/DashboardIntegratedHotTrendCard.swift` — 微博 / B站 整合热搜卡。
- `Sources/NewsBar/Views/Dashboard/DashboardModeSegmentedControl.swift` — 三段式模式切换器 + 关注段角标。

**修改**
- `Sources/NewsBar/Views/Dashboard/DashboardWindow.swift` — 模式切换器位置/角标、关注筛选状态、右栏回调、关注页内容、滚动回顶。
- `Sources/NewsBar/Views/Dashboard/WeiboFollowingFeedView.swift` — 用 `FollowingMasonryFeed` 替换账号分组列表；筛选栏加账号菜单；搜索框下方加模式切换器。
- `Sources/NewsBar/Views/Dashboard/RecommendationFeedView.swift` — “关注动态”区块 + 查看全部。
- `Sources/NewsBar/Views/Dashboard/DashboardVisualComponents.swift` — 热搜卡改为整合卡（或保留旧卡给测试，新增整合卡）。
- `Sources/NewsBar/Models/AppSettings.swift` — 菜单栏 / Dashboard 角标开关。
- `Sources/NewsBar/Views/Settings/WeiboMonitorTab.swift` — 角标设置 UI。
- `Sources/NewsBar/AppDelegate.swift` — 菜单栏角标读取开关 + 设置变更通知。
- `Sources/NewsBar/Models/Localized.swift` — 新文案（关注动态、最近消息、显示更多、筛选、账号、角标开关等）。
- `RELEASE_NOTES.md`、`.release.json`、`version.txt` — 发版时更新（版本 2.17.3）。

**测试**
- `Tests/NewsBarTests/FollowingFeedModelTests.swift`
- `Tests/NewsBarTests/FollowingMasonryRenderingTests.swift`
- `Tests/NewsBarTests/FollowingRecentMessagesCardRenderingTests.swift`
- `Tests/NewsBarTests/DashboardIntegratedHotTrendCardRenderingTests.swift`
- `Tests/NewsBarTests/DashboardModeSegmentedControlTests.swift`
- `Tests/NewsBarTests/WeiboBadgeSettingsTests.swift`
- 更新 `Tests/NewsBarTests/WeiboMonitorRenderingTests.swift` / `DashboardReaderPresentationRenderingTests.swift`

---

## Task P0: Dashboard 模式切换器位置、角标与角标开关（发版阻塞项）

**Files:**
- Create: `Sources/NewsBar/Views/Dashboard/DashboardModeSegmentedControl.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/DashboardWindow.swift`（`browsePane`、`DashboardFilterBar`、`DashboardModePicker`）
- Modify: `Sources/NewsBar/Views/Dashboard/WeiboFollowingFeedView.swift`（搜索框下方模式切换器）
- Modify: `Sources/NewsBar/Models/AppSettings.swift`（两个角标开关）
- Modify: `Sources/NewsBar/Views/Settings/WeiboMonitorTab.swift`（角标设置 UI）
- Modify: `Sources/NewsBar/AppDelegate.swift`（菜单栏角标读取开关）
- Modify: `Sources/NewsBar/Models/Localized.swift`
- Test: `Tests/NewsBarTests/DashboardModeSegmentedControlTests.swift`, `Tests/NewsBarTests/WeiboBadgeSettingsTests.swift`

**Interfaces:**
- Produces: `DashboardModeSegmentedControl(mode: Binding<DashboardBrowseMode>, followingUnread: Int, badgeEnabled: Bool)`
- Produces: `AppSettings.weiboMonitorMenuBarBadgeEnabled: Bool`（默认 true）
- Produces: `AppSettings.weiboMonitorDashboardBadgeEnabled: Bool`（默认 true）
- Produces: `Notification.Name.weiboBadgeSettingsChanged`

- [ ] 写失败测试：三段按钮、选中态；`followingUnread > 0 && badgeEnabled` 时只有“关注”段含角标；`badgeEnabled == false` 或 `followingUnread == 0` 时无角标。
- [ ] 渲染测试 420×32，light/dark/retro；断言 PNG 和 accessibility label（关注段包含未读数）。
- [ ] 实现自定义分段控件：HStack + 三个 Button；选中段 accent 16% 填充；retro 用 paper/brick；角标 `Text(count)` 红底白字，放在关注段 trailing；未选中段不含角标。
- [ ] 从 `browsePane` 的外层 `VStack` 删除常驻 `DashboardModePicker`；把模式控件放进 `DashboardFilterBar`，位置在搜索框与来源 chips 之间（搜索栏下方）。
- [ ] `WeiboFollowingFeedView` 的筛选栏也在搜索框下方放同一个模式控件；保留关注页顶部 header，但不再有 ScrollView 外常驻切换器。
- [ ] 在 `AppSettings` 增加两个 `Bool`（UserDefaults 持久化，默认 true）；初始化遵循现有 `TestIsolation.defaults` 模式。
- [ ] 在 `WeiboMonitorTab` 增加“角标”设置组：菜单栏未读角标、Dashboard 关注角标两个 Toggle；切换时 post `.weiboBadgeSettingsChanged`。
- [ ] `AppDelegate.updateWeiboBadge` 读取 `settings.weiboMonitorMenuBarBadgeEnabled`；关闭时 `WeiboMenuBarBadge.image(unread: 0)`，并监听 `.weiboBadgeSettingsChanged` 强制刷新。
- [ ] Dashboard 侧：`followingUnread` 只在 `settings.weiboMonitorDashboardBadgeEnabled` 时传入控件；关闭角标不影响关注页 header/卡片里的未读数文本。
- [ ] 运行 `swift test --filter DashboardModeSegmentedControlTests`、`--filter WeiboBadgeSettingsTests`。
- [ ] 渲染/手动检查 1180×860、960×720、760×720；滚动后模式切换仍可达；两个角标开关独立生效。

## Task P1: FollowingFeedModel（纯模型）

**Files:**
- Create: `Sources/NewsBar/Models/FollowingFeedModel.swift`
- Test: `Tests/NewsBarTests/FollowingFeedModelTests.swift`

**Interfaces:**
- `struct FollowingPostEntry: Identifiable { let post: WeiboPost; let user: WeiboMonitorUser }`
- `enum FollowingReadFilter { case all, unread, p0 }`
- `struct FollowingFeedQuery { var readFilter: FollowingReadFilter; var accountUID: String?; var searchText: String }`
- `enum FollowingFeedModel { static func entries(snapshot:query:) -> [FollowingPostEntry]; static func recentEntries(snapshot:limit:) -> [FollowingPostEntry]; static func unreadCount(snapshot:query:) -> Int; static func collapsedPosts(snapshot:query:) -> [WeiboPost] }`

- [ ] 测试：账号筛选、未读筛选、P0 筛选、搜索（文本+账号名）、按 `createdAt` 倒序、最近 N 条、未读计数、collapsed relevance 尊重筛选。
- [ ] 测试：空 snapshot、无用户、被禁用、暂停状态返回空数组/0 不崩。
- [ ] 实现扁平化 `postsByUID` + `usersByUID` join；过滤 `isCollapsedByRelevance`（搜索时保留 collapsed 作为 escape hatch，与现有逻辑一致）。
- [ ] 运行 `swift test --filter FollowingFeedModelTests`。

## Task P2: FollowingPostCard + FollowingMasonryFeed

**Files:**
- Create: `Sources/NewsBar/Views/Dashboard/FollowingMasonryLayout.swift`
- Create: `Sources/NewsBar/Views/Dashboard/FollowingPostCard.swift`
- Create: `Sources/NewsBar/Views/Dashboard/FollowingMasonryFeed.swift`
- Test: `Tests/NewsBarTests/FollowingMasonryRenderingTests.swift`

**Interfaces:**
- `FollowingPostCard(entry: FollowingPostEntry, columnWidth: CGFloat, onOpen: () -> Void)`
- `FollowingMasonryFeed(entries: [FollowingPostEntry], width: CGFloat, visibleLimit: Int, onOpen: (WeiboPost) -> Void, onShowMore: (() -> Void)?)`
- `FollowingMasonryLayout.columnCount(for:)`, `columnWidth(for:columns:)`, `columns(for:columnWidth:)`, `estimatedHeight(entry:columnWidth:)`

- [ ] 写布局测试：560/760/920/1180 宽度列数 1/2/2/3；列宽与间距符合 `WaterfallLayout`；同一条目不会跨列。
- [ ] 写渲染测试：中文/英文、长文本、无图/1图/3图、转发、未读、relevance badge；light/dark/retro。
- [ ] 实现卡片：账号行（头像/昵称/优先标签/未读点）、正文 lineLimit 6、图片最多 3 张、时间/长文/转发/图片数 meta、打开动作；`newsCardSurface`；`accessibilityElement(children:.combine)`。
- [ ] 实现瀑布流容器：`LazyVStack` + 列分配；`visibleLimit` 超出时底部“加载更多”；reader compact 1 列。
- [ ] 运行 `swift test --filter FollowingMasonryRenderingTests`。

## Task P3: 独立关注页改为瀑布流 + 账号筛选

**Files:**
- Modify: `Sources/NewsBar/Views/Dashboard/WeiboFollowingFeedView.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/DashboardWindow.swift`（`followingAccountUID` 等状态）
- Modify: `Sources/NewsBar/Models/Localized.swift`
- Test: 更新 `WeiboMonitorRenderingTests` / 新增渲染变体

- [ ] 保留 header、banners、status line、collapsed relevance section。
- [ ] 删除 `accountGroup` 列表渲染；`feed` 改为 `FollowingMasonryFeed`（全量 filtered entries）。
- [ ] `filterBar` 增加账号 `Menu`（所有账号 + 每个用户，P0 tag/未读计数）；保留搜索、全部/未读/P0、计数。
- [ ] 账号筛选状态放 `DashboardWindow`，绑定到 `WeiboFollowingFeedView`；切换账号/筛选时滚动回顶。
- [ ] 更新本地化文案：关注动态、最近消息、显示更多、所有账号、按账号筛选、清除筛选。
- [ ] 渲染测试：920/760/560、light/dark/retro、空态/未登录/暂停/多账号。
- [ ] 手动：滚动、筛选、打开帖子、标记已读、返回路径。

## Task P4: “为你推荐”中的关注动态区块

**Files:**
- Modify: `Sources/NewsBar/Views/Dashboard/RecommendationFeedView.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/DashboardWindow.swift`（传 snapshot、onShowFollowing）
- Test: 新渲染变体

- [ ] `RecommendationFeedView` 增加可选 `followingEntries: [FollowingPostEntry]` + `onShowFollowing`，默认空以保持现有测试。
- [ ] 在“为你推荐”标题之前插入“关注动态”区块：标题 + `FollowingMasonryFeed(entries: prefix(6), ...)` + “查看全部关注”按钮。
- [ ] 区块只在 `followingEntries` 非空且非搜索/筛选状态时显示；避免与推荐结果重复。
- [ ] 渲染测试：1180/960/760，区块不挤压推荐 masonry，空态隐藏。
- [ ] 手动：点击卡片打开帖子；查看全部切到关注页并回到顶部。

## Task P5: 右栏整合热搜 + 关注最近消息（移除研究侧栏）

**Files:**
- Create: `Sources/NewsBar/Views/Dashboard/DashboardIntegratedHotTrendCard.swift`
- Create: `Sources/NewsBar/Views/Dashboard/FollowingRecentMessagesCard.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/DashboardWindow.swift`（`DashboardSidebarRegion` 参数 + 回调）
- Modify: `Sources/NewsBar/Views/Dashboard/DashboardVisualComponents.swift`（旧热搜卡保留给测试或删除）
- Test: `Tests/NewsBarTests/DashboardIntegratedHotTrendCardRenderingTests.swift`, `Tests/NewsBarTests/FollowingRecentMessagesCardRenderingTests.swift`

**Interfaces:**
- `DashboardIntegratedHotTrendCard(weiboItems: [NewsItem], bilibiliItems: [NewsItem])`
- `FollowingRecentMessagesCard(entries: [FollowingPostEntry], unreadCount: Int, onOpen: (WeiboPost) -> Void, onShowMore: () -> Void)`

- [ ] 写整合热搜卡测试：微博/B站二段切换、选中源只显示该源 5 条、展开全部、空态、light/dark/retro。
- [ ] 实现一张“热搜”卡：header “热搜” + 选中源计数 + 副标题“微博 · B站”；卡内二段切换；行复用 `DashboardTrendRow`；保留展开全部。
- [ ] 在 `DashboardSidebarRegion` 用一张整合卡替换两张 `DashboardHotTrendCard`；编号 01 AI → 02 热搜 → 03 关注最近消息。
- [ ] 删除 `DashboardResearchSection` 在侧栏的挂载与 `onOpenResearch` 参数；研究入口保留在工具栏（`DashboardToolbarAction`），不要变成不可达。
- [ ] 实现 `FollowingRecentMessagesCard`：header 关注 badge + “关注最近消息” + 未读 tag + 条数；5 条（账号、2 行文本、相对时间、未读点）；footer“显示更多”。
- [ ] 空态：无关注账号/未启用时隐藏；有账号无消息时显示“暂无关注消息”；加载/暂停有轻量状态。
- [ ] `onShowMore` 设置 `browseMode = .following` 并 `scrollProxy.scrollTo("browse-top", anchor: .top)`；`onOpen` 调 `monitor.openPost`。
- [ ] 渲染测试：1180 宽、sidebar 336pt、5/0/很多条、未读/已读、light/dark/retro；卡片不撑破 sidebar。
- [ ] 手动：卡片随 monitor snapshot 更新；“显示更多”落到关注页顶部；研究侧栏不再出现，但工具栏研究仍可用。

## Task P6: 发版与验收（v2.17.3）

- [ ] 全量 `swift test`（预计新增 20–30 项；记录实际数量与跳过数）。
- [ ] `swift build -c release`。
- [ ] 渲染矩阵存档：`.build/following-ui-validation/`、`.build/dashboard-sidebar-ui-validation/`、`.build/reader-ui-validation/`。
- [ ] 更新 `RELEASE_NOTES.md` 的 `## [v2.17.3]`：阅读器辅助栏、关注瀑布流、关注筛选、右栏整合热搜、关注最近消息、角标与开关、模式切换器位置；签名说明保留。
- [ ] 更新 `.release.json` 的 summary / summary_en / validation（测试计数）。
- [ ] 不新开 2.18.0；在现有 `release/v2.17.3` 分支追加提交，更新 PR #87 标题/正文，转回 ready。
- [ ] 重跑 CI（`gh pr checks 87 --watch`）；通过后合并 → tag v2.17.3 → `scripts/build.sh --adhoc` → `scripts/release.sh --allow-adhoc`。
- [ ] 替换本机 `/Applications/NewsBar.app`：退出旧 app → 旧版移入废纸篓 `NewsBar-2.17.2-<时间戳>.app` → `ditto` 新版 → 校验版本 2.17.3 / codesign → 重新启动。
- [ ] 最终 `git status` 干净复核；`gh release view v2.17.3` 校验标题、body、DMG/SHA256 附件。

---

## 已确认决策

1. 关注进入推荐：独立“关注动态”区块。
2. 关注页筛选：搜索 + 账号菜单 + 全部/未读/P0。
3. 右栏：01 AI → 02 整合热搜（微博/B站）→ 03 关注最近消息；研究侧栏移除，研究入口保留在工具栏。
4. 角标：挂在“关注”段、其他模式可见；菜单栏 / Dashboard 两个开关独立，均可关闭。
5. 模式切换器：搜索栏下方，放入 `DashboardFilterBar`；关注页放在其搜索框下方。
6. 版本：补进 2.17.3。

## 请确认

请确认按此计划执行。确认后我在主会话按 P0→P6 实现，不调起 subagent；实现完成、全量测试与渲染复核通过后，再恢复发版（PR #87 转 ready → CI → 合并 → tag → 构建 → Release → 本机替换）。

发版保持暂停：PR #87 draft，无 tag、无构建、无安装，本机仍是 2.17.2。
