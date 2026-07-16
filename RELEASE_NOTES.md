## v1.4.2 — Provider 连接修复 & 错误诊断增强

### 🔐 安全修复

- **IOPlatformUUID 日志泄露修复**：移除系统日志中的机器 UUID 明文输出，防止 AES 密钥派生材料泄露

### 🐛 Bug 修复

- **测试按钮保存后变灰修复**：保存 API Key 后测试按钮仍可点击，支持直接测试已保存的 key
- **测试连接 key 优先级修复**：测试连接时优先使用用户当前输入的 key，而非缓存中的旧 key
- **测试输入清理**：测试连接时对输入 key 调用 sanitizeUserInput，与保存流程保持一致
- **启动时 cachedAPIKey 竞态修复**：异步加载未完成时 fallback 读取加密文件，防止首次刷新跳过 AI 摘要；regenerateAISummary 同步修复
- **Opencode 响应格式自适应**：Anthropic 格式解码失败时自动回退到 OpenAI 格式，兼容代理端点格式差异

### 🔧 改进

- **错误诊断增强**：测试连接和 AI 总结失败时细分网络/解码/重试耗尽错误，显示具体提示信息（含 HTTP 状态码和重试次数）
- **安全日志**：所有错误路径添加 NSLog 输出（统一使用 localizedDescription，不泄漏敏感数据）

---

## v1.4.1 — 平台兼容 & 健壮性增强

### 🐛 Bug 修复

- **1Password Apple Silicon 兼容**：支持 `/opt/homebrew/bin/op` 路径，修复 M1/M2/M3 Mac 上 1Password 集成不可用
- **AI 摘要动画竞态修复**：状态变更时取消旧动画 Task，防止快速切换导致文本混合显示

### 🔧 改进

- **更新校验纵深防御**：删除 SHA256 回退路径，统一使用 GitHub API digest 字段
- **Markdown 剥离修正**：重写粗体/斜体正则，正确清理逐字动画中的 Markdown 标记
- **RSS 警告视觉区分**：私有 IP 警告显示橙色而非红色
- **版本兜底值同步**：AppVersion 硬编码兜底更新至 1.4.0

---

## v1.3.6 — Bug 修复 & 健壮性增强

### 🐛 Bug 修复

- **API Key 启动同步加载**：确保定时器触发时 API Key 已就绪，防止首次定时刷新时因 Key 未加载而跳过 AI 摘要
- **Dashboard force unwrap 修复**：修复 Dashboard 窗口中 `orchestrator` 的强制解包，消除潜在的崩溃风险
- **AI 摘要逐字动画取消支持**：将 `Task.isCancelled` 检测改为 `try/catch` 模式，正确响应 Task 取消信号
- **AI 摘要状态数据一致**：新增 `aiSummaryItems` 属性追踪摘要所用的新闻条目，替代实时计算，避免数据不一致

### 🔧 改进

- **AI 摘要重试指数退避**：重试间隔改为指数增长（1s → 2s → 4s），捕获最后一次 HTTP 错误并输出详细信息
- **AISummaryService 错误诊断增强**：在重试全部失败时返回具体 HTTP 状态码，便于定位问题
- **NewsOrchestrator 日志增强**：获取数据源失败时增加 `NSLog` 输出，方便调试

---

## v1.3.5 — 安全加固 & 架构优化

### 🔐 安全增强

- **SHA256 代理验证修复**：修复代理验证逻辑，确保下载完整性校验
- **SSRF 防护加固**：增强服务端请求伪造防护，限制内网访问
- **HTML on* 事件属性纵深防御**：清理 HTML 内容中的危险事件属性，防止 XSS 攻击

### 🏗️ 架构优化

- **HTTPClient 提取**：将网络请求逻辑抽取为独立 HTTPClient 模块，提升可测试性
- **AISummaryParser 拆分**：AI 摘要解析器独立封装，职责单一化
- **并行刷新支持**：多数据源（微博/B站/RSS）可并行请求，提升加载速度
- **SHA256 hash 校验**：下载文件完整性验证机制
- **测试框架搭建**：引入单元测试基础设施

### 🐛 稳定性修复

- **@MainActor 线程安全修复**：确保 UI 更新在主线程执行
- **@Published 线程问题修复**：修复属性发布器的线程竞争问题
- **[weak self] 循环引用修复**：消除潜在的内存泄漏
- **缓存清除逻辑优化**：改进缓存过期和清理策略
- **applyCachedState 状态管理**：优化启动时缓存状态恢复

### ♿ 无障碍

- **无障碍支持增强**：提升 VoiceOver 兼容性
- **动画优化**：改进过渡动画流畅度
- **Magic Numbers 提取**：将硬编码常量提取为可配置参数

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
