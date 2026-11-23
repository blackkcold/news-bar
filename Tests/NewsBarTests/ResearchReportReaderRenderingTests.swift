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

        for theme in AppTheme.allCases {
            for size in sizes {
                try render(
                    state: "full",
                    report: report,
                    theme: theme,
                    size: size,
                    output: output
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
                    output: output
                )
            }
        }
    }

    private func render(
        state: String,
        report: BurstResearch,
        theme: AppTheme,
        size: NSSize,
        output: URL
    ) throws {
        let settings = AppSettings()
        settings.appTheme = theme

        let view = ResearchReportReader(
            report: report,
            contextID: nil,
            onOpenURL: { _, _ in }
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
    }
}
