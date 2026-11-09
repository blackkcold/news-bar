import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class DashboardModeSegmentedControlTests: XCTestCase {
    func testBadgeOnlyBelongsToFollowingSegment() {
        XCTAssertNil(DashboardModeSegmentedControl.badgeText(
            for: .forYou,
            unread: 5,
            enabled: true
        ))
        XCTAssertNil(DashboardModeSegmentedControl.badgeText(
            for: .bySource,
            unread: 5,
            enabled: true
        ))
        XCTAssertEqual(DashboardModeSegmentedControl.badgeText(
            for: .following,
            unread: 5,
            enabled: true
        ), "5")
        XCTAssertNil(DashboardModeSegmentedControl.badgeText(
            for: .following,
            unread: 0,
            enabled: true
        ))
        XCTAssertNil(DashboardModeSegmentedControl.badgeText(
            for: .following,
            unread: 5,
            enabled: false
        ))
        XCTAssertEqual(DashboardModeSegmentedControl.badgeText(
            for: .following,
            unread: 120,
            enabled: true
        ), "99+")
    }

    func testControlRendersInModernAndRetroThemes() throws {
        let settings = AppSettings()
        defer {
            settings.appTheme = .modern
            settings.appLanguage = .zh
        }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/dashboard-mode-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (name, theme, language) in [
            ("mode-modern-zh", AppTheme.modern, AppLanguage.zh),
            ("mode-modern-en", AppTheme.modern, AppLanguage.en),
            ("mode-retro-zh", AppTheme.retroEditorial, AppLanguage.zh),
        ] {
            settings.appTheme = theme
            settings.appLanguage = language
            let control = DashboardModeSegmentedControl(
                mode: .constant(.forYou),
                followingUnread: 2,
                badgeEnabled: true
            )
            .environment(settings)
            .frame(width: 420, height: 36)

            let image = try Self.render(control, size: CGSize(width: 420, height: 36))
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
