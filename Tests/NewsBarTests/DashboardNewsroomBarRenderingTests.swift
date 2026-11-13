import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class DashboardNewsroomBarRenderingTests: XCTestCase {
    func testBarRendersAtBothWidthsAndThemes() throws {
        let settings = AppSettings()
        defer {
            settings.appTheme = .modern
            settings.appLanguage = .zh
        }

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/newsroom-bar-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let variants: [(name: String, theme: AppTheme, language: AppLanguage, width: CGFloat)] = [
            ("bar-modern-zh-960", .modern, .zh, 960),
            ("bar-modern-en-960", .modern, .en, 960),
            ("bar-modern-zh-1180", .modern, .zh, 1180),
            ("bar-retro-zh-960", .retroEditorial, .zh, 960),
        ]

        for variant in variants {
            settings.appTheme = variant.theme
            settings.appLanguage = variant.language

            let bar = DashboardNewsroomBar(
                mode: .forYou,
                followingUnread: 2,
                badgeEnabled: true,
                tabs: [],
                activeID: nil,
                isRefreshing: false,
                showsRefresh: true,
                onSelectMode: { _ in },
                onSelectBrowse: {},
                onSelectTab: { _ in },
                onCloseTab: { _ in },
                onRefresh: {},
                onOpenResearch: {},
                onOpenEventMonitor: {},
                onOpenSettings: {}
            )
            .environment(settings)
            .frame(width: variant.width, height: 46)

            let image = try Self.render(bar, size: CGSize(width: variant.width, height: 46))
            XCTAssertGreaterThan(image.count, 2_000, "\(variant.name) should render")
            try image.write(to: output.appendingPathComponent("\(variant.name).png"))
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
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
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
