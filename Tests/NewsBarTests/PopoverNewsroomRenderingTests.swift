import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

/// Renders the real popover surface so the 48pt header, AI card picker and
/// trend columns are covered by a layout check instead of a hand-built header
/// fixture.
@MainActor
final class PopoverNewsroomRenderingTests: XCTestCase {
    func testPopoverRendersWithRealHeaderAndBriefing() throws {
        let settings = AppSettings()
        defer {
            settings.appTheme = .modern
            settings.appLanguage = .zh
        }
        settings.appLanguage = .zh
        settings.appTheme = .modern
        settings.aiSummaryEnabled = true

        let items: [NewsItem] = [
            NewsItem(title: "王楚钦反思长文被指双标对待", url: "https://example.com/1", source: .weibo, rank: 1),
            NewsItem(title: "张雪冠军车拍卖款不再捐给韩红基金会", url: "https://example.com/2", source: .weibo, rank: 2),
            NewsItem(title: "黄仁勋呐，出轨我们也认。", url: "https://example.com/3", source: .bilibili, rank: 1),
            NewsItem(title: "养了大肥鱼以后，家里的米就没够吃过", url: "https://example.com/4", source: .bilibili, rank: 2),
            NewsItem(title: "苹果研究团队用仿真训练人形机器人", url: "https://example.com/5", source: .rss(name: "少数派", url: "https://example.com/feed")),
            NewsItem(title: "Apple 回应 iPhone Duo 破发", url: "https://example.com/6", source: .rss(name: "爱范儿", url: "https://example.com/feed2")),
        ]
        let summary = ParsedSummary(
            trendOverview: [
                ("高叶金鸡影后", "高叶获金鸡奖影后，成为本届最受关注的话题之一。", 0),
                ("羊城晚报评王楚钦反思长文", "媒体就王楚钦反思长文发表评论，引发广泛讨论。", 1),
            ],
            dailyEssentials: [
                ("苹果 AI 进展", "特努斯施压 Siri 掌门人，苹果 AI 推进节奏受到关注。", 4),
                ("Anthropic 路演与 IPO", "路演 PPT 显示算力提 49 次，长期利润率目标 35%。", 5),
            ],
            isLegacyFallback: false
        )

        let orchestrator = NewsOrchestrator()
        orchestrator.weiboItems = Array(items.prefix(2))
        orchestrator.bilibiliItems = Array(items[2..<4])
        orchestrator.aiSummaryState = .done("fixture")
        orchestrator.aiSummaryText = "fixture"
        orchestrator.aiSummaryItems = items
        orchestrator.aiParsedSummary = summary
        orchestrator.aiSummaryManifest = SummaryManifest(
            items: items,
            profileVersion: 0,
            model: "test",
            provider: "test",
            language: .zh,
            maxWords: 300,
            asOf: Date(),
            coverageStart: Date().addingTimeInterval(-24 * 3600)
        )
        orchestrator.researchSummary = ResearchSummary(burstCount: 25, unreadBurstCount: 1)

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/popover-newsroom-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (name, theme) in [("popover-modern", AppTheme.modern), ("popover-retro", .retroEditorial)] {
            settings.appTheme = theme
            let view = ZStack {
                Color(nsColor: .windowBackgroundColor)
                PopoverContent(
                    orchestrator: orchestrator,
                    updater: SparkleUpdater(),
                    onOpenSettings: {},
                    onOpenDashboard: {},
                    onOpenResearchCenter: {},
                    onConfigureKey: {},
                    weiboMonitor: nil
                )
                .environment(settings)
                .frame(width: 400, height: 520)
            }
            .frame(width: 400, height: 520)

            let host = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 520)
            host.layoutSubtreeIfNeeded()

            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 2_000, "\(name) should render")
            try data.write(to: output.appendingPathComponent("\(name).png"))
            window.contentView = nil
        }
    }
}
