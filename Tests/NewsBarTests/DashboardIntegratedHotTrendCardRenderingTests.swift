import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class DashboardIntegratedHotTrendCardRenderingTests: XCTestCase {
    private func items(source: NewsSource, count: Int) -> [NewsItem] {
        (0..<count).map { index in
            NewsItem(
                title: source == .weibo
                    ? "微博热搜第 \(index + 1) 条：影像旗舰新动向"
                    : "B站热门第 \(index + 1) 条：长焦成为标配？",
                url: "https://example.com/\(source.id)/\(index)",
                source: source
            )
        }
    }

    func testIntegratedHotCardRendersBothSourcesAndEmptyState() throws {
        let settings = AppSettings()
        defer {
            settings.appTheme = .modern
            settings.appLanguage = .zh
        }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/dashboard-sidebar-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let cases: [(String, [NewsItem], [NewsItem], NewsSource, AppTheme, AppLanguage)] = [
            ("hot-integrated-weibo", items(source: .weibo, count: 6), items(source: .bilibili, count: 6), .weibo, .modern, .zh),
            ("hot-integrated-bilibili", items(source: .weibo, count: 6), items(source: .bilibili, count: 6), .bilibili, .modern, .zh),
            ("hot-integrated-retro", items(source: .weibo, count: 6), items(source: .bilibili, count: 6), .weibo, .retroEditorial, .en),
            ("hot-integrated-empty", [], [], .weibo, .modern, .zh),
        ]

        for (name, weibo, bilibili, initialSource, theme, language) in cases {
            settings.appTheme = theme
            settings.appLanguage = language
            let card = DashboardIntegratedHotTrendCard(
                weiboItems: weibo,
                bilibiliItems: bilibili,
                initialSource: initialSource
            )
            .environment(settings)
            .frame(width: 336, height: 460)

            let image = try Self.render(card, size: CGSize(width: 336, height: 460))
            XCTAssertGreaterThan(image.count, 500, "\(name) should render")
            try image.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    private static func render<Content: View>(_ view: Content, size: CGSize) throws -> Data {
        let host = NSHostingView(rootView: ZStack {
            Color(nsColor: .windowBackgroundColor)
            view
        })
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
        window.contentView = nil
        return data
    }
}
