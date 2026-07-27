# Draft: Split Popup & Dashboard AI Summary States

## Requirements (confirmed)
- Split Popup and Dashboard summary states, prompts, content hashes, refresh triggers
- Popup: default 120 characters, independent preset
- Dashboard: default 360 characters, independent preset, lazy-on-open
- Retain one shared daily budget and serial generation lock
- Restore Dashboard two-column RSS density at 960pt widths without distorting 16:9 images
- Test both independent and shared-budget behavior

## Current Architecture (from code evidence)

### NewsOrchestrator (607 lines)
- SINGLE `aiSummaryState`, `aiSummaryItems`, `aiParsedSummary`, `lastBatchHash`
- `handleAISummary()` generates one summary for all consumers
- `regenerateAISummary()` reuses same pipeline
- `generateSummary()` uses `settings.aiMaxWords` (single value)

### AppSettings (390 lines)
- Single `aiMaxWords: Int` (default 150, options: 50/100/150/200/300)
- No per-context presets

### AISummaryService (408 lines)
- `summarize()` takes `maxWords` parameter, uses shared budget + lock
- `initBudget()`, `consumeAttemptBudget()` — shared across all callers
- `tryAcquireGenerationLock()` / `releaseGenerationLock()` — serial guard

### PopoverContent.swift (249 lines)
- Reads `orchestrator.aiSummaryState` and `orchestrator.aiSummaryItems`
- Passes to `AISummaryCard`

### DashboardAIBriefingPanel.swift (337 lines)
- Reads same `orchestrator.aiSummaryState`, `aiSummaryItems`, `aiParsedSummary`
- No lazy-on-open — consumes whatever is in orchestrator

### DashboardWindow.swift (264 lines)
- `layoutBreakpoint: CGFloat = 960`
- `sidebarWidth: CGFloat = 336`
- Min size: 960×720

### DashboardVisualComponents.swift (928 lines)
- `DashboardAdaptiveRSSMasonryFeed.minimumTwoColumnCardWidth: CGFloat = 320`
- `ViewThatFits` switches between single/two column based on this threshold
- Image cards use `aspectRatio(16/9, contentMode: .fit)`

### AITab.swift (380 lines)
- Single `aiMaxWords` picker in "模型设置" section
- No Popup/Dashboard split

### Tests (AISummaryTests.swift, 517 lines)
- Tests for `AISummaryParser`, `AppSettings` budget caps, `AISummaryService` budget boundaries
- No tests for split states scenario

## Technical Decisions

### Split State Architecture
- Add `popupAIState`, `dashboardAIState` as separate `AISummaryState` fields
- Add `popupParsedSummary`, `dashboardParsedSummary` 
- Add `popupSummaryItems`, `dashboardSummaryItems`
- Add `popupLastHash`, `dashboardLastHash`
- Add `generatePopupSummary()` and `generateDashboardSummary()` methods

### Settings
- Add `aiPopupMaxWords: Int` (default 120, whitelist: 50, 80, 120, 150)
- Add `aiDashboardMaxWords: Int` (default 360, whitelist: 200, 300, 360, 500)
- Keep `aiMaxWords` for backward compat (used as fallback during migration)
- Persist new keys to UserDefaults

### Lazy-On-Open
- Dashboard triggers summary generation in `DashboardAIBriefingPanel.onAppear` 
- Only if `dashboardAIState` is `.idle` or `.error`
- Uses shared budget/lock from AISummaryService

### Two-Column Fix
- Lower `minimumTwoColumnCardWidth` from 320 to ~280
- Calculation: (960 - 336 sidebar - 20 spacing - 28 card padding) / 2 ≈ 288
- Keep 16:9 aspect ratio unchanged

## Scope Boundaries
- INCLUDE: State split, settings UI, lazy-on-open, two-column threshold, docs update
- EXCLUDE: version.txt, release artifacts, unrelated layouts, dependency changes, credentials

## Open Questions
- None — all clear from requirements
