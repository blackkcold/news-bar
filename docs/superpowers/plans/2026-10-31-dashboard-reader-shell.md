# Dashboard Reader Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` for the recommended native execution method (user review pending).

**Goal:** Isolate the Dashboard reader-pane presentation so its real open/close, interruption, resize, motion, and accessibility behavior can be tested with synthetic SwiftUI content and screenshots.

**Architecture:** Add a generic `DashboardReaderPresentation` SwiftUI shell that owns presentation phase, request visibility, hero transition, geometry, splitter, and async transition identity. `DashboardWindow` supplies the existing production browse and reader builders; XCTest supplies fake builders and selection bindings, so the real cache task and `WKWebView` are never instantiated in screenshots.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit `NSHostingView`, XCTest, existing SwiftPM targets.

**Spec:** `docs/superpowers/specs/2026-10-31-dashboard-reader-shell-design.md`

## Global Constraints

- macOS 15+; no new package dependencies.
- Tests use synthetic content and must not instantiate `DashboardWindow`, `NewsReaderView`, `InterestController.shared`, or network-backed image content.
- Keep cache loading, toolbar, sheets, and root theme modifiers in `DashboardWindow`.
- Store snapshots only under ignored `.build/dashboard-reader-ui-validation/`.
- Do not change system accessibility settings, user data, or commit.
- Preserve the existing transition timing/style unless screenshots show a specific defect.

## Review Focus

- Close, reopen, and close again before the first settle deadline: the old close must not finish the newer dismissal early; pin with `testOlderDismissalDoesNotFinishNewerDismissal`.
- Open followed by close before the first yielded task resumes: the old open must not reveal the reader; pin with `testOpenThenCloseBeforeFirstYieldDoesNotRevealReader`.
- A previous hero completing after a replacement: it must not remove the current hero; pin with `testOldHeroCompletionDoesNotClearReplacement`.
- Widths around the compact/split boundary and resizing while presented: pane frames must use current geometry; pin with `testReaderGeometryAtCompactAndSplitWidths` and `testPresentedReaderTracksWindowResize`.
- Compact dismissal restoration: the browse width must carry a structural animation transaction after the reader fade; pin with `testCompactBrowseWidthRestorationUsesAnimationTransaction`.
- Compact occlusion and Reduce Motion: hidden panes must not remain accessible and the hero must not travel; pin with `testAccessibilityVisibilityMatchesPresentedPanes` and `testReduceMotionSkipsHeroTravel`.

---

## File Structure

- Create `Sources/NewsBar/Views/Dashboard/DashboardReaderPresentation.swift`: presentation context, generic shell, generation guards, geometry, and the existing `DashboardSplitter` implementation moved without behavior change.
- Modify `Sources/NewsBar/Views/Dashboard/DashboardWindow.swift`: pass router selection/list-width bindings and existing production content builders; keep `browsePane` load task, search debounce, toolbar, and sheet behavior in the window.
- Modify `Sources/NewsBar/Views/Dashboard/ReaderHeroOverlay.swift`: mark the hero as decorative in the accessibility tree.
- Create `Tests/NewsBarTests/DashboardReaderPresentationRenderingTests.swift`: synthetic test host, race/geometry/accessibility tests, PNG snapshots, and a nonblank-image assertion.

## Task 1: Add the failing transition-shell tests

**Files:**
- Create: `Tests/NewsBarTests/DashboardReaderPresentationRenderingTests.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/ReaderHeroOverlay.swift`

**Interfaces:**
- Test harness drives `Binding<NewsReaderRequest?>` and `Binding<CGFloat>` without using `NewsNavigationRouter.shared`.
- It constructs `DashboardReaderPresentation<BrowseContent, ReaderContent>` with `transitionOriginProvider: () -> ReaderTransitionOrigin?`, `browseContent: (DashboardReaderPresentationContext) -> BrowseContent`, and `readerContent: (NewsReaderRequest, Bool) -> ReaderContent`.
- Fake browse content displays the supplied `phase`, `isReaderCompact`, and `listObscured`; fake reader content displays request title and `readerVisible` in a fixed, high-contrast frame.

- [ ] **Step 1: Write `testReaderHeroIsExcludedFromAccessibilityTree` against the existing `ReaderHeroOverlay` and a minimal static snapshot of `ReaderHeroCard`.** The hero test must check exposed accessibility labels, not screenshot pixels. If the off-screen AX tree is unavailable, mark the assertion skipped with an explicit reason and use Accessibility Inspector later.
- [ ] **Step 2: Run the focused target to confirm RED.**

Run: `swift test --filter DashboardReaderPresentationRenderingTests`

- Expected: if the off-screen AX tree is available, the accessibility assertion fails because the current hero title is exposed; the static hero images are generated. If AX is unavailable, the test reports an explicit skip and the image check still runs. Record the raw output; fix any unrelated test syntax error before proceeding.

- [ ] **Step 3: Add `.accessibilityHidden(true)` to `ReaderHeroOverlay` because it is decorative.** Do not change animation or frame behavior.
- [ ] **Step 4: Re-run the focused target to verify GREEN for the hero accessibility assertion (or confirm the explicit AX skip).**
- [ ] **Step 5: Verify the test harness uses only synthetic dependencies.** Search the new test file for production singleton, network, `AppSettings`, and database references; none may be present.

## Task 2: Implement and integrate the isolated presentation shell

**Files:**
- Create: `Sources/NewsBar/Views/Dashboard/DashboardReaderPresentation.swift`
- Modify: `Sources/NewsBar/Views/Dashboard/DashboardWindow.swift`
- Test: `Tests/NewsBarTests/DashboardReaderPresentationRenderingTests.swift`

**Interfaces:**
- `DashboardReaderPresentationContext` exposes `phase: ReaderPresentationPhase`, `isWide: Bool`, `isReaderCompact: Bool`, and `listObscured: Bool`.
- `DashboardReaderPresentation` takes `selection: Binding<NewsReaderRequest?>`, `listWidth: Binding<CGFloat>`, `isRetro: Bool`, `transitionOriginProvider: () -> ReaderTransitionOrigin?`, plus the two builders defined in Task 1.
- The shell owns `phase`, `displayedRequest`, `readerVisible`, `hero`, and a private transition generation token. The parent continues to own/bind `listWidth`.

- [ ] **Step 1: Add shell contract tests before the new type exists.** Add the named cases from Review Focus plus `testReaderShellWritesInspectableSwiftUISnapshots`. Use test-only `NewsReaderRequest`s with `https://example.invalid`, no `NewsReaderModel`, no `WKWebView`, no image URLs, and no `AppSettings`.
- [ ] **Step 2: Run the focused target to confirm RED.** Expected compiler output is limited to the missing new shell/context API. This is the intentional first failure for the new component; resolve any test syntax/import errors before proceeding.
- [ ] **Step 3: Implement the shell API and current geometry/state behavior.** Use the existing 1100pt split threshold, 9pt divider, and 320…480pt clamped list width. Move `DashboardSplitter` unchanged. Keep `readerFrame` and list-width calculations in the shell; pass context to the browse builder and `(request, readerVisible)` to the reader builder, but do not add the new generation/accessibility guards yet.
- [ ] **Step 4: Run the focused target to confirm behavioral RED.** The target must compile; stale-task, hero-replacement, and pane-visibility assertions should fail specifically, not as compiler errors. The hero accessibility assertion from Task 1 should now pass (or remain an explicit AX skip requiring manual inspection).
- [ ] **Step 5: Add task identity guards.** Increment/capture one generation token for each selection transition. After the open `Task.yield()`, require matching generation, request ID, and `.presented` phase before setting `readerVisible = true`. Before dismissal finalization, require the captured generation and `.dismissing` phase to still match.
- [ ] **Step 6: Guard hero replacement.** Apply `.id(hero.id)` to each `ReaderHeroOverlay`; its completion closure may clear only the hero with the matching ID.
- [ ] **Step 7: Apply accessibility visibility at the shell boundary.** Hide browse content while compact presentation obscures it (through dismissal until `.idle`); hide reader content whenever `readerVisible == false`; keep the list accessible in wide split.
- [ ] **Step 8: Integrate without moving data side effects.** Replace the state/geometry composition in `DashboardWindow` with the shell, pass `$router.selection`, `$listWidth`, the transition-origin provider, existing `browsePane` and `readerPane` builders, and move the splitter into the shell. Keep `.task { loadCached }`, search debounce, root theme, toolbar, and sheet behavior out of test construction and unchanged in production.
- [ ] **Step 9: Re-run the focused target to verify GREEN.**

Run: `swift test --filter DashboardReaderPresentationRenderingTests`

Expected: all runnable transition, geometry, accessibility, and render assertions pass; PNGs exist in `.build/dashboard-reader-ui-validation/`. If the AX query is unsupported off-screen, its explicit skip must be paired with the manual inspection in Task 3.

## Task 3: Inspect screenshots and close the verification loop

**Files:**
- Inspect: `.build/dashboard-reader-ui-validation/*.png` (generated, ignored)
- Verify: `Sources/NewsBar/Views/Dashboard/DashboardReaderPresentation.swift`, `DashboardWindow.swift`, `ReaderHeroOverlay.swift`, and the new test file.

- [ ] **Step 1: Capture the matrix.** Render the synthetic shell at 960×720, 1100×720, and 1180×860. Cover modern/light/zh, modern/dark/en, retro/light/zh, and a Reduce Motion case. Capture origin, settled, and dismissal states; attempt an in-flight frame without adding timing assertions that make tests flaky.
- [ ] **Step 2: Open and inspect every PNG.** Check clipping, empty/blank regions during dismissal, compact/split alignment, hero origin/target continuity, long fixture text, and theme contrast. If `NSHostingView` does not advance an animation frame, report that limitation and inspect the isolated shell in a visible fixture window; do not claim the mid-frame screenshot passed.
- [ ] **Step 3: Verify accessibility.** Assert covered/invisible content is absent from the hosting accessibility tree if that tree is stable. If it is not stable, perform a manual Accessibility Inspector check and report it as manual, not automated.
- [ ] **Step 4: Only if screenshots show the suspected compact-close blank/reflow defect, add a focused failing assertion/capture first, then apply the smallest close-layout animation adjustment and re-run the focused target.** Otherwise preserve existing close timing/layout. An off-screen `NSHostingView` reports the final `GeometryReader` size rather than an interpolated width, so its regression assertion checks the dismissal transaction and final geometry, not an intermediate width sample.
- [ ] **Step 5: Run focused and full verification.**

Run: `swift test --filter DashboardReaderPresentationRenderingTests`

Expected: PASS; actual generated image count and paths are recorded.

Run: `swift test`

Expected: exit 0; record executed/skipped/failed totals from raw output.

Run: `git diff --check && git status --short --branch && git diff --stat`

Expected: no whitespace errors; only the listed source/test files and the two design/plan documents are changed; no user data or original worktree changes.

---

## Execution Notes

- Use the native/current-session method unless the user requests delegation: the shell, tests, and screenshots share one API and must be reviewed together.
- Do not commit; the plan and implementation remain uncommitted in the isolated worktree.
