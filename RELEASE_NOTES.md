## v1.3.0 — 暗色模式修复 & UI 优化

### 🐛 Bug 修复

- **修复暗色模式外观设置不生效**：设置中的「通用 → 外观 → 深色/浅色」选项现在会正确应用到所有窗口，包括主弹窗、Dashboard 和设置面板。此前该设置仅存储到 UserDefaults 但从未生效。
- **修复"跟随系统"选项**：切换到「跟随系统」后立即检测当前 macOS 系统外观（深色/浅色）并应用。系统切换日/夜间模式时实时跟随，无需重启 App。

### ✨ 改进

- 使用 `NSApp.effectiveAppearance` 替代 `@Environment(\.colorScheme)`，准确读取真实系统外观，避免被 SwiftUI 视图树残留值污染。
- 新增 `AppleInterfaceThemeChangedNotification` 监听系统外观实时变化，确保"跟随系统"模式下即时响应。
- 提取 `AdaptiveColorSchemeModifier` 统一管理所有窗口的暗色模式逻辑，3 个视图窗口（SettingsWindow、PopoverContent、DashboardWindow）仅需一行 `.adaptiveColorScheme()`。

### 🔧 技术细节

- `AppSettings.swift` 新增 `resolvedColorScheme: ColorScheme?` 计算属性，将存储的 String 值 (`"system"/"light"/"dark"`) 映射为 SwiftUI ColorScheme 枚举。
- `View+Glass.swift` 新增 `AdaptiveColorSchemeModifier` + `.adaptiveColorScheme()` View 扩展。
- 创建分支: `feature/v1.3.0`
