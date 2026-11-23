# 研究报告阅读器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把推荐流浮窗和研究中心的研究记录换成一个共享的「结论 → 时间线 → 核验 → 来源」简报式阅读器；来源默认折叠，引用变成可点开的 `E1` 芯片。

**Architecture:** 新增一个纯数据层 `ResearchReportMetrics` / `ResearchSourceGrouping` / `ResearchReportDisplay`，再加一个共享 SwiftUI 阅读器 `ResearchReportReader`。浮窗只保留标题、状态、变化提示和进度；研究中心把运行条、版本菜单、阅读器、底部操作条重新组合。A（单栏阅读器）先落地；B（宽窗来源栏）在详情区 ≥820pt 时出现。

**Tech Stack:** Swift 5.9、SwiftUI、macOS 15、SwiftPM、XCTest。

**Spec:** [docs/superpowers/specs/2026-11-23-research-report-reader-design.zh-CN.md](../specs/2026-11-23-research-report-reader-design.zh-CN.md)

## Global Constraints

- 基线是 `origin/main` / v3.3.1（`6e83e06`）。工作分支：`feat/research-report-reader`。
- 不改 `BurstResearch` / `ResearchRecord` / `VerificationReport` 的 Codable 字段；不改研究管线、提示词、搜索源、通知正文 80 字上限和推荐排序。
- 不新增第三方依赖。
- 新代码不使用 `try!`、`as!` 或强制解包；遵循现有 `guard` / `if let` 风格。
- 所有新 UI 文案必须同时写入 `Localized.swift` 的中英两张表；`LocalizationParityTests` 必须通过。
- 视觉沿用 `newsCardSurface`、`EditorialTag`、`EditorialActionButtonStyle`、`WorkspaceSectionHeader`、`RetroEditorialTokens`；不新造主题色。
- 浮窗不加完整版本历史菜单；保留现有「新版报告已就绪 / 查看变化」。
- 不做「关键事实」正则抽取；首屏元信息只使用 `ResearchReportMetrics` 的结构化计数。
- 来源栏阈值是详情区宽度 820pt，不是窗口宽度；默认 1180 窗口不显示来源栏。
- 保留 `WorkspaceReportMarkdown` 的现有导出字段；本计划不改复制内容。
- 每个任务结束跑对应测试；最终跑 `swift test` 和 `swift build`。

## Review Focus

- **历史版本**：`selectedVersion` 存在时必须显示该版本的 `report`，不能显示 `record.report` 的最新版；同一 digest 不能被误判为历史版本。
- **空数据**：没有 timeline、没有 evidence、没有 verification、legacy 报告、搜索失败、运行中，都不能出现空白段、错误计数或 crash。
- **核验真实性**：`claimsWithVerifiedEvidenceCount` 只统计命中了 `quoteVerified == true` 的 claim；未核验引文不能显示成已核验。
- **窄窗**：620pt 宽的浮窗里，01–04 导航、章节标题、来源摘要不能换行溢出或互相遮挡。
- **来源操作**：`E1` popover 和「打开原文」必须走现有 `NewsNavigationRouter`，不丢失报告滚动位置；关闭 popover 后仍在原段落。
- **长报告**：20 个时间线节点 + 10 个来源在 760pt 和 1180pt 下都能滚动，导航仍可达。

## File Structure

**新增**

- `Sources/NewsBar/Views/Workspace/ResearchReportMetrics.swift` — 纯计数、来源分组、历史版本选择。
- `Sources/NewsBar/Views/Workspace/ResearchReportReader.swift` — 章节枚举、导航、阅读器外壳、章节偏移跟踪。
- `Sources/NewsBar/Views/Workspace/ResearchReportSections.swift` — 结论、时间线、核验、来源四段和来源行。
- `Sources/NewsBar/Views/Workspace/ResearchSourceRail.swift` — 宽窗来源栏（Task 6）。
- `Tests/NewsBarTests/ResearchReportMetricsTests.swift`
- `Tests/NewsBarTests/ResearchReportReaderRenderingTests.swift`
- `Tests/NewsBarTests/WorkspacePresentationStoreTests.swift`

**修改**

- `Sources/NewsBar/Views/Workspace/WorkspaceReportBody.swift` — 保留章节 chrome 与 Markdown；`WorkspaceReportBody` 改为阅读器薄包装。
- `Sources/NewsBar/Views/Workspace/TransientResearchReportView.swift` — 删除 80 字结论；接阅读器；历史版本修复；头部动作。
- `Sources/NewsBar/AppDelegate.swift` — 浮窗 760×760 / 最小 620×560；传 `onOpenWorkspace`。
- `Sources/NewsBar/Views/Workspace/WorkspaceResearchPane.swift` — 运行条 + 版本菜单 + 阅读器 + 底部操作条；宽窗来源栏。
- `Sources/NewsBar/Views/Workspace/WorkspaceDetailView.swift` — 默认报告 tab；事件时间线入口；分段标签。
- `Sources/NewsBar/Views/Workspace/WorkspacePresentationStore.swift` — `hasChosenSegment`。
- `Sources/NewsBar/Models/Localized.swift` — `research.report.*`；`workspace.detail.research` 值。
- `docs/research-center.zh-CN.md` / `docs/research-center.md` — 报告阅读器说明（Task 7）。

---

### Task 0: Preflight

**Files:** none

- [ ] **Step 1: Confirm base**

Run: `git log --oneline -1 && git status --short`
Expected: HEAD is `6e83e06` (or a descendant); only untracked screenshots / `.openchamber` / `.playwright-mcp` are allowed.

- [ ] **Step 2: Baseline build**

Run: `swift build`
Expected: exit 0. If it fails before any edit, stop and report; do not fix unrelated code.

- [ ] **Step 3: Baseline tests**

Run: `swift test`
Expected: record any pre-existing failures. Do not fix unrelated failures; the final report must separate them.

---

### Task 1: Metrics, source grouping, historical report display

**Files:**
- Create: `Sources/NewsBar/Views/Workspace/ResearchReportMetrics.swift`
- Test: `Tests/NewsBarTests/ResearchReportMetricsTests.swift`

**Interfaces:**
- Consumes: `BurstResearch`, `EvidenceItem`, `VerificationReport`, `ClaimCheck`, `TimelineNode`, `ResearchRecord`, `WorkspaceReportVersion`, `WorkspaceReportDigest`.
- Produces:
  - `ResearchReportMetrics(report: BurstResearch)` with `evidenceCount`, `verifiedQuoteCount`, `domainCount`, `claimCount`, `claimsWithVerifiedEvidenceCount`, `claimsNeedingEvidenceCount`, `conflictCount`, `missingCount`, `timelineNodeCount`, `timelineSpanDays`, `independentSourceCount`.
  - `ResearchSourceGroup { let domain: String; let items: [EvidenceItem] }`
  - `ResearchSourceGrouping.groups(for: [EvidenceItem]) -> [ResearchSourceGroup]`
  - `ResearchReportDisplay.report(selectedVersion: WorkspaceReportVersion?, record: ResearchRecord?) -> BurstResearch?`
  - `ResearchReportDisplay.isHistorical(selectedVersion: WorkspaceReportVersion?, record: ResearchRecord?) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `ResearchReportMetricsTests.swift` with these assertions. Build the fixture with `EvidenceItem`, `ClaimCheck`, `TimelineNode`, and `VerificationReport` memberwise initializers.

```swift
import XCTest
@testable import NewsBar

final class ResearchReportMetricsTests: XCTestCase {
    func testCountsVerifiedQuotesClaimsAndDomains() {
        let metrics = ResearchReportMetrics(report: makeReport())
        XCTAssertEqual(metrics.evidenceCount, 3)
        XCTAssertEqual(metrics.verifiedQuoteCount, 2)
        XCTAssertEqual(metrics.domainCount, 2)
        XCTAssertEqual(metrics.claimCount, 4)
        XCTAssertEqual(metrics.claimsWithVerifiedEvidenceCount, 1)
        XCTAssertEqual(metrics.claimsNeedingEvidenceCount, 3)
        XCTAssertEqual(metrics.conflictCount, 1)
        XCTAssertEqual(metrics.missingCount, 2)
        XCTAssertEqual(metrics.timelineNodeCount, 2)
        XCTAssertEqual(metrics.timelineSpanDays, 4)
        XCTAssertEqual(metrics.independentSourceCount, 5)
    }

    func testEmptyReportHasZeroCountsAndNoSpan() {
        let metrics = ResearchReportMetrics(report: BurstResearch())
        XCTAssertEqual(metrics.evidenceCount, 0)
        XCTAssertEqual(metrics.timelineNodeCount, 0)
        XCTAssertNil(metrics.timelineSpanDays)
        XCTAssertEqual(metrics.claimsNeedingEvidenceCount, 0)
    }

    func testSourceGroupsSortByCountThenDomainAndNaturalID() {
        let groups = ResearchSourceGrouping.groups(for: makeEvidence())
        XCTAssertEqual(groups.map(\.domain), ["a.example", "b.example"])
        XCTAssertEqual(groups[0].items.map(\.id), ["E2", "E10"])
    }

    func testHistoricalVersionUsesSelectedReportAndDigest() {
        let latest = researchTestRecord(title: "topic", report: BurstResearch(summary: "new"))
        let oldReport = BurstResearch(summary: "old")
        let version = WorkspaceReportVersion(
            id: "\(latest.id)#1",
            recordID: latest.id,
            subjectID: "subject-1",
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            trigger: .manual,
            report: oldReport,
            digest: WorkspaceReportDigest.make(oldReport)
        )
        XCTAssertEqual(ResearchReportDisplay.report(selectedVersion: version, record: latest)?.summary, "old")
        XCTAssertTrue(ResearchReportDisplay.isHistorical(selectedVersion: version, record: latest))
        XCTAssertEqual(ResearchReportDisplay.report(selectedVersion: nil, record: latest)?.summary, "new")
        XCTAssertFalse(ResearchReportDisplay.isHistorical(selectedVersion: nil, record: latest))
    }
}
```

Fixture requirements for `makeReport()`:

- Evidence `E2` verified domain `a.example`; `E10` verified domain `a.example`; `E3` unverified domain `b.example`.
- Claims: `C1 [E2]`, `C2 [E3]`, `C3 []`, `C4 ["E99"]`.
- `verification.independentSources = 5`, `verdict = .mixed`, `conflicts = ["conflict"]`, `missing = ["m1", "m2"]`.
- Timeline nodes with `sortDate` day 1 and day 5; one node with `sortDate: nil` can be added to prove it is ignored for span.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ResearchReportMetricsTests`
Expected: FAIL because `ResearchReportMetrics`, `ResearchSourceGrouping`, `ResearchReportDisplay` are undefined.

- [ ] **Step 3: Implement the pure layer**

Create `ResearchReportMetrics.swift`.

Rules:
- Build `evidenceByID` with `Dictionary(..., uniquingKeysWith: { first, _ in first })`.
- `claimsWithVerifiedEvidenceCount` = claims where any cited ID maps to `quoteVerified == true`.
- `timelineSpanDays` = `max(0, Calendar(identifier: .gregorian).dateComponents([.day], from: minDate, to: maxDate).day ?? 0)` using only non-nil `sortDate`; `nil` if fewer than 2 dated nodes.
- `ResearchSourceGrouping.groups(for:)`: group by `domain`; sort groups by item count descending, then domain ascending; sort items by numeric ID suffix (`E2` before `E10`), then raw ID.
- `ResearchReportDisplay.report` returns `selectedVersion?.report ?? record?.report`.
- `ResearchReportDisplay.isHistorical` returns `false` when `selectedVersion == nil` or `record?.report == nil`; otherwise compare `WorkspaceReportDigest.make(selectedVersion.report)` with `WorkspaceReportDigest.make(record.report)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ResearchReportMetricsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NewsBar/Views/Workspace/ResearchReportMetrics.swift Tests/NewsBarTests/ResearchReportMetricsTests.swift
git commit -m "feat(research): add report metrics and source grouping"
```

---

### Task 2: Reader shell, conclusion, timeline

**Files:**
- Create: `Sources/NewsBar/Views/Workspace/ResearchReportReader.swift`
- Create: `Sources/NewsBar/Views/Workspace/ResearchReportSections.swift`
- Test: `Tests/NewsBarTests/ResearchReportReaderRenderingTests.swift`

**Interfaces:**
- Consumes: `ResearchReportMetrics`, `ReportPresentation`, `ResearchEvidenceChip`, `WorkspaceSectionHeader`, `AppSettings`, `NewsNavigationRouter`.
- Produces:
  - `ResearchReportSection: String, CaseIterable, Identifiable, Sendable` with `.conclusion`, `.timeline`, `.verification`, `.sources`.
  - `ResearchReportReader`:
    ```swift
    struct ResearchReportReader: View {
        let report: BurstResearch
        let contextID: String?
        var isHistorical: Bool = false
        var isLegacy: Bool = false
        var showsSourceSection: Bool = true
        let onOpenURL: (String, String) -> Void
        var onOpenEventTimeline: (() -> Void)? = nil
        var topContent: AnyView? = nil
    }
    ```
  - `ResearchReportConclusionSection` and `ResearchReportTimelineSection` with internal initializers used by the reader.

- [ ] **Step 1: Write the failing rendering test**

Create `ResearchReportReaderRenderingTests.swift`. Use the same `NSHostingView` / `bitmapImageRepForCachingDisplay` pattern as `ResearchCenterRenderingTests`.

Test names and assertions:

```swift
func testReaderRendersAcrossSizesAndThemes() throws
func testReaderRendersEmptyTimeline() throws
```

- `testReaderRendersAcrossSizesAndThemes`: for `AppTheme.allCases` × sizes `[620×560, 760×760]`, render a report with summary, 3 timeline nodes, no verification, no evidence. Assert PNG data > 2,000 bytes and bitmap size >= the requested size.
- `testReaderRendersEmptyTimeline`: render a report with summary and empty timeline. Assert PNG data > 2,000 bytes.
- Write output to `researchTestDirectory().appendingPathComponent("report-reader-render-matrix")`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ResearchReportReaderRenderingTests`
Expected: FAIL because `ResearchReportReader` is undefined.

- [ ] **Step 3: Implement the reader shell and the two sections**

`ResearchReportReader.swift`:
- `ResearchReportSection.title` must use literal keys in a switch, not string interpolation:
  - `.conclusion` → `"research.report.nav.conclusion".localized`
  - `.timeline` → `"research.report.nav.timeline".localized`
  - `.verification` → `"research.report.nav.verification".localized`
  - `.sources` → `"research.report.nav.sources".localized`
- `var sections: [ResearchReportSection]` is internal for tests. In this task return `[.conclusion, .timeline]`.
- Body is `ScrollViewReader { proxy in VStack(spacing: 0) { ResearchReportNavigator(...); Divider(); ScrollView { if let topContent { topContent }; sections } } }`.
- Navigator uses a segmented `Picker` bound to `activeSection`; `onSelect` sets `activeSection` and calls `proxy.scrollTo(section.id, anchor: .top)` inside `withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18))`.
- Each section has `.id(section.id)` and a `SectionOffsetReader` background.
- `ResearchReportSectionOffsetKey` is a `PreferenceKey` with `[ResearchReportSection: CGFloat]`.
- `updateActiveSection`: choose the last section whose `minY <= 12`; if the scroll is at the bottom, choose the last section; otherwise keep the first.
- The ScrollView uses `.coordinateSpace(name: "researchReportScroll")`.
- Navigation labels are `01 结论` / `02 时间线` / `03 核验` / `04 来源`; do not put the source count in the segment label.

`ResearchReportSections.swift`:
- `ResearchReportConclusionSection`:
  - Section header index `"01"`, title `"research.report.nav.conclusion".localized`.
  - Full `report.summary` at 14pt, lineSpacing 2, `.textSelection(.enabled)`.
  - Meta strip from `ResearchReportMetrics`: timeline node count (+ span if present), source/domain count, verified quote count, independent source count.
  - If `metrics.missingCount > 0`, an amber strip: first 2 `verification.missing` items and `+N`.
  - If `report.overview` is not empty, a `DisclosureGroup` labeled `"research.report.overview"`; default expanded only when `report.summary` is empty.
  - If `isLegacy`, a small `"research.report.legacy.note"` note.
  - If `report.searchStatus == .failed`, a small `"research.report.searchFailed"` note.
- `ResearchReportTimelineSection`:
  - Section header index `"02"`, trailing `"research.report.timeline.count"` with node count and span (or just count).
  - Build `ReportPresentation(report: report, isLegacy: isLegacy)`.
  - Coverage line: verified node count / total, plus unsourced count.
  - Each node row: date, state dot (verified = accent; citedUnverified = orange dashed; unsourced = secondary), title, detail, `ResearchEvidenceChip` for each resolved evidence.
  - Empty state: `"research.report.timeline.empty.title"` + body; if `onOpenEventTimeline != nil`, a button `"research.report.timeline.empty.action"`.

Add the keys used in this task to both zh/en tables now (do not wait for Task 7): `research.report.nav.conclusion`, `.timeline`, `.verification` (placeholder for Task 3), `.sources` (placeholder), `research.report.meta.sources`, `.quotes`, `.timeline`, `.timelineNoSpan`, `.independentSources`, `research.report.overview`, `research.report.missing.summary`, `.more`, `research.report.timeline.count`, `.coverage`, `.unsourced`, `.empty.title`, `.empty.body`, `.empty.action`, `research.report.legacy.note`, `research.report.searchFailed`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ResearchReportReaderRenderingTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NewsBar/Views/Workspace/ResearchReportReader.swift Sources/NewsBar/Views/Workspace/ResearchReportSections.swift Tests/NewsBarTests/ResearchReportReaderRenderingTests.swift
git commit -m "feat(research): add shared report reader with conclusion and timeline"
```

---

### Task 3: Verification and source index

**Files:**
- Modify: `Sources/NewsBar/Views/Workspace/ResearchReportSections.swift`
- Modify: `Sources/NewsBar/Views/Workspace/ResearchReportReader.swift`
- Modify: `Tests/NewsBarTests/ResearchReportReaderRenderingTests.swift`

**Interfaces:**
- Consumes: `ResearchReportMetrics`, `ResearchSourceGroup`, `ResearchEvidenceChip`, `VerificationReport`, `EvidenceItem`.
- Produces:
  - `ResearchReportVerificationSection`
  - `ResearchReportSourceSection`
  - `ResearchSourceRow`
  - `ResearchReportReader.sections` now includes `.verification` and `.sources` when data exists.

- [ ] **Step 1: Write the failing section tests**

Extend `ResearchReportReaderRenderingTests.swift`:

```swift
func testSectionsIncludeVerificationAndSourcesWithEvidence() {
    let reader = ResearchReportReader(
        report: makeReportWithClaimsAndEvidence(),
        contextID: "record-1",
        onOpenURL: { _, _ in }
    )
    XCTAssertEqual(reader.sections, [.conclusion, .timeline, .verification, .sources])
}

func testSectionsHideVerificationAndSourcesWhenEmpty() {
    let reader = ResearchReportReader(
        report: BurstResearch(summary: "only summary"),
        contextID: nil,
        onOpenURL: { _, _ in }
    )
    XCTAssertEqual(reader.sections, [.conclusion, .timeline])
}

func testReaderRendersClaimsAndCollapsedSources() throws { /* render and assert PNG > 2,000 */ }
func testReaderRendersLegacyReport() throws { /* isLegacy: true, render and assert PNG > 2,000 */ }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ResearchReportReaderRenderingTests`
Expected: FAIL because `sections` only returns conclusion/timeline and the new views are undefined.

- [ ] **Step 3: Implement verification and sources**

`ResearchReportVerificationSection`:
- Section header index `"03"`, title `"research.report.nav.verification"`.
- Verdict row: `EditorialTag` with the verdict; `Text` with `"research.report.claimsSummary"` using `claimCount`, `claimsWithVerifiedEvidenceCount`, `claimsNeedingEvidenceCount`. If `verdict == .unverified`, add a `help` tooltip with `"research.report.verdict.unverifiedHelp"`.
- Claims: one `DisclosureGroup` per claim. Label: status icon (`supports` check, `refutes` xmark, `unclear`/`nil` question), claim text, evidence count (`"research.report.claims.count"` or `"research.report.claims.noEvidence"`). Content: note and `ResearchEvidenceChip` for each cited ID. Use a `Set<String>` of expanded claim IDs.
- Conflicts: if non-empty, `DisclosureGroup` labeled `"research.report.conflicts"` with count; content is a bullet list.
- Missing: if non-empty, `DisclosureGroup` labeled `"research.report.missing.title"` with count; content is a bullet list.
- Limitations: if non-empty, a small `"research.report.limitations"` label + secondary text.
- If `verification == nil`, show `"research.report.legacy.note"` when `isLegacy`; otherwise render nothing in this section.

`ResearchReportSourceSection`:
- Section header index `"04"`, title `"research.report.nav.sources"`, trailing evidence count.
- Summary button: `"research.report.sources.summary"` with evidence count, domain count, verified quote count; chevron rotates when expanded; `accessibilityValue` expanded/collapsed.
- When expanded, `ForEach(ResearchSourceGrouping.groups(for: report.evidence))`: domain header + count; `ResearchSourceRow` for each item.
- `ResearchSourceRow` is a `DisclosureGroup`:
  - Label: `E1`, title (2 lines), verified badge (green/orange).
  - Content: quote in secondary text, `domain · stance · T2`, and an `Button("research.report.source.open")` calling `onOpenURL(item.url, title)`.
  - Do not nest a button inside the DisclosureGroup label.

`ResearchReportReader`:
- `sections` returns:
  ```swift
  var result: [ResearchReportSection] = [.conclusion, .timeline]
  if report.verification != nil || !report.evidence.isEmpty { result.append(.verification) }
  if showsSourceSection && !report.evidence.isEmpty { result.append(.sources) }
  return result
  ```
- Pass `metrics`, `groups`, `contextID`, `onOpenURL`, `onOpenEventTimeline` to the sections.
- Add `WorkspaceReportBody` compatibility: replace the old `WorkspaceReportBody.body` (summary/overview/claims/evidence) with a thin `ResearchReportReader(report:isHistorical:onOpenURL:)` call. Keep `WorkspaceSectionHeader`, `WorkspaceOriginBadge`, `WorkspaceVerificationBadge`, and `WorkspaceReportMarkdown` in the file. Do not delete the type; Task 4/5 use the reader directly for `contextID` and `onOpenEventTimeline`.
- Add the keys used in this task to both zh/en tables now: `research.report.claimsSummary`, `research.report.claims.count`, `research.report.claims.noEvidence`, `research.report.conflicts`, `research.report.missing.title`, `research.report.limitations`, `research.report.sources.summary`, `research.report.sources.expand`, `research.report.sources.collapse`, `research.report.source.open`, `research.report.verdict.unverifiedHelp`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ResearchReportReaderRenderingTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NewsBar/Views/Workspace/ResearchReportReader.swift Sources/NewsBar/Views/Workspace/ResearchReportSections.swift Tests/NewsBarTests/ResearchReportReaderRenderingTests.swift
git commit -m "feat(research): add report verification and source index"
```

---

### Task 4: Research panel integration

**Files:**
- Modify: `Sources/NewsBar/Views/Workspace/TransientResearchReportView.swift:231-575`
- Modify: `Sources/NewsBar/AppDelegate.swift:1229-1248`

**Interfaces:**
- Consumes: `ResearchReportReader`, `ResearchReportDisplay`, `WorkspaceReportMarkdown`, `AppSettings`.
- Produces:
  - `TransientResearchReportView` requires `onOpenWorkspace: () -> Void`.
  - Panel default size `760×760`; minimum `620×560`.
  - `ResearchReportReader` gains `var topContent: AnyView? = nil` so the popup's「本次变化」block scrolls with the report instead of occupying fixed height.

- [ ] **Step 1: Fix the displayed report first**

In `TransientResearchReportView`, replace the current `report` computed property usage with:

```swift
private var displayedReport: BurstResearch? {
    ResearchReportDisplay.report(selectedVersion: model.selectedVersion, record: model.record)
}
private var isHistoricalReport: Bool {
    ResearchReportDisplay.isHistorical(selectedVersion: model.selectedVersion, record: model.record)
}
```

The report body must use `displayedReport`, not `record.report`. This is the historical-version bug fix.

- [ ] **Step 2: Rebuild the panel body**

`body` becomes:

```swift
VStack(spacing: 0) {
    header
    Divider()
    if model.availableRecord != nil {
        updateAvailableBanner
        Divider()
    }
    if let record = model.record, record.status.isActive {
        progressDisclosure(record)
        Divider()
    }
    if !model.didLoad {
        ProgressView(...)
    } else if let record = model.record, let report = displayedReport {
        let changes: AnyView? = {
            guard model.isShowingChanges,
                  let previous = model.previousVersion,
                  let current = model.selectedVersion else { return nil }
            return AnyView(versionComparison(previous: previous, current: current))
        }()
        ResearchReportReader(
            report: report,
            contextID: record.id,
            isHistorical: isHistoricalReport,
            isLegacy: record.reportVersion == 0,
            onOpenURL: openEvidenceURL,
            onOpenEventTimeline: onOpenWorkspace,
            topContent: changes
        )
    } else if let event = model.event {
        eventContent(event)
    } else {
        unavailable
    }
}
```

- Remove `reportContent(_:)` and the `ResearchNotificationSummary.make` call / `"当前结论"` card.
- Keep `progressDisclosure`, `updateAvailableBanner`, `versionComparison`, `eventContent`, `unavailable`, `sourceFallbackButton`.
- Header:
  - Title: `model.event?.title ?? model.record?.topic ?? "研究报告"`.
  - Meta: status label + `"核验于 / 更新于"` from `report.generatedAt ?? record.updatedAt` (if no displayed report, use status only).
  - Actions: `Button("在研究中心打开")` calling `onOpenWorkspace` (disabled when `model.recordID == nil`); a `Menu` with `"复制 Markdown"` (uses `WorkspaceReportMarkdown.make(report:subjectTitle:versionLabel:)`, disabled when `displayedReport == nil`) and `"关闭"`; keep the close button if the menu is not used. The empty-timeline action uses the same `onOpenWorkspace` closure.
  - Do not show a fake `V3` label; the transient model does not load version history.
- Add the `onOpenWorkspace` parameter to the view's initializer. Keep `onClose`.
- Change the view's outer frame to `.frame(minWidth: 620, minHeight: 560)`.
- Add the keys used in this task to both zh/en tables now: `research.report.openWorkspace`, `research.report.copy`.

- [ ] **Step 3: Update AppDelegate**

At `AppDelegate.swift:1229`:
- `NSSize(width: 760, height: 760)`.
- `panel.minSize = NSSize(width: 620, height: 560)`.
- Pass:
  ```swift
  onOpenWorkspace: { [weak self] in
      guard let self, let recordID = self.transientResearchModel?.recordID else { return }
      self.openResearchWorkspace(recordID: recordID)
  }
  ```

- [ ] **Step 4: Compile and manually verify**

Run: `swift build`
Expected: exit 0.

Manual:
1. Open a recommendation card with 「有深研」.
2. Confirm the popup opens at 760×760, shows the full summary and at least 2 timeline nodes without scrolling.
3. Confirm there is no truncated 80-character conclusion.
4. Click `E1`; confirm the source card opens and the report scroll position does not change.
5. Click 「在研究中心打开」; confirm the workspace opens the same record.
6. Resize to 620×560; confirm nav and section headers do not clip.

- [ ] **Step 5: Commit**

```bash
git add Sources/NewsBar/Views/Workspace/TransientResearchReportView.swift Sources/NewsBar/AppDelegate.swift
git commit -m "feat(research): use report reader in the research panel"
```

---

### Task 5: Research workspace integration

**Files:**
- Modify: `Sources/NewsBar/Views/Workspace/WorkspacePresentationStore.swift`
- Modify: `Sources/NewsBar/Views/Workspace/WorkspaceDetailView.swift:40-46,367-441`
- Modify: `Sources/NewsBar/Views/Workspace/WorkspaceResearchPane.swift:41-88,182-268,272-322`
- Modify: `Sources/NewsBar/Views/Workspace/WorkspaceReportBody.swift` (delete the now-unused `WorkspaceReportBody` wrapper; keep chrome + Markdown)
- Modify: `Sources/NewsBar/Models/Localized.swift` (`workspace.detail.research` only; report keys added by earlier tasks)
- Test: `Tests/NewsBarTests/WorkspacePresentationStoreTests.swift`

**Interfaces:**
- Consumes: `ResearchReportReader`, `WorkspaceReportVersion`, `WorkspaceReportDigest`.
- Produces:
  - `WorkspacePresentationStore.hasChosenSegment(for:) -> Bool`.
  - `WorkspaceResearchPane` initializer gains `onRequestSegment: (WorkspaceSegment) -> Void`.
  - `WorkspaceSegment.research` displays 「报告」/「Report」.

- [ ] **Step 1: Write the failing store test**

Create `WorkspacePresentationStoreTests.swift`:

```swift
import XCTest
@testable import NewsBar

@MainActor
final class WorkspacePresentationStoreTests: XCTestCase {
    func testNewSubjectHasNoChosenSegment() {
        let store = WorkspacePresentationStore()
        XCTAssertFalse(store.hasChosenSegment(for: "subject-1"))
        XCTAssertEqual(store.segment(for: "subject-1"), .overview)
    }

    func testSetSegmentMarksChosen() {
        let store = WorkspacePresentationStore()
        store.setSegment(.research, for: "subject-1")
        XCTAssertTrue(store.hasChosenSegment(for: "subject-1"))
        XCTAssertEqual(store.segment(for: "subject-1"), .research)
    }

    func testSelectingCurrentSegmentMarksChosen() {
        let store = WorkspacePresentationStore()
        store.setSegment(.overview, for: "subject-1")
        XCTAssertTrue(store.hasChosenSegment(for: "subject-1"))
        XCTAssertEqual(store.segment(for: "subject-1"), .overview)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WorkspacePresentationStoreTests`
Expected: FAIL because `hasChosenSegment` is undefined.

- [ ] **Step 3: Add the flag and the default-tab rule**

`WorkspacePresentationStore.State`:
```swift
var segment: WorkspaceSegment = .overview
var hasChosenSegment = false
```
`setSegment` must mark the segment as chosen even when the value is unchanged (the user may tap the already-selected 「概览」):
```swift
func setSegment(_ segment: WorkspaceSegment, for subjectID: String) {
    guard !subjectID.isEmpty else { return }
    var current = state(for: subjectID)
    let changed = current.segment != segment || !current.hasChosenSegment
    current.segment = segment
    current.hasChosenSegment = true
    guard changed else { return }
    states[subjectID] = current
}
```
Add:
```swift
func hasChosenSegment(for subjectID: String) -> Bool {
    state(for: subjectID).hasChosenSegment
}
```

`WorkspaceDetailView.applySegmentRequestIfPossible()`:
```swift
guard !subjectID.isEmpty else { return }
if let request = model.segmentRequest, handledSegmentRequestID != request.id {
    handledSegmentRequestID = request.id
    model.presentation.setSegment(request.segment, for: subjectID)
    return
}
guard !model.presentation.hasChosenSegment(for: subjectID),
      let detail = model.detail,
      detail.research?.report != nil else { return }
model.presentation.setSegment(.research, for: subjectID)
```
Keep both `.onChange` triggers (`segmentRequest` and `detail?.subject.id`). The `initial: true` call with an empty subject returns early.

- [ ] **Step 4: Rebuild the research pane**

`WorkspaceResearchPane`:
- Add `let onRequestSegment: (WorkspaceSegment) -> Void`.
- Keep `runSection`, but add a trailing `versionMenu`:
  ```swift
  Menu {
      ForEach(versions) { version in
          Button {
              model.presentation.setSelectedVersionID(version.id, for: detail.subject.id)
          } label: {
              if displayedVersion?.id == version.id {
                  Label(versionTitle(version), systemImage: "checkmark")
              } else {
                  Text(versionTitle(version))
              }
          }
      }
      if isHistorical {
          Divider()
          Button("workspace.research.viewLatest".localized) {
              model.presentation.setSelectedVersionID(nil, for: detail.subject.id)
          }
      }
  } label: {
      Label(displayedVersion.map { "V\($0.sequence)" } ?? "workspace.report.legacy".localized,
            systemImage: "clock.arrow.circlepath")
  }
  ```
  Show the menu only when `!versions.isEmpty`. Add:
  ```swift
  private func versionTitle(_ version: WorkspaceReportVersion) -> String {
      "V\(version.sequence) · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))"
  }
  ```
  Remove `versionSection` and `versionRow`.
- Body becomes:
  ```swift
  VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
          runSection
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 10)
      Divider()
      if let report = displayedReport {
          ResearchReportReader(
              report: report,
              contextID: record?.id,
              isHistorical: isHistorical,
              isLegacy: record?.reportVersion == 0,
              onOpenURL: { url, title in model.openEvidenceURL(url, title: title) },
              onOpenEventTimeline: { onRequestSegment(.timeline) }
          )
      } else {
          Text("workspace.research.noReport".localized)
          ...
      }
      Divider()
      footer
  }
  ```
- `footer` becomes a fixed bar below the reader with the existing start/force/depth/copy actions; remove the old `ScrollView` and `.scrollPosition` anchor binding. The reader owns scrolling.
- Remove the `research.top`, `research.run`, `research.versions`, `research.report`, `research.footer` anchors; no other view depends on them (the reader has its own section ids).
- After both call sites use `ResearchReportReader` (Task 4 popup, this task workspace), delete the `WorkspaceReportBody` wrapper struct. Keep `WorkspaceSectionHeader`, `WorkspaceOriginBadge`, `WorkspaceVerificationBadge`, and `WorkspaceReportMarkdown` in the file; the file name can stay.

- [ ] **Step 5: Update the tab label and the detail call site**

`Localized.swift`:
- `"workspace.detail.research"`: zh `"报告"`, en `"Report"`.
- Do **not** rename `"workspace.detail.timeline"`; keep `"时间线"` / `"Timeline"` to avoid a 4-segment label that is too wide.
- Do **not** reorder `WorkspaceSegment.allCases`; keep the existing tab order (overview / timeline / evidence / research). The mockup's 报告/依据 order is illustrative; changing tab positions would be an unrelated muscle-memory change.

`WorkspaceDetailView.panes`:
```swift
WorkspaceResearchPane(
    model: model,
    detail: detail,
    onStart: { force, depth in ... },
    onRequestSegment: { model.presentation.setSegment($0, for: detail.subject.id) }
)
```

- [ ] **Step 6: Run tests and compile**

Run: `swift test --filter WorkspacePresentationStoreTests`
Expected: PASS (2 tests).

Run: `swift test --filter LocalizationParityTests`
Expected: PASS.

Run: `swift build`
Expected: exit 0.

Manual:
1. Open the workspace at the default 1180 width with a subject that has a report.
2. Confirm it lands on 「报告」 when no tab was chosen; switch to 「概览」 and back, confirm the choice sticks.
3. Confirm the version menu changes the displayed report; history versions show the read-only label.
4. Confirm the bottom action bar (start/update/depth/copy) is fixed and usable.
5. Confirm the timeline tab still shows the merged event/research timeline.

- [ ] **Step 7: Commit**

```bash
git add Sources/NewsBar/Views/Workspace/WorkspacePresentationStore.swift Sources/NewsBar/Views/Workspace/WorkspaceDetailView.swift Sources/NewsBar/Views/Workspace/WorkspaceResearchPane.swift Sources/NewsBar/Views/Workspace/WorkspaceReportBody.swift Sources/NewsBar/Models/Localized.swift Tests/NewsBarTests/WorkspacePresentationStoreTests.swift
git commit -m "feat(workspace): use report reader in the research workspace"
```

---

### Task 6: Wide source rail (Phase B)

**Files:**
- Create: `Sources/NewsBar/Views/Workspace/ResearchSourceRail.swift`
- Modify: `Sources/NewsBar/Views/Workspace/WorkspaceResearchPane.swift`
- Modify: `Tests/NewsBarTests/ResearchReportReaderRenderingTests.swift`

**Interfaces:**
- Consumes: `ResearchSourceGroup`, `ResearchReportMetrics`.
- Produces:
  - `ResearchSourceRail(groups:metrics:onOpenURL:)`
  - `WorkspaceResearchPane` measures its width and shows the rail at `>= 820`.

- [ ] **Step 1: Write the failing rail render test**

Extend `ResearchReportReaderRenderingTests.swift`:

```swift
func testSourceRailRendersAtWideLayoutWidth() throws {
    let groups = ResearchSourceGrouping.groups(for: makeEvidence())
    let view = ResearchSourceRail(
        groups: groups,
        metrics: ResearchReportMetrics(report: makeReport()),
        onOpenURL: { _, _ in }
    )
    .environment(settings)
    .frame(width: 220, height: 600)
    // render with NSHostingView; assert PNG data > 2,000
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ResearchReportReaderRenderingTests`
Expected: FAIL because `ResearchSourceRail` is undefined.

- [ ] **Step 3: Implement the rail and the width switch**

`ResearchSourceRail`:
- Header: `L10n.string("research.report.meta.sources", metrics.evidenceCount, metrics.domainCount)`; do not hardcode Chinese.
- ScrollView of groups: domain header + count; rows are compact `Button`s showing `E1`, title (1 line), verified dot; click calls `onOpenURL(item.url, item.title)`.
- Width 220; background `.background`; leading `Divider`.
- No cross-highlight; the reader's `E1` popover remains the quote view.

`WorkspaceResearchPane`:
```swift
@State private var showsSourceRail = false

HStack(spacing: 0) {
    ResearchReportReader(
        ...,
        showsSourceSection: !showsSourceRail,
        ...
    )
    if showsSourceRail {
        Divider()
        ResearchSourceRail(
            groups: ResearchSourceGrouping.groups(for: report.evidence),
            metrics: ResearchReportMetrics(report: report),
            onOpenURL: { url, title in model.openEvidenceURL(url, title: title) }
        )
        .frame(width: 220)
    }
}
.onGeometryChange(for: CGFloat.self) { proxy in
    proxy.size.width
} action: { width in
    showsSourceRail = width >= 820
}
```
Place the `onGeometryChange` on the pane's outer container. At the default 1180 window the detail width is ~630, so the rail stays hidden; at ~1600 it appears.

When `showsSourceSection` flips to `false`, `ResearchReportReader` must clamp `activeSection` if the current value is `.sources`:
```swift
private func clampActiveSection() {
    if !sections.contains(activeSection) {
        activeSection = sections.last ?? .conclusion
    }
}
```
Call it from `.onChange(of: showsSourceSection)` (not from `body`; state must not mutate during body evaluation). The navigator must never hold a selection that is absent from its options.

- [ ] **Step 4: Run test and compile**

Run: `swift test --filter ResearchReportReaderRenderingTests`
Expected: PASS.

Run: `swift build`
Expected: exit 0.

Manual:
1. Open the workspace at 1180 width: no rail; the report has the collapsed 04 来源 section.
2. Resize to 1600: rail appears; the report hides 04 来源; the rail scrolls independently.
3. Resize back to 1180: rail disappears; 04 来源 returns.

- [ ] **Step 5: Commit**

```bash
git add Sources/NewsBar/Views/Workspace/ResearchSourceRail.swift Sources/NewsBar/Views/Workspace/WorkspaceResearchPane.swift Tests/NewsBarTests/ResearchReportReaderRenderingTests.swift
git commit -m "feat(workspace): add wide report source rail"
```

---

### Task 7: Localization, accessibility, acceptance, docs

**Files:**
- Modify: `Sources/NewsBar/Models/Localized.swift`
- Modify: `docs/research-center.zh-CN.md`
- Modify: `docs/research-center.md`

**Interfaces:**
- Consumes: all `research.report.*` keys from Tasks 2–6.
- Produces: complete zh/en strings; docs.

- [ ] **Step 1: Audit the localization table**

Tasks 2–4 add their keys as they go. This step is the audit: run the parity/lint tests, compare the list below, and add any missing value. Minimum set:

```text
research.report.nav.conclusion
research.report.nav.timeline
research.report.nav.verification
research.report.nav.sources
research.report.meta.sources
research.report.meta.quotes
research.report.meta.timeline
research.report.meta.timelineNoSpan
research.report.meta.independentSources
research.report.overview
research.report.missing.summary
research.report.missing.more
research.report.timeline.count
research.report.timeline.coverage
research.report.timeline.unsourced
research.report.timeline.empty.title
research.report.timeline.empty.body
research.report.timeline.empty.action
research.report.claimsSummary
research.report.claims.count
research.report.claims.noEvidence
research.report.conflicts
research.report.missing.title
research.report.limitations
research.report.sources.summary
research.report.sources.expand
research.report.sources.collapse
research.report.source.open
research.report.legacy.note
research.report.verdict.unverifiedHelp
research.report.searchFailed
research.report.openWorkspace
research.report.copy
```

Use format strings consistently with `L10n.string`; check the format contract test. Do not add a key only to one language.

- [ ] **Step 2: Accessibility and reduce motion**

- Section nav: `Picker`/buttons have an accessibility label per section; active segment has `.isSelected`.
- Source summary: `accessibilityValue` = expanded/collapsed; label includes evidence and domain counts.
- Claim rows: `accessibilityLabel` combines the claim and evidence count; expanded content is reachable.
- Timeline nodes: combine date, title, state, and citation count into one accessibility element.
- Source rows: label includes ID, title, domain, and verification state.
- Use `@Environment(\.accessibilityReduceMotion)` for the scroll animation; no animation when reduced motion is on.
- Text selection on summary, overview, timeline detail, quote, and limitations.

- [ ] **Step 3: Audit empty and failure states**

Manually render/check:
- `report.timeline == []` → timeline empty state with the workspace action; no blank section.
- `report.evidence == []` → no sources section; conclusion meta shows 0 sources; no empty list.
- `report.verification == nil` + `isLegacy` → legacy note; no claims/conflicts.
- `report.searchStatus == .failed` → search-failed note.
- record `.failed` / `.partial` / `.interrupted` → existing banners still visible; reader shows the last report if present.
- record `.running` → progress disclosure still collapses/expands; report reader shows the last verified version.

- [ ] **Step 4: Run the full verification**

Run: `swift test --filter LocalizationParityTests`
Expected: PASS.

Run: `swift test`
Expected: PASS, or only pre-existing failures recorded in Task 0 remain. The new tests must pass.

Run: `swift build`
Expected: exit 0.

Manual acceptance matrix:
- Popup 760×760 / 620×560, both themes: conclusion + ≥2 timeline nodes visible; nav works; sources collapsed; E1 card; open source; close returns.
- Historical version from a notification with `versionID`: shows that version, not the latest.
- Workspace 1180: report tab default, version menu, collapsed sources, bottom action bar.
- Workspace 1600: source rail appears; 1180 hides it.
- VoiceOver and keyboard focus; reduced motion.
- Recommendation card with 「有深研」; notification route; workspace route.

- [ ] **Step 5: Update docs**

In `docs/research-center.zh-CN.md` and `docs/research-center.md`, add a short「报告阅读器」section:
- conclusion → timeline → verification → sources;
- sources collapsed, E1 card;
- popup 760 default / 620 minimum;
- workspace report tab default and wide source rail at detail ≥820.

Do not rewrite the whole document; add the section near 「一个主题的日常」/「版本」.

- [ ] **Step 6: Commit**

```bash
git add Sources/NewsBar/Models/Localized.swift docs/research-center.zh-CN.md docs/research-center.md
git commit -m "docs(research): document report reader and finish localization"
```

---

## Self-Review

- **Spec coverage:** 结论、时间线、核验、来源、浮窗、研究中心、宽窗来源栏、历史版本、默认 tab、空状态、主题/可访问性、测试均有对应任务。
- **Step scan:** 每个任务都有失败测试/验证 → 实现 → 通过 → 提交；没有“TBD”“处理边界情况”之类的空步骤。
- **Type consistency:** `ResearchReportReader` 的 `contextID`、`isHistorical`、`isLegacy`、`showsSourceSection`、`onOpenURL`、`onOpenEventTimeline`、`onOpenWorkspace` 在各任务中一致；`ResearchReportMetrics` 字段名一致；`ResearchSourceGroup` 在阅读器和来源栏中一致。
- **Review Focus:** 历史版本（Task 1/4）、空数据（Task 3/7）、核验计数（Task 1/3）、窄窗（Task 2/7）、来源操作（Task 2/3/7）、长报告（Task 2/7）均有测试或手动验收。
- **Proportion:** 计划把决策、接口、测试断言写清楚，未提前写完整视图/函数体。

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-11-23-research-report-reader.md`.

Please review the plan. Which execution approach would you prefer?

- **Subagent-driven** — 每个任务由新的 subagent 实现，另一个 fresh reviewer 检查后再进入下一任务；最彻底，适合这次跨浮窗、研究中心和数据层三块的改动。
- **Native** — 我在本会话按任务顺序实现，最后用一个 fresh reviewer 检查整个分支；更快、更省上下文，适合任务之间接口耦合较紧的情况。

For this plan I recommend **Subagent-driven**, because Task 2–3 create the shared reader interfaces that Task 4–6 consume, and a fresh reviewer after each task catches interface drift before it spreads. Does the plan capture what you want, and which approach should we use?
