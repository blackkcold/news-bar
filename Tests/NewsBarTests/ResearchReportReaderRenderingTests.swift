import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class ResearchReportReaderRenderingTests: XCTestCase {
    private let sizes = [
        NSSize(width: 620, height: 560),
        NSSize(width: 760, height: 760),
    ]

    func testPopupReaderShowsLegacyURLSourcesWithoutInventingEvidence() throws {
        let report = legacyURLOnlyReport()
        let reader = popupReader(report, isLegacy: true)
        XCTAssertEqual(reader.sections, [.conclusion, .sources])
        XCTAssertEqual(reader.supplementaryLinks.map(\.rawURL), ["https://example.org/legacy?utm_source=archive"])
        XCTAssertEqual(reader.supplementaryLinks.map(\.kind), [.legacy])
        XCTAssertEqual(reader.supplementaryLinks.first?.label(language: .zh), "旧版链接 · 无引文")
        XCTAssertFalse(ResearchReportConclusionSection.noteKeys(
            report: report, isLegacy: true, supplementaryLinks: reader.supplementaryLinks
        ).contains("research.report.legacy.note"))
        XCTAssertEqual(popupReader(report, isLegacy: true, showsSourceSection: false).sections, [.conclusion])

        let output = try researchTestDirectory()
        try render(state: "popup-legacy-url-only", theme: .retroEditorial, size: sizes[0], output: output, content: reader)
    }

    func testPopupReaderShowsLimitationsWithoutVerificationOrEvidence() throws {
        let report = legacyLimitationsOnlyReport()
        let reader = popupReader(report, isLegacy: true)
        XCTAssertEqual(reader.sections, [.conclusion, .verification])
        XCTAssertEqual(reader.presentation.visibleLimitations(in: report), "只覆盖公开披露，不评估未公开渠道。")
        XCTAssertEqual(reader.presentation.verificationAnchor(in: report), .verification)
        XCTAssertNil(ResearchReportPresentation.workspace.visibleLimitations(in: report))
        var evidenceOnly = report
        evidenceOnly.evidence = makeEvidence()
        XCTAssertEqual(popupReader(evidenceOnly).sections, [.conclusion, .verification, .sources])
        XCTAssertEqual(reader.presentation.visibleLimitations(in: evidenceOnly), "只覆盖公开披露，不评估未公开渠道。")

        let output = try researchTestDirectory()
        try render(state: "popup-legacy-limitations", theme: .modern, size: sizes[1], output: output, content: reader)
    }

    func testPopupSupplementarySourcesKeepFirstSafeTargetsAndExistingCitationIDs() {
        let report = BurstResearch(
            sources: [
                "https://example.org/stored?utm_medium=source",
                "https://example.org/first?utm_source=original#article",
                "javascript:alert(1)",
                "https://example.org/second",
                "https://EXAMPLE.org/first?fbclid=duplicate",
                "http://example.org/insecure",
                "https://127.0.0.1/private",
                "https://example.org:8080/other",
            ],
            evidence: [EvidenceItem(
                id: "E7", url: "https://example.org/stored?utm_source=evidence",
                canonicalURL: "https://example.org/stale-canonical-field",
                domain: "example.org", title: "Existing evidence", publishedAt: nil,
                quote: "Existing quotation", quoteVerified: true, stance: .supports,
                tier: .major, syndicationGroup: nil, fetchedAt: .distantPast
            )]
        )
        let reader = popupReader(report)
        let links = reader.supplementaryLinks
        XCTAssertEqual(links.map(\.rawURL), ["https://example.org/first?utm_source=original#article", "https://example.org/second"])
        XCTAssertEqual(links.map(\.kind), [.other, .other])
        XCTAssertEqual(links.first?.label(language: .zh), "其他来源链接 · 无引文")
        XCTAssertEqual(reader.report.evidence.map(\.id), ["E7"])
    }

    func testPopupHidesBlankTimelineButKeepsNarrativeNodesInOrder() {
        let blank = TimelineNode(date: "", title: " ", detail: "")
        let first = TimelineNode(date: "", title: "First input", detail: "")
        let second = TimelineNode(date: "Earlier date", title: "Second input", detail: "")
        XCTAssertEqual(popupReader(BurstResearch(timeline: [blank])).sections, [.conclusion])
        let reader = popupReader(BurstResearch(timeline: [first, blank, second]))
        XCTAssertEqual(reader.sections, [.conclusion, .timeline])
        XCTAssertEqual(reader.presentation.timelineReport(reader.report).timeline.map(\.title), ["First input", "Second input"])
    }

    private func legacyURLOnlyReport() -> BurstResearch {
        BurstResearch(summary: "报道呈现了争议双方的说法。", sources: ["https://example.org/legacy?utm_source=archive"])
    }

    private func legacyLimitationsOnlyReport() -> BurstResearch {
        BurstResearch(summary: "简短结论。", limitations: "只覆盖公开披露，不评估未公开渠道。")
    }

    private func popupReader(
        _ report: BurstResearch, isLegacy: Bool = false, showsSourceSection: Bool = true
    ) -> ResearchReportReader {
        ResearchReportReader(
            report: report, contextID: nil, isLegacy: isLegacy, showsSourceSection: showsSourceSection,
            onOpenURL: { _, _ in }, presentation: .popup
        )
    }

    func testReaderRendersAcrossSizesAndThemes() throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("report-reader-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let report = BurstResearch(
            summary: "两家独立媒体确认新品将于十月发布，渠道备货同步到位。",
            overview: "公司先发布预告，随后两家媒体分别确认发布时间，渠道随即开始备货。",
            timeline: [
                TimelineNode(
                    date: "2026-10-01",
                    title: "发布预告",
                    detail: "公司发布新品预告。",
                    confidence: .high
                ),
                TimelineNode(
                    date: "2026-10-03",
                    title: "媒体确认",
                    detail: "两家独立媒体确认发布时间。",
                    confidence: .medium
                ),
                TimelineNode(
                    date: "2026-10-05",
                    title: "渠道备货",
                    detail: "渠道端开始备货。",
                    confidence: .low
                ),
            ],
            searchStatus: .succeeded
        )
        // Same summary, no timeline and no background: the PNG must be smaller
        // than the full report's, so the size assertion still means something.
        let summaryOnly = BurstResearch(
            summary: report.summary,
            searchStatus: .succeeded
        )

        for theme in AppTheme.allCases {
            for size in sizes {
                let fullData = try render(
                    state: "full",
                    report: report,
                    theme: theme,
                    size: size,
                    output: output
                )
                let emptyData = try render(
                    state: "summary-only",
                    report: summaryOnly,
                    theme: theme,
                    size: size,
                    output: output
                )
                XCTAssertGreaterThan(
                    fullData.count,
                    emptyData.count + 1_000,
                    "full-\(theme.rawValue)-\(Int(size.width))x\(Int(size.height))"
                )
            }
        }
    }

    func testReaderRendersEmptyTimeline() throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("report-reader-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let report = BurstResearch(
            summary: "现有来源只支撑结论，没有可回溯的事件顺序。",
            overview: "",
            timeline: [],
            searchStatus: .succeeded
        )

        for theme in AppTheme.allCases {
            for size in sizes {
                try render(
                    state: "empty-timeline",
                    report: report,
                    theme: theme,
                    size: size,
                    output: output,
                    onOpenEventTimeline: {}
                )
            }
        }
    }

    func testReaderRendersLegacyFailedReport() throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("report-reader-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var verification = VerificationReport()
        verification.verdict = .unverified
        verification.missing = [
            "发布时间尚未得到厂商确认",
            "备货规模没有公开数据",
            "渠道价格仍未知",
        ]
        let report = BurstResearch(
            summary: "旧版报告只保留了有限结论，联网检索也失败了。",
            overview: "来源不足，只能整理已知线索。",
            timeline: [
                TimelineNode(
                    date: "2026-10-01",
                    title: "线索出现在社交平台",
                    detail: "尚未得到第二方确认。",
                    confidence: .low
                ),
            ],
            searchStatus: .failed,
            verification: verification
        )

        for theme in AppTheme.allCases {
            for size in sizes {
                try render(
                    state: "legacy-failed",
                    report: report,
                    theme: theme,
                    size: size,
                    output: output,
                    isLegacy: true
                )
            }
        }
    }

    // MARK: - Chapters

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

    func testSectionsHideSourcesWhenTheRailOwnsThem() {
        let reader = ResearchReportReader(
            report: makeReportWithClaimsAndEvidence(),
            contextID: "record-1",
            showsSourceSection: false,
            onOpenURL: { _, _ in }
        )
        XCTAssertEqual(reader.sections, [.conclusion, .timeline, .verification])
    }

    /// The wide layout's source index. It is a 220pt column with its own
    /// scroll view, so the rail must draw its groups and compact rows without
    /// the reader beside it.
    func testSourceRailRendersAtWideLayoutWidth() throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("report-reader-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let report = makeReportWithClaimsAndEvidence()
        let groups = ResearchSourceGrouping.groups(for: report.evidence)
        XCTAssertEqual(groups.count, 2, "fixture keeps two domains")
        let metrics = ResearchReportMetrics(report: report)

        for theme in AppTheme.allCases {
            let rail = try render(
                state: "source-rail",
                theme: theme,
                size: NSSize(width: 220, height: 600),
                output: output,
                content: ResearchSourceRail(
                    groups: groups,
                    metrics: metrics,
                    onOpenURL: { _, _ in }
                )
            )
            XCTAssertGreaterThan(
                rail.count,
                2_000,
                "source-rail-\(theme.rawValue)"
            )

            // Header-only rail: the same chrome without any group. The data
            // must differ, otherwise the rows are not being drawn at all.
            let headerOnly = try render(
                state: "source-rail-no-groups",
                theme: theme,
                size: NSSize(width: 220, height: 600),
                output: output,
                content: ResearchSourceRail(
                    groups: [],
                    metrics: metrics,
                    onOpenURL: { _, _ in }
                )
            )
            XCTAssertNotEqual(
                rail,
                headerOnly,
                "source-rail-\(theme.rawValue): groups and rows must draw below the header"
            )
        }
    }

    func testReaderRendersClaimsAndCollapsedSources() throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("report-reader-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let report = makeReportWithClaimsAndEvidence()
        for theme in AppTheme.allCases {
            for size in sizes {
                try render(
                    state: "claims-sources",
                    report: report,
                    theme: theme,
                    size: size,
                    output: output
                )
            }
        }
    }

    /// The chapter's gap state must be observable, not inferred from a render:
    /// a blank body still produces a PNG well over the byte floor.
    func testVerificationGapNoteKeyTracksLegacyAndVerifiedReports() {
        let gapReport = BurstResearch(
            summary: "来源已保留，但这次运行没有生成逐条核验。",
            searchStatus: .succeeded,
            evidence: makeEvidence(),
            verification: nil
        )

        XCTAssertEqual(
            ResearchReportVerificationSection(report: gapReport, isLegacy: false).gapNoteKey,
            "research.report.verification.none"
        )
        XCTAssertEqual(
            ResearchReportVerificationSection(report: gapReport, isLegacy: true).gapNoteKey,
            "research.legacy.noVerification"
        )
        XCTAssertNil(
            ResearchReportVerificationSection(report: makeReportWithClaimsAndEvidence()).gapNoteKey
        )
        XCTAssertNil(
            ResearchReportVerificationSection(report: makeReportWithClaimsAndEvidence(), isLegacy: true)
                .gapNoteKey
        )
    }

    /// A legacy record is `reportVersion == 0`, not "no evidence": imported
    /// reports keep their sources and verification. Chapter 01 must not claim
    /// the report lacks evidence when chapter 04 lists it.
    func testLegacyNotesOnlyMentionEvidenceWhenThereIsNone() {
        let withEvidence = makeReportWithClaimsAndEvidence()
        XCTAssertEqual(
            ResearchReportConclusionSection.noteKeys(report: withEvidence, isLegacy: true),
            ["research.oldReport"]
        )

        let withoutEvidence = BurstResearch(summary: "旧版结论。", searchStatus: .succeeded)
        XCTAssertEqual(
            ResearchReportConclusionSection.noteKeys(report: withoutEvidence, isLegacy: true),
            ["research.oldReport", "research.report.legacy.note"]
        )
        XCTAssertEqual(
            ResearchReportConclusionSection.noteKeys(report: withoutEvidence, isLegacy: false),
            []
        )

        var failed = withoutEvidence
        failed.searchStatus = .failed
        XCTAssertEqual(
            ResearchReportConclusionSection.noteKeys(report: failed, isLegacy: false),
            ["research.report.searchFailed"]
        )
    }

    func testLegacyEmptyEvidenceHidesTheSourceCountLine() {
        let report = BurstResearch(summary: "旧版结论。", searchStatus: .succeeded)
        // Modern zero is a finding; legacy zero is an artifact with no list.
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: report, language: .zh),
            "0 个来源 · 0 个域名"
        )
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(
                report: report,
                language: .zh,
                isLegacy: true
            ),
            ""
        )
    }

    /// Expanded claim content (note + evidence chips) only exists inside the
    /// disclosure, which no reader render can reach.
    func testVerificationSectionRendersExpandedClaim() throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("report-reader-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let report = makeReportWithClaimsAndEvidence()
        let expandedClaim = "渠道已开始备货"

        for theme in AppTheme.allCases {
            for size in sizes {
                let collapsed = try render(
                    state: "verification-claim-collapsed",
                    theme: theme,
                    size: size,
                    output: output,
                    content: ResearchReportVerificationSection(
                        report: report,
                        isLegacy: false,
                        contextID: "record-1"
                    )
                )
                let expanded = try render(
                    state: "verification-claim-expanded",
                    theme: theme,
                    size: size,
                    output: output,
                    content: ResearchReportVerificationSection(
                        report: report,
                        isLegacy: false,
                        contextID: "record-1",
                        initiallyExpandedClaimIDs: [expandedClaim]
                    )
                )
                // The note and its two evidence chips add real content; a body
                // that ignored the seeded expansion would render both states
                // identically.
                XCTAssertGreaterThan(
                    expanded.count,
                    collapsed.count + 500,
                    "verification-claim-\(theme.rawValue)-\(Int(size.width))x\(Int(size.height))"
                )
            }
        }
    }

    func testSourceRowMetaOmitsBlankDomain() {
        let blankDomain = evidenceItem(
            id: "E9",
            domain: "",
            quoteVerified: false,
            stance: .supports
        )
        XCTAssertEqual(
            ResearchSourceRow.metaText(for: blankDomain, language: .zh),
            "支持 · T2"
        )
        XCTAssertEqual(
            ResearchSourceRow.metaText(
                for: evidenceItem(
                    id: "E2",
                    domain: "a.example",
                    quoteVerified: false,
                    stance: .unclear
                ),
                language: .zh
            ),
            "a.example · 存疑 · T2"
        )
    }

    /// The rail and the source index must describe one source the same way. The
    /// chip key is part of the label: without it, two rows on the same domain
    /// are indistinguishable to VoiceOver.
    func testSourceAccessibilityDescriptionCarriesKeyTitleDomainAndState() {
        let item = evidenceItem(
            id: "E7",
            domain: "a.example",
            quoteVerified: true,
            stance: .supports
        )
        XCTAssertEqual(
            ResearchSourceRow.accessibilityDescription(for: item, language: .zh),
            "E7 · Story E7 · a.example · 支持 · T2 · 引文已核"
        )
        XCTAssertEqual(
            ResearchSourceRow.accessibilityDescription(for: item, language: .en),
            "E7 · Story E7 · a.example · Supports · T2 · Quote verified"
        )
        XCTAssertEqual(
            ResearchSourceRow.accessibilityDescription(
                for: evidenceItem(id: "E2", domain: "", quoteVerified: false, stance: .unclear),
                language: .zh
            ),
            "E2 · Story E2 · 存疑 · T2 · 引文未核"
        )
    }

    /// A timeline node is one VoiceOver stop: date, title, state and citation
    /// count. The chips stay separate buttons inside the node.
    func testTimelineNodeAccessibilityLabelCombinesDateTitleStateAndCitations() {
        let verified = BurstResearch(
            summary: "summary",
            timeline: [
                TimelineNode(
                    date: "2026-10-01",
                    title: "发布预告",
                    detail: "公司释放预告。",
                    evidenceIDs: ["E1", "E2"],
                    confidence: .high
                )
            ],
            evidence: makeEvidence()
        )
        let verifiedNode = ReportPresentation(report: verified).nodes[0]
        XCTAssertEqual(
            ResearchReportTimelineSection.nodeAccessibilityLabel(for: verifiedNode, language: .zh),
            "2026-10-01 · 发布预告 · 已核验 · 2 条引文"
        )

        let unsourced = BurstResearch(
            summary: "summary",
            timeline: [
                TimelineNode(date: "", title: "尚未落地的传闻", detail: "", confidence: .low)
            ]
        )
        let unsourcedNode = ReportPresentation(report: unsourced).nodes[0]
        XCTAssertEqual(
            ResearchReportTimelineSection.nodeAccessibilityLabel(for: unsourcedNode, language: .zh),
            "尚未落地的传闻 · 无来源 · 无引文"
        )
    }

    /// No evidence is a real state: chapter 04 disappears, but the conclusion
    /// still says "0 sources" instead of silently dropping the count line.
    func testConclusionMetaShowsZeroSourcesWhenEvidenceIsEmpty() {
        let report = BurstResearch(summary: "只有结论。", searchStatus: .succeeded)
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: report, language: .zh),
            "0 个来源 · 0 个域名"
        )
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: report, language: .en),
            "Sources: 0 · Domains: 0"
        )

        let reader = ResearchReportReader(
            report: report,
            contextID: nil,
            onOpenURL: { _, _ in }
        )
        XCTAssertFalse(reader.sections.contains(.sources))
        XCTAssertFalse(reader.sections.contains(.verification))
    }

    func testConclusionMetaCountsTimelineSourcesAndQuotes() {
        // The date label alone is prose; a span needs `sortDate`.
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(
                report: makeReportWithClaimsAndEvidence(),
                language: .zh
            ),
            "2 个节点 · 3 个来源 · 2 个域名 · 已核验 2/3 条引文 · 2 个独立来源"
        )

        var dated = makeReportWithClaimsAndEvidence()
        dated.timeline = [
            TimelineNode(
                date: "10月1日",
                title: "发布预告",
                detail: "",
                sortDate: Date(timeIntervalSince1970: 1_790_000_000)
            ),
            TimelineNode(
                date: "10月8日",
                title: "渠道备货",
                detail: "",
                sortDate: Date(timeIntervalSince1970: 1_790_604_800)
            ),
        ]
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: dated, language: .zh),
            "2 个节点 · 跨 7 天 · 3 个来源 · 2 个域名 · 已核验 2/3 条引文 · 2 个独立来源"
        )
    }

    /// Two nodes on one day have a span of zero days; "跨 0 天" reads like a
    /// bug, so the display falls back to the node count and keeps it.
    func testSameDayTimelineShowsNodeCountInsteadOfZeroDaySpan() {
        var sameDay = makeReportWithClaimsAndEvidence()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        sameDay.timeline = [
            TimelineNode(date: "10月1日", title: "上午", detail: "", sortDate: day),
            TimelineNode(date: "10月1日", title: "下午", detail: "", sortDate: day),
        ]
        let metrics = ResearchReportMetrics(report: sameDay)
        XCTAssertEqual(metrics.timelineSpanDays, 0)
        XCTAssertNil(metrics.displaySpanDays)
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: sameDay, language: .zh),
            "2 个节点 · 3 个来源 · 2 个域名 · 已核验 2/3 条引文 · 2 个独立来源"
        )
    }

    /// The historical tag sits at the trailing edge of the full-width tab bar;
    /// it must keep drawing without squeezing the four chapters away.
    func testReaderRendersHistoricalTagBesideTheFullWidthNavigator() throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("report-reader-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let report = makeReportWithClaimsAndEvidence()
        for theme in AppTheme.allCases {
            for size in sizes {
                let tagged = try render(
                    state: "historical-nav",
                    report: report,
                    theme: theme,
                    size: size,
                    output: output,
                    isHistorical: true
                )
                let plain = try render(
                    state: "historical-nav-off",
                    report: report,
                    theme: theme,
                    size: size,
                    output: output
                )
                XCTAssertNotEqual(
                    tagged,
                    plain,
                    "historical tag must draw: \(theme.rawValue) \(Int(size.width))"
                )
            }
        }
    }

    /// The wide rail is gated on the detail pane's own width, not the window's.
    func testSourceRailGateIs820() {
        XCTAssertFalse(ResearchSourceRail.isVisible(detailWidth: 819))
        XCTAssertTrue(ResearchSourceRail.isVisible(detailWidth: 820))
    }

    /// The reader keeps the source index collapsed, so the expanded row and the
    /// two chapters are rendered on their own to prove they draw in both themes.
    func testReaderRendersVerificationAndSourceSections() throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("report-reader-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let report = makeReportWithClaimsAndEvidence()
        let item = try XCTUnwrap(report.evidence.first)

        for theme in AppTheme.allCases {
            for size in sizes {
                try render(
                    state: "verification-section",
                    theme: theme,
                    size: size,
                    output: output,
                    content: ResearchReportVerificationSection(
                        report: report,
                        isLegacy: false,
                        contextID: "record-1"
                    )
                )
                try render(
                    state: "source-index-section",
                    theme: theme,
                    size: size,
                    output: output,
                    content: ResearchReportSourceSection(
                        report: report,
                        onOpenURL: { _, _ in }
                    )
                )
                try render(
                    state: "source-row-expanded",
                    theme: theme,
                    size: size,
                    output: output,
                    content: ResearchSourceRow(
                        item: item,
                        isExpanded: .constant(true),
                        onOpenURL: { _, _ in }
                    )
                    .padding(18)
                )
            }
        }
    }

    /// Evidence without a verification block is a real state: chapter 03 must
    /// explain the gap instead of listing a chapter that draws nothing.
    func testReaderRendersVerificationGapNote() throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("report-reader-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let report = BurstResearch(
            summary: "来源已保留，但这次运行没有生成逐条核验。",
            overview: "",
            timeline: [],
            searchStatus: .succeeded,
            evidence: makeEvidence(),
            verification: nil
        )

        let reader = ResearchReportReader(
            report: report,
            contextID: nil,
            onOpenURL: { _, _ in }
        )
        XCTAssertEqual(reader.sections, [.conclusion, .timeline, .verification, .sources])

        for theme in AppTheme.allCases {
            for size in sizes {
                let data = try render(
                    state: "verification-gap",
                    report: report,
                    theme: theme,
                    size: size,
                    output: output
                )
                XCTAssertGreaterThan(
                    data.count,
                    2_000,
                    "verification-gap-\(theme.rawValue)-\(Int(size.width))x\(Int(size.height))"
                )

                let sectionData = try render(
                    state: "verification-gap-section",
                    theme: theme,
                    size: size,
                    output: output,
                    content: ResearchReportVerificationSection(
                        report: report,
                        isLegacy: false,
                        contextID: nil
                    )
                )
                XCTAssertGreaterThan(
                    sectionData.count,
                    2_000,
                    "verification-gap-section-\(theme.rawValue)-\(Int(size.width))x\(Int(size.height))"
                )

                // Pixels, not bytes: the binary must differ from a header-only
                // chapter, otherwise the gap note is not being drawn at all.
                let headerOnly = try render(
                    state: "verification-gap-header-only",
                    theme: theme,
                    size: size,
                    output: output,
                    content: VStack(alignment: .leading, spacing: 9) {
                        WorkspaceSectionHeader(
                            symbol: "checklist",
                            title: "\(ResearchReportSection.verification.index) "
                                + ResearchReportSection.verification.title
                        )
                    }
                )
                XCTAssertNotEqual(
                    sectionData,
                    headerOnly,
                    "verification-gap-\(theme.rawValue)-\(Int(size.width))x\(Int(size.height)): "
                        + "the gap note must draw below the header"
                )
            }
        }
    }

    func testReaderRendersLegacyReport() throws {
        let output = try researchTestDirectory()
            .appendingPathComponent("report-reader-render-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // A partially migrated artifact: evidence survives, but the verification
        // block does not. Section 03 must explain the gap instead of looking
        // empty, and the source index must still list what was kept.
        let report = BurstResearch(
            summary: "旧版流水线留下的报告只有结论和来源，没有主张账本。",
            overview: "",
            timeline: [
                TimelineNode(
                    date: "2026-09-20",
                    title: "旧版报告生成",
                    detail: "只保留了来源清单。",
                    confidence: .medium
                ),
            ],
            searchStatus: .succeeded,
            evidence: makeEvidence(),
            verification: nil,
            limitations: "旧版报告没有逐条核验主张。"
        )

        for theme in AppTheme.allCases {
            for size in sizes {
                try render(
                    state: "legacy-no-verification",
                    report: report,
                    theme: theme,
                    size: size,
                    output: output,
                    isLegacy: true
                )
            }
        }
    }

    // MARK: - Fixtures

    private func makeReportWithClaimsAndEvidence() -> BurstResearch {
        var verification = VerificationReport()
        verification.verdict = .unverified
        verification.strength = 2
        verification.independentSources = 2
        verification.claims = [
            ClaimCheck(
                claim: "新品将在十月发布",
                status: .supports,
                evidenceIDs: ["E1"],
                note: "两家媒体给出相同的月份。"
            ),
            ClaimCheck(
                claim: "渠道已开始备货",
                status: .unclear,
                evidenceIDs: ["E2", "E99"],
                note: "只有一家渠道口径。"
            ),
            ClaimCheck(
                claim: "售价维持上一代水平",
                status: nil,
                evidenceIDs: [],
                note: ""
            ),
        ]
        verification.conflicts = ["官方口径与渠道说法在时间上相差一周。"]
        verification.missing = ["发布时间未得到厂商确认", "备货规模没有公开数据"]

        return BurstResearch(
            summary: "两家媒体确认新品将于十月发布，渠道同步开始备货，售价仍未确认。",
            overview: "公司先释放预告，媒体随后确认，渠道跟进备货。",
            timeline: [
                TimelineNode(
                    date: "2026-10-01",
                    title: "发布预告",
                    detail: "公司释放新品预告。",
                    evidenceIDs: ["E1"],
                    confidence: .high
                ),
                TimelineNode(
                    date: "2026-10-08",
                    title: "渠道备货",
                    detail: "渠道端开始备货。",
                    evidenceIDs: ["E2"],
                    confidence: .low
                ),
            ],
            searchStatus: .succeeded,
            evidence: makeEvidence(),
            verification: verification,
            limitations: "只覆盖公开报道，未包含渠道内部数据。"
        )
    }

    private func makeEvidence() -> [EvidenceItem] {
        [
            evidenceItem(id: "E1", domain: "a.example", quoteVerified: true, stance: .supports),
            evidenceItem(id: "E2", domain: "a.example", quoteVerified: false, stance: .unclear),
            evidenceItem(id: "E3", domain: "b.example", quoteVerified: true, stance: .refutes),
        ]
    }

    private func evidenceItem(
        id: String,
        domain: String,
        quoteVerified: Bool,
        stance: EvidenceStance
    ) -> EvidenceItem {
        let url = "https://\(domain)/story/\(id.lowercased())"
        return EvidenceItem(
            id: id,
            url: url,
            canonicalURL: url,
            domain: domain,
            title: "Story \(id)",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            quote: "Quote \(id) from \(domain)",
            quoteVerified: quoteVerified,
            stance: stance,
            tier: .major,
            syndicationGroup: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    @discardableResult
    private func render(
        state: String,
        report: BurstResearch,
        theme: AppTheme,
        size: NSSize,
        output: URL,
        isLegacy: Bool = false,
        isHistorical: Bool = false,
        onOpenEventTimeline: (() -> Void)? = nil
    ) throws -> Data {
        let view = ResearchReportReader(
            report: report,
            contextID: nil,
            isHistorical: isHistorical,
            isLegacy: isLegacy,
            onOpenURL: { _, _ in },
            onOpenEventTimeline: onOpenEventTimeline
        )
        return try render(
            state: state,
            theme: theme,
            size: size,
            output: output,
            content: view
        )
    }

    @discardableResult
    private func render(
        state: String,
        theme: AppTheme,
        size: NSSize,
        output: URL,
        content: some View
    ) throws -> Data {
        let settings = AppSettings()
        settings.appTheme = theme

        let view = content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // Paint each theme's real surface: the reader itself is transparent,
            // so a window-colored harness would hide retro palette regressions.
            .background(
                theme == .retroEditorial
                    ? RetroEditorialTokens.paper
                    : Color(nsColor: .windowBackgroundColor)
            )
            .environment(settings)
            // Retro paints light paper, so the app pins a light appearance for
            // it (`AppSettings.resolvedColorScheme`). Without the same pin the
            // harness draws light text on cream and hides palette regressions.
            .environment(\.colorScheme, theme == .retroEditorial ? .light : .dark)

        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let name = "\(state)-\(theme.rawValue)-\(Int(size.width))x\(Int(size.height)).png"
        try data.write(to: output.appendingPathComponent(name))

        XCTAssertGreaterThan(data.count, 2_000, name)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width), name)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height), name)

        window.contentView = nil
        return data
    }
}
