# Split Popup & Dashboard AI Summary States

## TL;DR

> **Quick Summary**: Split the shared AI summary pipeline into independent Popup (120-char) and Dashboard (360-char) channels with separate states, prompts, hashes, and generation triggers, while retaining one shared daily budget and serial lock. Also fix two-column RSS masonry at 960pt windows.
>
> **Deliverables**:
> - Dual AI summary state model in `NewsOrchestrator` (popup + dashboard)
> - Independent word-count presets in `AppSettings` + `AITab` UI
> - Dashboard lazy-on-open summary generation
> - Lowered two-column masonry threshold (~280pt)
> - Updated README.md
> - Extended `AISummaryTests.swift`
>
> **Estimated Effort**: Medium
> **Parallel Execution**: YES — 2 waves
> **Critical Path**: Task 1 → Task 2 → Task 4 → Task 5 → Task 7

---

## Context

### Original Request
Split Popup and Dashboard AI summary states with independent prompts, word limits, and refresh triggers. Popup defaults to 120 chars, Dashboard to 360 chars. Dashboard generates lazily on open. Shared daily budget and serial lock preserved. Fix two-column RSS density at 960pt without distorting 16:9 images.

### Interview Summary
**Key Discussions**:
- User explicitly rejected a one-call/truncate design — requires separately generated Popup and Dashboard content
- Accepted duplicate API cost warning (Metis flag) after confirming distinct generation semantics
- No dependency additions, no version/release record changes, no credential changes

**Research Findings**:
- `NewsOrchestrator` (607 lines) has single `aiSummaryState`, single `lastBatchHash`, single pipeline
- `AppSettings` has single `aiMaxWords` (default 150)
- `DashboardAdaptiveRSSMasonryFeed.minimumTwoColumnCardWidth = 320` — too high for 960pt window (effective width ~288pt per column after sidebar + padding)
- `DashboardWindow.layoutBreakpoint = 960`, `sidebarWidth = 336`
- Both `PopoverContent` and `DashboardAIBriefingPanel` consume the same `orchestrator.aiSummaryState`
- `AISummaryService` budget and lock are global/static — naturally shared

---

## Work Objectives

### Core Objective
Decouple Popup and Dashboard AI summary generation into independent state channels, each with its own prompt, word-limit preset, content hash, and refresh trigger. Fix two-column RSS masonry at 960pt windows.

### Concrete Deliverables
- `NewsOrchestrator.swift` — split state properties + per-context generation methods
- `AppSettings.swift` — `aiPopupMaxWords`, `aiDashboardMaxWords` fields
- `AITab.swift` — settings UI for Popup vs Dashboard presets
- `PopoverContent.swift` — read `popupAIState` instead of shared `aiSummaryState`
- `AISummaryCard.swift` — accept `popupAIState` (already reads `state` binding)
- `DashboardAIBriefingPanel.swift` — read `dashboardAIState`, trigger lazy generation
- `DashboardVisualComponents.swift` — lower `minimumTwoColumnCardWidth` 320 → 280
- `README.md` — document split summary behavior
- `AISummaryTests.swift` — tests for split-state scenarios, lazy trigger, budget sharing

### Definition of Done
- [ ] Popup generates 120-char summary independently from Dashboard's 360-char summary
- [ ] Each has independent content hash — changing Popup preset does not invalidate Dashboard cache
- [ ] Dashboard opens with `.idle` state, triggers generation on first display
- [ ] Two RSS columns render at 960pt window width with 16:9 images undistorted
- [ ] Shared budget: Popup + Dashboard combined requests ≤ `aiDailyCap`
- [ ] Serial lock: cannot generate Popup and Dashboard summaries concurrently
- [ ] `swift build -c release --arch arm64` passes
- [ ] `swift test` passes (all existing + new tests)

### Must Have
- Independent `popupAIState` / `dashboardAIState` in orchestrator
- Independent `aiPopupMaxWords` / `aiDashboardMaxWords` in settings (whitelisted)
- Dashboard lazy-on-open trigger in `.onAppear`
- Two-column threshold lowered to ≤280pt
- Shared budget and lock unchanged

### Must NOT Have (Guardrails)
- Do NOT add third-party dependencies
- Do NOT alter `version.txt`, `RELEASE_NOTES.md`, `.release.json`
- Do NOT change unrelated layouts (trend cards, settings tabs, popover sizing)
- Do NOT change credential storage (`EncryptedKeyStore`)
- Do NOT assume external API integration tests can run
- Do NOT alter `scripts/build.sh` behavior
- Do NOT change `Package.swift`

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed.

### Test Decision
- **Infrastructure exists**: YES (XCTest, `swift test`)
- **Automated tests**: Tests-after (extend `AISummaryTests.swift`)
- **Framework**: XCTest (existing)

### QA Policy
Every task includes agent-executed QA scenarios. Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **API/Logic**: Use Bash (`swift test --filter`) — Run specific test cases, assert pass/fail
- **Build**: Use Bash (`swift build`) — Assert clean compilation
- **UI**: Use Playwright (not applicable — macOS native app, verify via build + test)

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately — model + settings foundation, MAX PARALLEL):
├── Task 1: AppSettings — add aiPopupMaxWords / aiDashboardMaxWords [quick]
├── Task 2: AITab.swift — Popup/Dashboard preset UI [quick]
├── Task 3: DashboardVisualComponents — lower two-column threshold [quick]
└── Task 4: NewsOrchestrator — split state + per-context generation [deep]

Wave 2 (After Wave 1 — views + tests, MAX PARALLEL):
├── Task 5: PopoverContent + AISummaryCard — wire popup state [quick]
├── Task 6: DashboardAIBriefingPanel — lazy-on-open trigger [quick]
├── Task 7: AISummaryTests — split-state + budget-sharing tests [deep]
└── Task 8: README.md — document split summary [writing]

Critical Path: Task 1 → Task 4 → Task 7 (must verify)
Parallel Speedup: ~60% faster than sequential
Max Concurrent: 4 (Wave 1) + 4 (Wave 2)
```

### Dependency Matrix

| Task | Depends On | Blocks | Wave |
|------|-----------|--------|------|
| 1 | - | 2, 4 | 1 |
| 2 | 1 | - | 1 |
| 3 | - | - | 1 |
| 4 | 1 | 5, 6, 7 | 1 |
| 5 | 4 | - | 2 |
| 6 | 4 | - | 2 |
| 7 | 4 | - | 2 |
| 8 | 7 | - | 2 |

### Agent Dispatch Summary

- **Wave 1**: **4 tasks** — T1, T2, T3 → `quick`, T4 → `deep`
- **Wave 2**: **4 tasks** — T5, T6 → `quick`, T7 → `deep`, T8 → `writing`

---

## TODOs

- [ ] 1. **AppSettings — add `aiPopupMaxWords` and `aiDashboardMaxWords` fields**

  **What to do**:
  - Add `var aiPopupMaxWords: Int` with `didSet` persisting to `UserDefaults` key `"aiPopupMaxWords"`
  - Add `var aiDashboardMaxWords: Int` with `didSet` persisting to `UserDefaults` key `"aiDashboardMaxWords"`
  - Define whitelists: `static let validPopupWordCounts: Set<Int> = [50, 80, 120, 150]` and `static let validDashboardWordCounts: Set<Int> = [200, 300, 360, 500]`
  - In `init()`, read from UserDefaults with fallback: `aiPopupMaxWords` defaults to 120, `aiDashboardMaxWords` defaults to 360
  - Validate against whitelists on init (reject invalid values, fall back to defaults)
  - Keep existing `aiMaxWords` for backward compatibility — it is not removed, but Popup/Dashboard should use their own presets
  - No changes to `todayAIRequestCount`, `aiDailyCap`, `recordAIRequests()`, or `resetDailyStatsIfNeeded()`

  **Must NOT do**:
  - Do NOT remove or rename `aiMaxWords`
  - Do NOT change budget/cap logic
  - Do NOT touch RSS-related fields

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Single file, straightforward property additions with UserDefaults persistence
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `swiftui-expert-skill`: Not needed — no SwiftUI views involved

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 2, 3)
  - **Blocks**: Task 2, Task 4
  - **Blocked By**: None (can start immediately)

  **References** (CRITICAL):
  - `Sources/NewsBar/Models/AppSettings.swift:30-32` — existing `aiMaxWords` pattern: `didSet` + `UserDefaults` setter, used for `didSet` template
  - `Sources/NewsBar/Models/AppSettings.swift:134` — `aiMaxWords` init: `defaults.integerIfPresent(forKey:) ?? 150`, pattern for reading persisted value
  - `Sources/NewsBar/Models/AppSettings.swift:134` — existing valid cap whitelist pattern: `Self.validAICaps.contains(rawCap) ? rawCap : 50`, used for word-count whitelist validation
  - `Sources/NewsBar/Models/AppSettings.swift:248-249` — `validAICaps` declaration pattern: `static let validAICaps: Set<Int> = [20, 50, 100]`, used for whitelist template
  - `Sources/NewsBar/Models/AppSettings.swift:182-180` (isInitializing pattern): guard `!isInitializing` before side effects, must replicate for new fields

  **Acceptance Criteria**:
  - [ ] `AppSettings().aiPopupMaxWords == 120` (default)
  - [ ] `AppSettings().aiDashboardMaxWords == 360` (default)
  - [ ] Setting invalid value (e.g., 42) for `aiPopupMaxWords` → falls back to 120
  - [ ] `UserDefaults` keys `aiPopupMaxWords` and `aiDashboardMaxWords` persist correctly

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Default values on fresh init
    Tool: Bash (swift REPL-style via test)
    Preconditions: Clear UserDefaults for keys aiPopupMaxWords, aiDashboardMaxWords
    Steps:
      1. Run: swift test --filter AppSettingsSplitPresetTests/testDefaults
      2. Assert: aiPopupMaxWords == 120, aiDashboardMaxWords == 360
    Expected Result: Both defaults match specification
    Failure Indicators: Values differ from 120/360
    Evidence: .sisyphus/evidence/task-1-defaults.txt

  Scenario: Whitelist validation rejects invalid values
    Tool: Bash (swift test)
    Preconditions: UserDefaults set to invalid value (e.g., 77 for popup)
    Steps:
      1. Run: swift test --filter AppSettingsSplitPresetTests/testRejectsInvalidPopupWords
      2. Assert: aiPopupMaxWords falls back to 120
    Expected Result: Invalid value rejected, default applied
    Failure Indicators: Invalid value accepted
    Evidence: .sisyphus/evidence/task-1-validation.txt
  ```

  **Evidence to Capture**:
  - [ ] `task-1-defaults.txt` — test output showing default values
  - [ ] `task-1-validation.txt` — test output showing whitelist rejection

  **Commit**: YES (groups with Task 2, 3, 4)
  - Message: `feat(ai): add split Popup/Dashboard AI summary word-count presets`
  - Files: `Sources/NewsBar/Models/AppSettings.swift`

- [ ] 2. **AITab.swift — add Popup/Dashboard preset pickers in Settings UI**

  **What to do**:
  - In the "模型设置" `Section`, replace or extend the single `aiMaxWords` picker
  - Add two new rows:
    1. "Popup 最大字数" — Picker with `settings.aiPopupMaxWords` bound to `aiPopupMaxWords` values from `validPopupWordCounts`
    2. "Dashboard 最大字数" — Picker with `settings.aiDashboardMaxWords` bound to `aiDashboardMaxWords` values from `validDashboardWordCounts`
  - Keep existing `aiMaxWords` picker with a `Disabled` state or label it "(Legacy)" — do NOT remove it to avoid breaking stored preferences
  - Each picker shows "X 字" labels like existing pattern at line 154-159
  - Add footer text explaining: "Popup 摘要显示在菜单栏弹窗中，Dashboard 摘要显示在独立窗口中。两者独立生成，共享每日 API 配额。"

  **Must NOT do**:
  - Do NOT remove the existing `aiMaxWords` picker
  - Do NOT change provider selection, API key, or other sections
  - Do NOT alter the "用量" or "限额" sections

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Single-file SwiftUI form modification with existing Picker patterns
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `swiftui-expert-skill`: Not needed — simple Picker additions

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 3)
  - **Blocks**: None
  - **Blocked By**: Task 1 (needs `aiPopupMaxWords`/`aiDashboardMaxWords` fields)

  **References** (CRITICAL):
  - `Sources/NewsBar/Views/Settings/AITab.swift:147-162` — existing `aiMaxWords` Picker pattern: `Picker("", selection: Binding(get:set:))` with `.labelsHidden().frame(width:90)`, exact template to copy
  - `Sources/NewsBar/Views/Settings/AITab.swift:137-146` — model picker pattern: `Picker("模型", selection: Binding(...))`, used for picker label style
  - `Sources/NewsBar/Models/AppSettings.swift` — new `validPopupWordCounts` / `validDashboardWordCounts` whitelists, needed for picker options

  **Acceptance Criteria**:
  - [ ] "Popup 最大字数" picker visible with options 50/80/120/150 字
  - [ ] "Dashboard 最大字数" picker visible with options 200/300/360/500 字
  - [ ] Changing picker updates `settings.aiPopupMaxWords` / `settings.aiDashboardMaxWords`
  - [ ] Footer explanation text visible

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Picker values persist correctly
    Tool: Bash (swift build + manual inspection of UserDefaults)
    Preconditions: Build succeeds
    Steps:
      1. Run: swift build -c release --arch arm64
      2. Assert: Build succeeded (0 errors)
      3. Verify AITab.swift compiles with references to aiPopupMaxWords/aiDashboardMaxWords
    Expected Result: Clean build
    Failure Indicators: Compiler errors referencing undefined properties
    Evidence: .sisyphus/evidence/task-2-build.txt

  Scenario: Picker range matches whitelists
    Tool: Bash (grep)
    Steps:
      1. grep for "aiPopupMaxWords" in AITab.swift — verify Picker options match validPopupWordCounts
      2. grep for "aiDashboardMaxWords" in AITab.swift — verify Picker options match validDashboardWordCounts
    Expected Result: Picker `.tag()` values match whitelist sets
    Failure Indicators: Mismatched values or missing options
    Evidence: .sisyphus/evidence/task-2-picker-values.txt
  ```

  **Evidence to Capture**:
  - [ ] `task-2-build.txt` — `swift build` output
  - [ ] `task-2-picker-values.txt` — grep results confirming picker values

  **Commit**: YES (groups with Task 1, 3, 4)
  - Message: `feat(ai): add split Popup/Dashboard AI summary word-count presets`
  - Files: `Sources/NewsBar/Views/Settings/AITab.swift`

- [ ] 3. **DashboardVisualComponents — lower two-column masonry threshold**

  **What to do**:
  - In `DashboardAdaptiveRSSMasonryFeed`, change `minimumTwoColumnCardWidth` from `320` to `280`
  - This is at line 450: `private let minimumTwoColumnCardWidth: CGFloat = 320` → `280`
  - Rationale: At 960pt window width, the RSS main region gets ~960 - 336(sidebar) - 20(spacing) - 12*2(padding) ≈ 580pt. Divided by 2 columns minus 12pt column spacing = ~284pt per column. 280pt allows `ViewThatFits` to select two-column layout.
  - Verify that `DashboardRSSMasonryCard` (line 641) `cardHeaderAspectRatio = 16/9` and `aspectRatio(contentMode: .fit)` remain unchanged — images stay undistorted
  - No other layout constants changed

  **Must NOT do**:
  - Do NOT change `cardHeaderAspectRatio` (must stay 16/9)
  - Do NOT change `aspectRatio(contentMode: .fit)` → must not become `.fill`
  - Do NOT change `columnSpacing` or other masonry layout constants
  - Do NOT change `layoutBreakpoint` in DashboardWindow.swift (stays 960)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Single constant change in one file
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `swiftui-expert-skill`: Not needed — single constant value change

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 2)
  - **Blocks**: None
  - **Blocked By**: None (can start immediately)

  **References** (CRITICAL):
  - `Sources/NewsBar/Views/Dashboard/DashboardVisualComponents.swift:450` — `private let minimumTwoColumnCardWidth: CGFloat = 320` — the exact line to change
  - `Sources/NewsBar/Views/Dashboard/DashboardVisualComponents.swift:512-515` — `ViewThatFits` usage: `twoColumnGrid` and `singleColumnGrid`, this is what the threshold controls
  - `Sources/NewsBar/Views/Dashboard/DashboardVisualComponents.swift:661` — `cardHeaderAspectRatio: 16.0 / 9.0` — must NOT change
  - `Sources/NewsBar/Views/Dashboard/DashboardVisualComponents.swift:761` — `aspectRatio(cardHeaderAspectRatio, contentMode: .fit)` — must NOT change
  - `Sources/NewsBar/Views/Dashboard/DashboardWindow.swift:11` — `layoutBreakpoint = 960` — contextual reference, must NOT change

  **Acceptance Criteria**:
  - [ ] `minimumTwoColumnCardWidth == 280` (was 320)
  - [ ] `cardHeaderAspectRatio == 16/9` (unchanged)
  - [ ] `aspectRatio(contentMode: .fit)` (unchanged)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Constant value verified
    Tool: Bash (grep)
    Steps:
      1. Run: grep -n "minimumTwoColumnCardWidth" Sources/NewsBar/Views/Dashboard/DashboardVisualComponents.swift
      2. Assert: value is 280, not 320
    Expected Result: Line shows `= 280`
    Failure Indicators: Value still 320 or changed to something else
    Evidence: .sisyphus/evidence/task-3-threshold.txt

  Scenario: Aspect ratio preserved
    Tool: Bash (grep)
    Steps:
      1. Run: grep -n "cardHeaderAspectRatio\|16.0.*9.0\|contentMode.*fit" Sources/NewsBar/Views/Dashboard/DashboardVisualComponents.swift
      2. Assert: 16.0/9.0 still present, contentMode remains .fit
    Expected Result: Both constants unchanged
    Failure Indicators: ratio or contentMode changed
    Evidence: .sisyphus/evidence/task-3-aspect.txt
  ```

  **Evidence to Capture**:
  - [ ] `task-3-threshold.txt` — grep output confirming 280
  - [ ] `task-3-aspect.txt` — grep output confirming 16:9 + .fit

  **Commit**: YES (groups with Task 1, 2, 4)
  - Message: `feat(ai): add split Popup/Dashboard AI summary word-count presets`
  - Files: `Sources/NewsBar/Views/Dashboard/DashboardVisualComponents.swift`

- [ ] 4. **NewsOrchestrator — split AI summary state into popup + dashboard channels**

  **What to do**:
  - **Split published state** (replace single `aiSummaryState`, `aiParsedSummary`, `aiSummaryItems`, `lastBatchHash`):
    - `@Published var popupAIState = AISummaryState.idle`
    - `@Published var dashboardAIState = AISummaryState.idle`
    - `@Published var popupAIParsedSummary: ParsedSummary?`
    - `@Published var dashboardAIParsedSummary: ParsedSummary?`
    - `@Published var popupAISummaryItems: [NewsItem] = []`
    - `@Published var dashboardAISummaryItems: [NewsItem] = []`
    - `private var popupLastHash: String?`
    - `private var dashboardLastHash: String?`
  - **Update `handleAISummary()`** (line 299): rename parameters to accept a context (`isPopup: Bool`), select correct state/hash/settings fields. Popup uses `settings.aiPopupMaxWords`, Dashboard uses `settings.aiDashboardMaxWords`.
  - **Update `generateSummary()`** (line 474): accept `maxWords` from caller instead of reading `settings.aiMaxWords`. Currently line 336 reads `settings.aiMaxWords` — change to parameter.
  - **Update `regenerateAISummary()`** (line 555): accept context parameter, route to correct state.
  - **Add `generateDashboardSummaryIfNeeded()`**: new method called by Dashboard view. Checks if `dashboardAIState` is `.idle` or `.error`, acquires lock, uses shared budget, generates.
  - **Update `clearCache()`**: reset both `popupAIState` and `dashboardAIState` to `.idle`
  - **Update `allActiveItems()`**: no change — shared data source
  - **Update `loadCached()`**: no change — cache loading is source-agnostic
  - Remove old `aiSummaryState`, `aiSummaryItems`, `aiParsedSummary`, `lastBatchHash` fields (replace with split versions)

  **Must NOT do**:
  - Do NOT change `AISummaryService` budget or lock mechanisms
  - Do NOT change `doRefresh()` logic flow (still calls `handleAISummary` for popup)
  - Do NOT change `fetchWeibo`/`fetchBilibili`/`fetchRSS`
  - Do NOT change `allActiveItems()` data assembly

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Multi-field refactor across the central orchestrator — requires careful state routing and impact awareness
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `swiftui-expert-skill`: Not needed — no SwiftUI views involved, pure state management

  **Parallelization**:
  - **Can Run In Parallel**: NO (must run after Task 1, before Tasks 5/6/7)
  - **Parallel Group**: Wave 1 (sequential within wave — runs alone)
  - **Blocks**: Task 5, Task 6, Task 7
  - **Blocked By**: Task 1 (needs `aiPopupMaxWords`/`aiDashboardMaxWords`)

  **References** (CRITICAL):
  - `Sources/NewsBar/Services/NewsOrchestrator.swift:46-49` — current `aiSummaryState`, `aiSummaryItems`, `aiParsedSummary` declarations — the exact lines to split
  - `Sources/NewsBar/Services/NewsOrchestrator.swift:56` — current `lastBatchHash` — split into `popupLastHash` / `dashboardLastHash`
  - `Sources/NewsBar/Services/NewsOrchestrator.swift:299-346` — `handleAISummary()` method — primary refactor target, needs context routing
  - `Sources/NewsBar/Services/NewsOrchestrator.swift:474-528` — `generateSummary()` — currently reads `settings.aiMaxWords` at line 336, must become parameterized
  - `Sources/NewsBar/Services/NewsOrchestrator.swift:555-593` — `regenerateAISummary()` — needs context routing
  - `Sources/NewsBar/Services/NewsOrchestrator.swift:543-553` — `clearCache()` — needs to reset both states
  - `Sources/NewsBar/Services/AISummaryService.swift:36-38` — `initBudget(baseline:cap:)` — called before each generation, shared budget init
  - `Sources/NewsBar/Services/AISummaryService.swift:63-68` — `tryAcquireGenerationLock()` — shared serial lock
  - `Sources/NewsBar/Models/AppSettings.swift` — new `aiPopupMaxWords`/`aiDashboardMaxWords` fields (from Task 1)

  **Acceptance Criteria**:
  - [ ] `popupAIState` and `dashboardAIState` exist as separate `@Published` properties
  - [ ] `handleAISummary` routes to correct state based on context
  - [ ] `generateDashboardSummaryIfNeeded()` generates only when state is `.idle` or `.error`
  - [ ] Shared budget: both popup and dashboard count toward `todayAIRequestCount`
  - [ ] Serial lock: `tryAcquireGenerationLock()` prevents concurrent generation
  - [ ] `clearCache()` resets both states to `.idle`

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Split state properties exist and compile
    Tool: Bash (swift build)
    Preconditions: Task 1 complete (aiPopupMaxWords/aiDashboardMaxWords exist)
    Steps:
      1. Run: swift build -c release --arch arm64
      2. Assert: Build succeeded (0 errors)
      3. If errors: fix all references to old aiSummaryState throughout the codebase
    Expected Result: Clean build with split state
    Failure Indicators: "aiSummaryState not found" or duplicate symbol errors
    Evidence: .sisyphus/evidence/task-4-build.txt

  Scenario: State isolation — popup generation does not affect dashboard state
    Tool: Bash (grep)
    Steps:
      1. grep for "popupAIState" in NewsOrchestrator.swift — verify handleAISummary writes to popupAIState for popup context
      2. grep for "dashboardAIState" — verify generateDashboardSummaryIfNeeded writes to dashboardAIState
      3. Assert: no cross-contamination (popup code does not set dashboardAIState)
    Expected Result: Clear separation of state writes
    Failure Indicators: popup code touching dashboardAIState or vice versa
    Evidence: .sisyphus/evidence/task-4-isolation.txt

  Scenario: Serial lock prevents concurrent generation
    Tool: Bash (grep)
    Steps:
      1. grep for "tryAcquireGenerationLock" in NewsOrchestrator.swift
      2. Assert: both popup and dashboard paths call tryAcquireGenerationLock() before generateSummary()
    Expected Result: Lock acquired in both code paths
    Failure Indicators: Missing lock acquisition in either path
    Evidence: .sisyphus/evidence/task-4-lock.txt
  ```

  **Evidence to Capture**:
  - [ ] `task-4-build.txt` — `swift build` output
  - [ ] `task-4-isolation.txt` — grep results showing state isolation
  - [ ] `task-4-lock.txt` — grep results showing lock usage

  **Commit**: YES (groups with Task 1, 2, 3)
  - Message: `feat(ai): add split Popup/Dashboard AI summary word-count presets`
  - Files: `Sources/NewsBar/Services/NewsOrchestrator.swift`

- [ ] 5. **PopoverContent + AISummaryCard — wire popup-specific AI state**

  **What to do**:
  - **PopoverContent.swift** (line 43-44): Change `orchestrator.aiSummaryState` → `orchestrator.popupAIState` and `orchestrator.aiSummaryItems` → `orchestrator.popupAISummaryItems`
  - The `AISummaryCard` already accepts `state` as a binding parameter — no changes needed to `AISummaryCard.swift` itself
  - **Regenerate callback** (line 48-52): Change to call `orchestrator.regenerateAISummary(settings: settings, context: .popup)`
  - No changes to `NewsSection`, `RSSWaterfallView`, or other PopoverContent components

  **Must NOT do**:
  - Do NOT change `AISummaryCard.swift` internal logic
  - Do NOT change PopoverContent layout or sizing

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple property reference updates in a single file
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `swiftui-expert-skill`: Not needed — no new views, just property renames

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 6, 7, 8)
  - **Blocks**: None
  - **Blocked By**: Task 4 (needs `popupAIState` to exist)

  **References** (CRITICAL):
  - `Sources/NewsBar/Views/MenuBar/PopoverContent.swift:43-44` — line where `orchestrator.aiSummaryState` is read — change to `orchestrator.popupAIState`
  - `Sources/NewsBar/Views/MenuBar/PopoverContent.swift:47` — `orchestrator.aiSummaryItems` — change to `orchestrator.popupAISummaryItems`
  - `Sources/NewsBar/Views/MenuBar/PopoverContent.swift:48-52` — regenerate callback — update method call
  - `Sources/NewsBar/Views/MenuBar/AISummaryCard.swift:4` — `let state: AISummaryState` — no change needed (already parameterized)

  **Acceptance Criteria**:
  - [ ] `PopoverContent` reads `orchestrator.popupAIState` (not old `aiSummaryState`)
  - [ ] `PopoverContent` reads `orchestrator.popupAISummaryItems` (not old `aiSummaryItems`)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: No references to old aiSummaryState in PopoverContent
    Tool: Bash (grep)
    Steps:
      1. Run: grep -n "aiSummaryState\|aiSummaryItems\|aiParsedSummary" Sources/NewsBar/Views/MenuBar/PopoverContent.swift
      2. Assert: zero matches (all replaced with popupAIState/popupAISummaryItems)
    Expected Result: No old property references remain
    Failure Indicators: Grep finds "aiSummaryState" or "aiSummaryItems"
    Evidence: .sisyphus/evidence/task-5-grep.txt

  Scenario: Build succeeds with popup state references
    Tool: Bash (swift build)
    Steps:
      1. Run: swift build -c release --arch arm64
      2. Assert: Build succeeded
    Expected Result: Clean build
    Failure Indicators: Compiler errors about undefined properties
    Evidence: .sisyphus/evidence/task-5-build.txt
  ```

  **Evidence to Capture**:
  - [ ] `task-5-grep.txt` — grep output confirming zero matches
  - [ ] `task-5-build.txt` — `swift build` output

  **Commit**: YES (groups with Task 6, 7, 8)
  - Message: `feat(ai): wire split AI states to Popup and Dashboard views`
  - Files: `Sources/NewsBar/Views/MenuBar/PopoverContent.swift`

- [ ] 6. **DashboardAIBriefingPanel — lazy-on-open trigger + dashboard state wiring**

  **What to do**:
  - **Wire state**: Change references from `orchestrator.aiSummaryState` → `orchestrator.dashboardAIState` throughout the file
  - Change `orchestrator.aiSummaryItems` → `orchestrator.dashboardAISummaryItems`
  - Change `orchestrator.aiParsedSummary` → `orchestrator.dashboardAIParsedSummary`
  - **Add lazy trigger**: In the existing `.onAppear` block (line 119-123), add logic:
    ```swift
    .onAppear {
        if case .idle = orchestrator.dashboardAIState {
            Task { await orchestrator.generateDashboardSummaryIfNeeded(settings: settings) }
        }
        if selectedSections.isEmpty {
            selectedCategory = preferredCategory
        }
    }
    ```
    - Need `@Environment(AppSettings.self) private var settings` — add if missing (check line 1-7; currently `DashboardAIBriefingPanel` does NOT have `@Environment(AppSettings.self)`)
    - Add `@Environment(AppSettings.self) private var settings` property at the top of the struct
  - **Regenerate**: If Dashboard panel has a regenerate button (check — currently does not), wire to `orchestrator.regenerateAISummary(settings:settings, context:.dashboard)`

  **Must NOT do**:
  - Do NOT change the existing `onChange(of: summarySignature)` observer
  - Do NOT change category picker or section rendering logic
  - Do NOT change `SectionRow` (shared component at line 432)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Property reference updates + one new `.onAppear` block
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `swiftui-expert-skill`: Not needed — straightforward wiring

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 7, 8)
  - **Blocks**: None
  - **Blocked By**: Task 4 (needs `dashboardAIState` and `generateDashboardSummaryIfNeeded`)

  **References** (CRITICAL):
  - `Sources/NewsBar/Views/Dashboard/DashboardAIBriefingPanel.swift:4` — `@ObservedObject var orchestrator` — the orchestrator reference
  - `Sources/NewsBar/Views/Dashboard/DashboardAIBriefingPanel.swift:11-16` — `resolvedSummaryText` reads `orchestrator.aiSummaryState` — change to `dashboardAIState`
  - `Sources/NewsBar/Views/Dashboard/DashboardAIBriefingPanel.swift:28` — reads `orchestrator.aiParsedSummary` — change to `dashboardAIParsedSummary`
  - `Sources/NewsBar/Views/Dashboard/DashboardAIBriefingPanel.swift:29` — reads `orchestrator.aiSummaryItems.count` — change to `dashboardAISummaryItems`
  - `Sources/NewsBar/Views/Dashboard/DashboardAIBriefingPanel.swift:61-63` — `summaryItems` computed property — reads `orchestrator.aiSummaryItems` — change to `dashboardAISummaryItems`
  - `Sources/NewsBar/Views/Dashboard/DashboardAIBriefingPanel.swift:119-123` — existing `.onAppear` — add lazy trigger here
  - `Sources/NewsBar/Views/Dashboard/DashboardAIBriefingPanel.swift:1-7` — no `@Environment(AppSettings.self)` currently — need to add

  **Acceptance Criteria**:
  - [ ] All `aiSummaryState` references replaced with `dashboardAIState`
  - [ ] All `aiSummaryItems` → `dashboardAISummaryItems`
  - [ ] All `aiParsedSummary` → `dashboardAIParsedSummary`
  - [ ] `.onAppear` triggers `generateDashboardSummaryIfNeeded()` when state is `.idle`
  - [ ] `@Environment(AppSettings.self)` added (required for lazy trigger call)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: No references to old shared state remain
    Tool: Bash (grep)
    Steps:
      1. Run: grep -n "aiSummaryState\|aiSummaryItems\|aiParsedSummary" Sources/NewsBar/Views/Dashboard/DashboardAIBriefingPanel.swift
      2. Assert: zero matches (all replaced with dashboard-prefixed versions)
    Expected Result: No old property references
    Failure Indicators: Found old property names
    Evidence: .sisyphus/evidence/task-6-grep.txt

  Scenario: Lazy trigger present in onAppear
    Tool: Bash (grep)
    Steps:
      1. Run: grep -A5 "\.onAppear" Sources/NewsBar/Views/Dashboard/DashboardAIBriefingPanel.swift
      2. Assert: contains "generateDashboardSummaryIfNeeded" call guarded by `.idle` check
    Expected Result: Lazy trigger code present
    Failure Indicators: Missing generateDashboardSummaryIfNeeded call
    Evidence: .sisyphus/evidence/task-6-lazy.txt

  Scenario: Build succeeds
    Tool: Bash (swift build)
    Steps:
      1. Run: swift build -c release --arch arm64
      2. Assert: Build succeeded
    Expected Result: Clean build
    Failure Indicators: Compiler errors
    Evidence: .sisyphus/evidence/task-6-build.txt
  ```

  **Evidence to Capture**:
  - [ ] `task-6-grep.txt` — grep confirming zero old references
  - [ ] `task-6-lazy.txt` — grep showing lazy trigger
  - [ ] `task-6-build.txt` — `swift build` output

  **Commit**: YES (groups with Task 5, 7, 8)
  - Message: `feat(ai): wire split AI states to Popup and Dashboard views`
  - Files: `Sources/NewsBar/Views/Dashboard/DashboardAIBriefingPanel.swift`

- [ ] 7. **AISummaryTests — extend tests for split-state scenarios**

  **What to do**:
  - Add new test class `SplitStateIntegrationTests` (or extend existing classes)
  - **Test 1 — State isolation**: Verify `popupAIState` and `dashboardAIState` are independent. Mock two generations with different word limits; assert states differ.
  - **Test 2 — Budget sharing**: Simulate `consumeAttemptBudget()` calls from both popup and dashboard paths; assert combined count ≤ cap.
  - **Test 3 — Lazy trigger guard**: Verify `generateDashboardSummaryIfNeeded()` does NOT generate when `dashboardAIState` is `.done` or `.summarizing`.
  - **Test 4 — AppSettings presets**: Verify `aiPopupMaxWords` defaults to 120, `aiDashboardMaxWords` to 360, whitelist validation works (extend `AppSettingsBudgetCapTests` or add new class).
  - **Test 5 — Hash independence**: Simulate changing popup word count; assert `popupLastHash` differs from `dashboardLastHash`.
  - Keep all existing tests passing — do NOT modify existing test methods unless they reference removed properties

  **Must NOT do**:
  - Do NOT remove or modify existing test methods (unless they reference removed `aiSummaryState`)
  - Do NOT add tests that require real API calls
  - Do NOT add tests that modify production UserDefaults without cleanup

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Multi-scenario test design requiring understanding of orchestrator state machine and budget system
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `swiftui-expert-skill`: Not needed — pure XCTest logic

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6, 8)
  - **Blocks**: None
  - **Blocked By**: Task 4 (needs split state to exist)

  **References** (CRITICAL):
  - `Tests/NewsBarTests/AISummaryTests.swift:6-242` — existing `AISummaryParserTests` — test structure pattern to follow
  - `Tests/NewsBarTests/AISummaryTests.swift:246-384` — `AppSettingsBudgetCapTests` — UserDefaults snapshot/restore pattern (lines 248-260) for safe UserDefaults testing
  - `Tests/NewsBarTests/AISummaryTests.swift:388-517` — `AISummaryServiceBudgetTests` — budget test patterns: `initBudget`, `consumeAttemptBudget`, `readGenerationAttempts`
  - `Sources/NewsBar/Services/NewsOrchestrator.swift:46-56` — new split state properties (from Task 4)
  - `Sources/NewsBar/Models/AppSettings.swift` — new preset fields (from Task 1)

  **Acceptance Criteria**:
  - [ ] `swift test --filter SplitStateIntegrationTests` passes
  - [ ] Test 1 verifies state independence
  - [ ] Test 2 verifies shared budget cap enforced
  - [ ] Test 3 verifies lazy trigger guard
  - [ ] Test 4 verifies preset defaults and whitelist
  - [ ] Test 5 verifies hash independence
  - [ ] ALL existing tests still pass

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: All new split-state tests pass
    Tool: Bash (swift test)
    Preconditions: Tasks 1-6 complete
    Steps:
      1. Run: swift test --filter SplitStateIntegrationTests 2>&1
      2. Assert: All tests pass (0 failures)
    Expected Result: All split-state tests green
    Failure Indicators: Any test failure
    Evidence: .sisyphus/evidence/task-7-split-tests.txt

  Scenario: All existing tests still pass (no regression)
    Tool: Bash (swift test)
    Steps:
      1. Run: swift test 2>&1
      2. Assert: All tests pass, count matches or exceeds previous count
    Expected Result: Zero regression — all existing + new tests pass
    Failure Indicators: Previously passing test now fails
    Evidence: .sisyphus/evidence/task-7-all-tests.txt
  ```

  **Evidence to Capture**:
  - [ ] `task-7-split-tests.txt` — split-state test output
  - [ ] `task-7-all-tests.txt` — full `swift test` output

  **Commit**: YES (groups with Task 5, 6, 8)
  - Message: `feat(ai): wire split AI states to Popup and Dashboard views`
  - Files: `Tests/NewsBarTests/AISummaryTests.swift`

- [ ] 8. **README.md — document split summary behavior**

  **What to do**:
  - In the README.md "Features" section, update the AI Summary bullet point:
    - Current: `- **🤖 AI Summary** · AI 摘要 — Dual-category briefings (趋势概览 / 每日精选) with template-framework...`
    - New: `- **🤖 AI Summary** · AI 摘要 — Independently generated Popup (120 chars) and Dashboard (360 chars) dual-category briefings; shared daily API quota; Dashboard summary lazy-on-open`
  - In "Usage" section, update step 3 (AI summary description):
    - Add note: "Popup 和 Dashboard 各自独立生成 AI 摘要，Popup 默认 120 字，Dashboard 默认 360 字，可在设置中调整。两者共享每日 API 配额。"
  - In "Project Structure" section, no changes needed (file structure unchanged)

  **Must NOT do**:
  - Do NOT change version number or release date
  - Do NOT add emojis unless they follow existing pattern
  - Do NOT restructure the README

  **Recommended Agent Profile**:
  - **Category**: `writing`
    - Reason: Documentation update with precise, concise changes
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `professor-lingua`: Not needed — Chinese documentation

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6, 7)
  - **Blocks**: None
  - **Blocked By**: Task 7 (verification complete)

  **References** (CRITICAL):
  - `README.md:13` — "AI Summary" feature bullet — update this line
  - `README.md:32` — "Usage" section AI summary step — add detail here
  - `README.md:53` — "Project Structure" — no change needed but verify

  **Acceptance Criteria**:
  - [ ] Feature bullet mentions independent Popup/Dashboard generation
  - [ ] Usage section mentions default word counts (120/360)
  - [ ] Usage section mentions shared daily quota

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: README contains split summary documentation
    Tool: Bash (grep)
    Steps:
      1. Run: grep -i "120.*360\|360.*120\|popup.*dashboard\|独立生成" README.md
      2. Assert: At least one match confirming split behavior documented
    Expected Result: Documentation references independent generation
    Failure Indicators: No mention of split behavior or word counts
    Evidence: .sisyphus/evidence/task-8-readme.txt

  Scenario: No version numbers changed
    Tool: Bash (grep)
    Steps:
      1. Run: git diff README.md | grep -E "^\+.*[0-9]+\.[0-9]+\.[0-9]+"
      2. Assert: No version strings in diff additions
    Expected Result: No version changes
    Failure Indicators: Version number in diff
    Evidence: .sisyphus/evidence/task-8-version-check.txt
  ```

  **Evidence to Capture**:
  - [ ] `task-8-readme.txt` — grep output confirming split docs
  - [ ] `task-8-version-check.txt` — git diff output confirming no version changes

  **Commit**: YES (groups with Task 5, 6, 7)
  - Message: `feat(ai): wire split AI states to Popup and Dashboard views`
  - Files: `README.md`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists. For each "Must NOT Have": search codebase for forbidden patterns. Check evidence files exist.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `swift build`. Run `swift test`. Review all changed files for AI slop: empty catches, force-unwrap, unused variables, commented-out code.
  Output: `Build [PASS/FAIL] | Tests [N pass/N fail] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high`
  Execute EVERY QA scenario from EVERY task. Test cross-task integration. Test edge cases.
  Output: `Scenarios [N/N pass] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff. Verify 1:1. Check "Must NOT do" compliance.
  Output: `Tasks [N/N compliant] | VERDICT`

---

## Commit Strategy

- **Wave 1**: `feat(ai): add split Popup/Dashboard AI summary presets` — AppSettings.swift, AITab.swift, DashboardVisualComponents.swift, NewsOrchestrator.swift
- **Wave 2**: `feat(ai): wire split states and add lazy Dashboard generation` — PopoverContent.swift, AISummaryCard.swift, DashboardAIBriefingPanel.swift, AISummaryTests.swift, README.md

---

## Success Criteria

### Verification Commands
```bash
swift build -c release --arch arm64  # Expected: Build succeeded
swift test                            # Expected: All tests passed
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] `swift build` passes
- [ ] `swift test` passes
- [ ] Popup generates 120-char independently
- [ ] Dashboard generates 360-char independently
- [ ] Shared budget and lock functional
- [ ] Two-column RSS at 960pt
