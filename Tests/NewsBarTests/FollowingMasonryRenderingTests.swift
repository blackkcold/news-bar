import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class FollowingMasonryRenderingTests: XCTestCase {
    private let now = WeiboMonitorTestSupport.date(2026, 11, 9, 12, 0)

    private func entries(count: Int) -> [FollowingPostEntry] {
        let user = WeiboMonitorTestSupport.user(
            uid: "1",
            name: "数码闲聊站",
            priority: .p0,
            now: now
        )
        return (0..<count).map { index in
            FollowingPostEntry(
                post: WeiboMonitorTestSupport.post(
                    mid: "\(index)",
                    uid: "1",
                    name: "数码闲聊站",
                    text: index.isMultiple(of: 3)
                        ? "这条消息比较长，用来验证瀑布流卡片的高度估算和换行，不会撑破列宽。"
                        : "短消息 \(index)",
                    createdAt: now.addingTimeInterval(TimeInterval(-index * 60)),
                    read: index.isMultiple(of: 2)
                ),
                user: user
            )
        }
    }

    func testWaterfallCoversEveryEntryExactlyOnce() {
        let sample = entries(count: 12)
        for (width, expectedColumns) in [(560.0, 2), (760.0, 2), (920.0, 3), (1180.0, 3)] {
            let count = FollowingMasonryLayout.columnCount(for: width)
            XCTAssertEqual(count, expectedColumns, "width \(width)")
            let columnWidth = FollowingMasonryLayout.columnWidth(for: width, columns: count)
            let columns = FollowingMasonryLayout.columns(
                for: sample,
                columnCount: count,
                columnWidth: columnWidth
            )
            XCTAssertEqual(columns.count, count)
            XCTAssertEqual(columns.flatMap { $0 }.sorted(), Array(0..<sample.count))
        }
    }

    func testImageAndLongTextIncreaseEstimatedHeight() {
        let short = FollowingPostEntry(
            post: WeiboMonitorTestSupport.post(mid: "short", text: "短", createdAt: now),
            user: WeiboMonitorTestSupport.user(now: now)
        )
        var longPost = WeiboMonitorTestSupport.post(
            mid: "long",
            text: String(repeating: "长文本", count: 60),
            createdAt: now
        )
        longPost.imageURLs = ["https://example.com/image.jpg"]
        let long = FollowingPostEntry(
            post: longPost,
            user: WeiboMonitorTestSupport.user(now: now)
        )

        let shortHeight = FollowingMasonryLayout.estimatedHeight(
            entry: short,
            columnWidth: 300
        )
        let longHeight = FollowingMasonryLayout.estimatedHeight(
            entry: long,
            columnWidth: 300
        )
        XCTAssertGreaterThan(longHeight, shortHeight)
    }

    func testFollowingFeedRendersAtWideAndCompactWidths() throws {
        let settings = AppSettings()
        defer {
            settings.appTheme = .modern
            settings.appLanguage = .zh
        }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/following-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (name, width, theme, language) in [
            ("following-masonry-wide", 900.0, AppTheme.modern, AppLanguage.zh),
            ("following-masonry-compact", 360.0, AppTheme.modern, AppLanguage.zh),
            ("following-masonry-retro", 900.0, AppTheme.retroEditorial, AppLanguage.en),
        ] {
            settings.appTheme = theme
            settings.appLanguage = language
            let view = FollowingMasonryFeed(
                entries: entries(count: 6),
                width: width,
                onOpen: { _ in }
            )
            .environment(settings)
            .frame(width: width, height: 620)

            let image = try Self.render(view, size: CGSize(width: width, height: 620))
            XCTAssertGreaterThan(image.count, 1_000, "\(name) should render")
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
