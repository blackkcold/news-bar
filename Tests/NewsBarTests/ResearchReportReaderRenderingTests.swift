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
        onOpenEventTimeline: (() -> Void)? = nil
    ) throws -> Data {
        let view = ResearchReportReader(
            report: report,
            contextID: nil,
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
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(settings)

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
