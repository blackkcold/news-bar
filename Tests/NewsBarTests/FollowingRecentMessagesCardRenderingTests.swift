import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class FollowingRecentMessagesCardRenderingTests: XCTestCase {
    private let now = WeiboMonitorTestSupport.date(2026, 11, 9, 12, 0)

    private func entries(count: Int) -> [FollowingPostEntry] {
        let users = [
            WeiboMonitorTestSupport.user(uid: "1", name: "数码闲聊站", priority: .p0, now: now),
            WeiboMonitorTestSupport.user(uid: "2", name: "爱范儿", priority: .p1, now: now),
        ]
        return (0..<count).map { index in
            let user = users[index % users.count]
            return FollowingPostEntry(
                post: WeiboMonitorTestSupport.post(
                    mid: "\(index)",
                    uid: user.uid,
                    name: user.screenName,
                    text: index.isMultiple(of: 2)
                        ? "新机影像规格曝光，主摄与长焦都有调整。"
                        : "端侧 AI 从演示走向日常工具。",
                    createdAt: now.addingTimeInterval(TimeInterval(-index * 90)),
                    read: index > 1
                ),
                user: user
            )
        }
    }

    func testRecentMessagesCardRendersWithUnreadAndEmptyStates() throws {
        let settings = AppSettings()
        defer {
            settings.appTheme = .modern
            settings.appLanguage = .zh
        }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/dashboard-sidebar-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let cases: [(String, [FollowingPostEntry], Int, AppTheme, AppLanguage)] = [
            ("following-recent-modern", entries(count: 5), 4, .modern, .zh),
            ("following-recent-retro", entries(count: 5), 4, .retroEditorial, .en),
            ("following-recent-empty", [], 0, .modern, .zh),
        ]

        for (name, entries, unread, theme, language) in cases {
            settings.appTheme = theme
            settings.appLanguage = language
            let card = FollowingRecentMessagesCard(
                entries: entries,
                unreadCount: unread,
                onOpen: { _ in },
                onShowMore: {}
            )
            .environment(settings)
            .frame(width: 336, height: 330)

            let image = try Self.render(card, size: CGSize(width: 336, height: 330))
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
