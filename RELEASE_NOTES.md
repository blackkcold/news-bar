## v1.3.2 — Bugfix: Auto-Refresh Body Text & Source Links

### 🐛 Bug Fixes

- **Fix missing body text during auto-refresh**: AI occasionally outputs title and body on the same line (`【标题】正文`). The template parser now correctly extracts inline body text after the `】` delimiter, restoring both paragraph content and source link badges.
- **Prevent empty-body sections**: Restored body-content guard in section flush logic to avoid rendering orphaned title-only sections when the `引用：` line immediately follows a title.

### 🔧 Technical

- `AISummaryCard.swift`: `extractTemplateTitle` returns `(title, inlineBody)` tuple; body text after `】` is preserved as first line of section content.
- `flush()`: requires non-empty body before creating a section.

---

## v1.3.1 — AI Summary Template Framework & Citation Source Links

### ✨ New Features

- **Template-framework AI output**: Prompt replaced `##` Markdown with `【title】` template blocks. AI fills content into predefined slots, eliminating fragile Markdown parsing. Section titles use native SwiftUI `.bold()`; body text uses `AttributedString(markdown:)` only for inline bold.
- **Citation-number source badges**: Each paragraph carries `[#N]` citation numbers deterministically mapped to original news items. Hover reveals a Liquid Glass capsule badge; click opens the source URL. Replaces probabilistic keyword matching with 100% accurate index mapping.
- **Section dividers**: Visual separators between topic sections.

### 🐛 Bug Fixes

- Fix truncated-summary blank frame during character animation (first character now visible immediately)
- Fix fallback rendering showing raw `[#N]` citation markers
- Fix hover badge overflow when multiple sources mapped to one section
- Fix old `##` Markdown cached data not parsing after `【】` template upgrade (add backward compatibility in parser)

### 🔧 Improvements

- `AISummaryService.swift`: Prompt upgraded to `【title】` + `引用：[#N]` template framework; AI selects 3–5 most important topics with `maxWords` hard constraint
- `AISummaryCard.swift`: `parseSections` scans lines for `【` or `#` headers; `SectionRow` uses native SwiftUI controls; `stripCitations` promoted to `internal static`
- `DashboardWindow.swift`: Removed ~90 lines of duplicate parsing functions; reuses shared `parseSections`
- `AboutTab.swift`: Added GitHub link, AI provider list, project metadata, and searchable keywords
- `README.md`: Complete bilingual Chinese/English rewrite with badges, provider table, and keyword section for discoverability
- Added `LICENSE` (MIT)

### 📦 Build

```
release/1.3.1/NewsBar.app
release/1.3.1/NewsBar-1.3.1.dmg
```

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
