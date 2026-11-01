# Dashboard Reader Shell — Design Draft

Status: approved 2026-11-01; no product code changed yet.

## Intent

Make the Dashboard reader side-pane transition safe under rapid open/close changes and visually testable at real window sizes, without loading user data or a real `WKWebView` in snapshot tests.

## Goals

- Keep the current Dashboard entry points and the existing spring/fade motion unless visual evidence justifies a narrowly scoped change.
- Isolate the production reader presentation layer so tests can inject synthetic list/reader views and drive selection changes deterministically.
- Prevent an obsolete open/dismiss task from changing the active presentation after a newer request.
- Keep obscured content out of the accessibility tree; hide the reader when it is not visually presented, and hide the decorative hero; skip hero travel under Reduce Motion.
- Capture and inspect real SwiftUI renders for compact, split, and wide window sizes.

## Non-goals / anti-goals

- Do not instantiate the full `DashboardWindow` in tests: its load task can write the real interest database and refresh log, and may migrate or clear research state.
- Do not instantiate production `NewsReaderView` in the test harness: it creates `WKWebView` and can record reading activity.
- Do not fix unrelated findings (RSS card density, dashboard localization, refresh feedback, duplicated card headers) or perform broad view extraction.
- Do not change transition timings or introduce new dependencies without evidence.

## Constraints

- macOS 15+, existing SwiftPM/XCTest and SwiftUI patterns; no new packages.
- All test data is synthetic. Snapshot output stays under ignored `.build/`.
- Keep Dashboard data loading and the real reader builder in `DashboardWindow`; the isolated presentation component must not own persistence, networking, or global store initialization.
- No system accessibility settings changes, user-data writes, or commits.

## Approaches considered

1. **Leaf-view snapshots only** — safest and smallest, but cannot exercise the integrated side-pane state and layout. Not selected because the task explicitly requires open/close, interruption, and resize coverage.
2. **Isolated presentation shell (selected)** — extract the actual side-pane layout/state boundary into a small production SwiftUI component with injected browse/reader builders and transition-origin provider. Tests use fake content, so they exercise the production geometry, state transitions, hero, and accessibility boundaries without the real data-loading task or WebKit.
3. **Render the full Dashboard / live reader** — rejected: observed side effects include writes to the user interest database and refresh log, possible research-state cleanup, and reader network/activity paths.

## Proposed behavior and boundaries

- `DashboardWindow` remains responsible for data, toolbar, sheets, root theme modifiers, and constructing production browse/reader content. Its existing load task stays attached to the production browse content, not to the extracted component.
- `DashboardReaderPresentation` owns phase, displayed request, reader visibility, hero overlay, list/reader geometry, the existing `DashboardSplitter` (behavior unchanged), and stale-task invalidation. It accepts selection/list-width bindings, theme as a small value input, and builders: browse receives phase/compact/obscured context; reader receives request/visibility. This keeps the real compact browse layout and reader visibility behavior on the production path while allowing tests to pass fake content.
- Opening a request uses a generation/request identity check after the initial yield. Dismissal finalization checks its own generation so an earlier close cannot clear a later reopen. Hero overlays are keyed by `ReaderHeroState.id`, and a completion callback may clear only the matching hero.
- In compact mode, browse content stays hidden from accessibility until the presentation returns to idle; the reader is hidden as soon as it is not visually presented. Wide split keeps the visible list accessible. The hero overlay is decorative. This can leave a short accessibility transition gap during compact dismissal; no focus-transfer redesign is included.
- The test shell receives synthetic fake content and value-based theme/scheme inputs; localized fixture strings cover zh/en. Root materials, toolbar, live RSS cards, and WebKit rendering are explicitly outside screenshot claims because they require `AppSettings`/real app services.
- No transition-style redesign is planned. Any close-layout change is conditional on screenshot evidence of the currently suspected blank/reflow state.

## Validation / acceptance

- Unit/integration-style SwiftUI tests drive: initial open; close; close then reopen before settlement; open then close before the first yielded task resumes; article replacement while open; hero replacement during flight; compact vs split geometry; Reduce Motion; resize after the reader is open.
- Snapshot the actual production shell with synthetic browse/reader content at 960×720, 1100×720, and 1180×860. Cover modern/light/en, retro/light/zh, and modern/dark/en. Include origin/mid-transition/settled captures where the host supports animation frames; otherwise record that limitation and inspect the live transition through the isolated shell rather than claiming frame coverage.
- Assert the accessibility tree for covered/invisible panes through the hosting view if its macOS accessibility representation is stable; otherwise perform and record a manual Accessibility Inspector check without changing system settings.
- Save PNGs to `.build/dashboard-reader-ui-validation/` and manually inspect every generated image for clipping, empty regions, hierarchy, and theme contrast.
- Confirm test fixtures never instantiate `DashboardWindow`, `NewsReaderView`, `InterestController.shared`, or network-backed image content.
- Run the focused test target, then `swift test`; review the final diff against this scope.

## Expected implementation files (subject to review)

- `Sources/NewsBar/Views/Dashboard/DashboardWindow.swift`
- New `Sources/NewsBar/Views/Dashboard/DashboardReaderPresentation.swift`
- `Sources/NewsBar/Views/Dashboard/ReaderHeroOverlay.swift` (accessibility semantics only, if validated)
- New `Tests/NewsBarTests/DashboardReaderPresentationRenderingTests.swift`

## Open implementation choices

- Keep the state machine in the extracted view unless a small pure transition gate is needed for deterministic race tests.
- The static snapshot matrix is required. Animation mid-frame screenshots are conditional on whether an off-screen `NSHostingView` reliably advances the actual spring; do not add flaky timing assertions to force them.
