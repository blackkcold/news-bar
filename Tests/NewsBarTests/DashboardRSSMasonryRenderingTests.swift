import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class DashboardRSSMasonryRenderingTests: XCTestCase {
    func testRSSMasonryRendersAtOneAndThreeColumnSlots() throws {
        let settings = AppSettings()
        settings.appLanguage = .zh
        settings.appTheme = .modern
        let items = makeItems()

        let cases: [(name: String, hostWidth: CGFloat, slotWidth: CGFloat)] = [
            ("rss-masonry-1col", 440, 468),
            ("rss-masonry-3col", 840, 868)
        ]
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/rss-masonry-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for testCase in cases {
            let view = DashboardAdaptiveRSSMasonryFeed(
                items: items,
                layoutWidth: testCase.slotWidth,
                title: "科技日报"
            )
            .environment(settings)
            .frame(width: testCase.hostWidth, height: 1_600)

            let host = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: testCase.hostWidth, height: 1_600),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()

            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 2_000, testCase.name)
            try data.write(to: output.appendingPathComponent("\(testCase.name).png"))
            window.contentView = nil
        }
    }

    private func makeItems() -> [NewsItem] {
        let titles = [
            "苹果发布新系统视觉规范，Dashboard 组件值得一看",
            "本地新闻：SwiftUI 在 macOS 15 上的布局技巧",
            "RSS 订阅源更新：产品设计案例集合",
            "一篇较长的标题用于测试瀑布流卡片在宽窄两种列宽下的稳定性",
            "保持懒加载与卡片高度平衡",
            "窄宽度下的单列回退依然应当保持可读性",
            "图像与纯文本卡片混排时的列高估算",
            "同一来源的更新会按时间顺序进入最短列"
        ]
        return titles.enumerated().map { index, title in
            NewsItem(
                title: title,
                url: "https://example.com/rss/\(index)",
                source: .rss(name: "科技日报", url: "https://example.com/feed"),
                rank: index
            )
        }
    }
}
