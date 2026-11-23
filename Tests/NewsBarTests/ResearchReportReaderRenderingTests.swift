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
        let settings = AppSettings()
        settings.appTheme = theme

        let view = ResearchReportReader(
            report: report,
            contextID: nil,
            isLegacy: isLegacy,
            onOpenURL: { _, _ in },
            onOpenEventTimeline: onOpenEventTimeline
        )
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
