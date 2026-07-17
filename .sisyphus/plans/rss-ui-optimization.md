# SDD Delta Card — RSS UI 优化

- Mode: feature
- Goal: 三项优化 — 图片流可选性检测/禁用、图标按钮替代窄Picker、文字流折叠分页
- Evidence checked: `RSSWaterfallView.swift`, `RSSTab.swift`, `AppSettings.swift:247-270`, `NewsOrchestrator.swift:265-277`, `PopoverContent.swift:66-91`, `DashboardWindow.swift:55-79`
- Root cause: 
  1. 设置中所有源都显示图片流选项，但部分源无图
  2. Picker `.frame(width:60)` 过窄
  3. 文字流无折叠，全部渲染
- Allowed files:
  - `AppSettings.swift` — RSSSourceConfig +supportsImage 字段 + Codable 迁移
  - `NewsOrchestrator.swift` — fetchRSS 后检测图片可用性
  - `RSSTab.swift` — Picker → 图标按钮
  - `RSSWaterfallView.swift` — 文字流折叠+分页
  - `PopoverContent.swift` — 分页参数动态化
  - `DashboardWindow.swift` — 同上
  - `DisplayModeMigrationTests.swift` — 新增 supportsImage 迁移测试
- Forbidden files: SecurityPolicies, ImageCache, RSSService, NewsItem, NotificationService, AIProvider, EncryptedKeyStore, CacheManager, AppDelegate, main.swift
- Minimal plan:
  1. RSSSourceConfig 添加 `supportsImage: Bool` (Codable decodeIfPresent 默认 true)
  2. NewsOrchestrator.fetchRSS 成功后 `items.contains { $0.imageURL != nil }` → 写回 settings
  3. RSSTab Picker → 两个图标按钮 (text.alignleft/photo)，无图禁用图片流按钮
  4. RSSWaterfallView displayItems 统一两种模式，文字流 pageSize=10
  5. PopoverContent/DashboardWindow 分页参数动态化 (image:4/text:10)
  6. 迁移测试 + swift test + swift build
- Verification:
  - `swift test` 40+8 新测试全绿
  - `swift build -c release --arch arm64` 成功
  - LSP 诊断 0 errors
- Safety boundary:
  - 不碰安全管道(SecurityPolicies/ImageCache)
  - 不改版本号
  - 不删现有测试
  - Codable 必须向后兼容(supportsImage 缺失时默认 true)