import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class FollowingMasonryOverflowRenderingTests: XCTestCase {
    private let now = WeiboMonitorTestSupport.date(2026, 11, 9, 12, 0)

    func testWideImageNeverPaintsOutsideItsColumn() throws {
        let settings = AppSettings()
        settings.appLanguage = .zh
        settings.appTheme = .modern
        defer {
            settings.appLanguage = .zh
            settings.appTheme = .modern
        }

        let user = WeiboMonitorTestSupport.user(
            uid: "1",
            name: "数码闲聊站",
            priority: .p0,
            now: now
        )
        var widePost = WeiboMonitorTestSupport.post(
            mid: "wide",
            uid: "1",
            name: "数码闲聊站",
            text: "宽表格图片不能越过自己的瀑布流列。",
            createdAt: now
        )
        widePost.imageURLs = ["https://example.com/wide-table.png"]

        let longPost = WeiboMonitorTestSupport.post(
            mid: "long",
            uid: "1",
            name: "数码闲聊站",
            text: String(repeating: "VeryLongUnbrokenLatinURL-", count: 40),
            createdAt: now.addingTimeInterval(-60)
        )

        let entries = [
            FollowingPostEntry(post: widePost, user: user),
            FollowingPostEntry(post: longPost, user: user),
        ]
        let wideImage = Self.magentaImage(width: 1_600, height: 220)

        for width in [900.0, 760.0, 560.0] {
            let columnCount = FollowingMasonryLayout.columnCount(for: width)
            let columnWidth = FollowingMasonryLayout.columnWidth(
                for: width,
                columns: columnCount
            )
            let columns = FollowingMasonryLayout.columns(
                for: entries,
                columnCount: columnCount,
                columnWidth: columnWidth
            )
            let wideIndex = entries.firstIndex { $0.id == "wide" } ?? 0
            let wideColumn = try XCTUnwrap(
                columns.firstIndex { $0.contains(wideIndex) },
                "wide card must be assigned to a column"
            )
            let columnStart = CGFloat(wideColumn) * (columnWidth + WaterfallLayout.columnSpacing)
            let columnEnd = columnStart + columnWidth

            let feed = FollowingMasonryFeed(
                entries: entries,
                width: width,
                imageOverrides: ["wide": wideImage],
                onOpen: { _ in }
            )
            .environment(settings)
            .frame(width: width, height: 800)

            let data = try Self.render(
                ZStack {
                    Color.red
                    feed
                },
                size: CGSize(width: width, height: 800)
            )
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let scale = CGFloat(bitmap.pixelsWide) / width
            var magentaOutside = 0

            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?
                        .usingColorSpace(.deviceRGB) else { continue }
                    guard color.redComponent > 0.75,
                          color.blueComponent > 0.75,
                          color.greenComponent < 0.25 else { continue }
                    let pointX = CGFloat(x) / scale
                    if pointX < columnStart - 1 || pointX > columnEnd + 1 {
                        magentaOutside += 1
                    }
                }
            }

            XCTAssertEqual(
                magentaOutside,
                0,
                "wide image painted outside its \(columnWidth)pt column at feed width \(width)"
            )
        }
    }

    private static func magentaImage(width: Int, height: Int) -> Image {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return Image(nsImage: image)
    }

    private static func render<Content: View>(_ view: Content, size: CGSize) throws -> Data {
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
        window.contentView = nil
        return data
    }
}
