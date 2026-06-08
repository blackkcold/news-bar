## v1.3.3 — 安全加固 & 架构优化

### 🔐 安全修复

- **修复代理 SHA256 验证漏洞**：DMG 通过镜像代理下载时，SHA256 校验文件改为从 GitHub 官方直链获取，防止代理同时篡改 DMG 和 SHA256 配对绕过验证。
- **SSRF 防护（警告模式）**：新增 `RSSURLValidation` 枚举，对私有 IP（10.x / 172.16–31.x / 192.168.x / 169.254.x / IPv6 ULA / link-local）返回警告而非直接阻止，兼顾企业内网合法 RSS 源。
- **修复 AppDelegate 强捕获**：`DispatchQueue.global().async { [self] in` 改为 `[weak self]` + guard，避免潜在循环引用。
- **修复 AboutTab 缓存清除**：注入主 orchestrator 引用，替换错误创建的临时 `NewsOrchestrator()` 实例。
- **HTML on* 事件属性纵深防御**：在 `sanitizeHTMLContent` 中添加显式 `on*=` 属性剥离正则，防止未来重构引入 XSS 漏洞。

### 🧵 线程安全

- **NewsOrchestrator 添加 @MainActor**：所有 `@Published` 属性赋值自动回到主线程，消除 SwiftUI 运行时警告。
- **AppDelegate @Published 线程安全**：将 `orchestrator?.aiSummaryState` 赋值包裹在 `Task { @MainActor in ... }` 中。

### 🏗️ 架构优化

- **提取 HTTPClient**：WeiboHotService / BilibiliHotService / RSSService 共享的 HTTP 请求逻辑抽取为 `HTTPClient` 枚举，减少 ~45 行重复代码。
- **提取 AISummaryParser**：AISummaryCard 中的 `parseSections` / `stripMarkdown` / `stripCitations` / `parseCitationNumbers` 抽取为独立 `AISummaryParser`，AISummaryCard 从 505 行降至 ~300 行。
- **消除刷新重复**：`refreshIfNeeded` 和 `manualRefresh` 共享逻辑抽取为 `doRefresh`，并使用 `withTaskGroup` 并行获取微博/B站/RSS，总刷新时间从累加变为最慢单源时间。
- **hashForItems → SHA256**：`CacheEntry.hashForItems` 从 base64(titles) 升级为 SHA256(sourceId:url:title)，提高抗碰撞能力。旧 API 保留为 deprecated wrapper。
- **applyCachedState 逻辑修复**：允许 `failed → loaded` 状态转移，缓存恢复后可正确更新 UI。

### ✨ 质量提升

- **无障碍支持**：NewsItemRow / rankBadge / AISummaryCard / BottomBar 按钮添加 `accessibilityLabel` 和 `accessibilityHint`。
- **逐字动画优化**：从 25ms/字符改为 30ms/3字符块，速度提升 ~2.5 倍同时保持流畅感。
- **Magic Numbers 提取**：AppDelegate 中 7 个魔法数字（时间间隔、窗口尺寸）提取为 `private static let` 常量。
- **新增单元测试**：Package.swift 添加 `NewsBarTests` target，覆盖 CacheEntry / SecurityPolicies / Version 比较逻辑（12 个测试用例）。

---

## v1.3.2 — 自动刷新正文消失修复

### 🐛 Bug 修复

- **修复自动刷新时 AI 摘要只显示标题、不显示正文的问题**：部分 AI 模型会将标题和正文输出在同一行（`【标题】正文内容`），解析器未能正确提取 `】` 后的正文文本，导致段落内容被丢弃、新闻源角标也随之消失。现已修复为正确提取同行内的正文。
- **防止空段落产生**：恢复段落内容空白检查，避免在标题后紧接引用行时产生只有标题没有正文的无效段落。

---

## v1.3.1 — AI 摘要模板框架 & 引用编号源链接

### ✨ 新功能

- **AI 摘要模板框架**：将 AI prompt 从脆弱的 `##` Markdown 格式升级为 `【标题】` 固定模板框架。AI 只需往预设结构中填充内容，不再依赖不稳定的 Markdown 解析。标题用原生 SwiftUI 粗体渲染，正文仅保留内联加粗，版面更稳定。
- **引用编号源链接角标**：每段 AI 摘要末尾标注 `[#N]` 引用编号，100% 确定性地映射到原始新闻。鼠标悬停段落时右上角浮现毛玻璃胶囊角标，点击即可跳转源新闻链接。替代了原有概率性关键词匹配，准确率从不确定提升至完全可靠。
- **段落间分隔线**：不同主题之间有视觉分隔，层次清晰。
- **双语 README**：中英双语项目说明，带状态徽章、AI 提供商对比表格、搜索关键词区段，提升 GitHub 可发现性。
- **MIT 开源协议**：随附完整 LICENSE 文件。

### 🐛 Bug 修复

- 修复截断摘要（摘要可能不完整）时逐字动画首帧空白的问题
- 修复摘要无法解析时回落路径直接显示原始 `[#N]` 引用标记
- 修复鼠标悬停时多来源角标横向溢出布局
- 修复旧 `##` Markdown 缓存数据在升级为 `【】` 模板后无法解析的向后兼容问题

### 🔧 改进

- `AISummaryService.swift`: prompt 升级为 `【标题】` + `引用：[#N]` 模板框架；AI 自主挑选 3–5 个最重要话题，总字数 ≤ maxWords 硬约束
- `AISummaryCard.swift`: `parseSections` 按行扫描 `【` 和 `#` 标记，同时兼容新旧格式；`SectionRow` 改用原生 SwiftUI 控件替代 Markdown 布局
- `DashboardWindow.swift`: 消除约 90 行重复解析代码，复用共享解析函数
- `AboutTab.swift`: 新增 GitHub 链接、AI 提供商列表、项目元信息和搜索关键词
- `PopoverContent.swift`: 传入新闻条目列表以支持引用编号映射

---

## v1.3.0 — Dark Mode Fix & UI Polish

### 🐛 Bug Fixes

- **Fix dark mode appearance setting not applying**: Settings → General → Appearance → Dark/Light now correctly applies to all windows (popover, dashboard, settings).
- **Fix "Follow System" option**: Detects current macOS appearance immediately; switches in real-time without app restart.

### ✨ Improvements

- Use `NSApp.effectiveAppearance` instead of `@Environment(\.colorScheme)` for accurate system appearance detection.
- Add `AppleInterfaceThemeChangedNotification` listener for real-time system appearance changes.
- Extract `AdaptiveColorSchemeModifier` to unify dark mode across 3 views via `.adaptiveColorScheme()`.

### 🔧 Technical

- `AppSettings.swift`: Add `resolvedColorScheme: ColorScheme?` computed property mapping `"system"/"light"/"dark"` to SwiftUI enum.
- `View+Glass.swift`: Add `AdaptiveColorSchemeModifier` + `.adaptiveColorScheme()` extension.
- Branch: `feature/v1.3.0`
