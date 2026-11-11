import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class DashboardBrowsePanesTests: XCTestCase {
    // MARK: - Exposure gate

    func testHiddenPaneIsObscuredForExposure() {
        XCTAssertTrue(
            DashboardPaneGatingRules.obscuresExposure(parentObscured: false, isActive: false),
            "a pane that is merely hidden behind another tab must not count impressions"
        )
        XCTAssertFalse(
            DashboardPaneGatingRules.obscuresExposure(parentObscured: false, isActive: true)
        )
    }

    func testReaderObscuringStillWins() {
        XCTAssertTrue(
            DashboardPaneGatingRules.obscuresExposure(parentObscured: true, isActive: true),
            "the reader covers the visible pane, so it stays obscured"
        )
        XCTAssertTrue(
            DashboardPaneGatingRules.obscuresExposure(parentObscured: true, isActive: false)
        )
    }

    // MARK: - Refresh control rendering

    func testRefreshControlRendersIdleAndBusyAtFeedAndReaderWidths() throws {
        let settings = AppSettings()
        settings.appLanguage = .zh
        settings.appTheme = .modern
        defer {
            settings.appTheme = .modern
            settings.appLanguage = .zh
        }

        let snapshot = makeSnapshot()
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/browse-panes-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let variants: [(name: String, width: CGFloat, refreshing: Bool, updatedAt: Date?)] = [
            ("feed-idle", 1200, false, Date().addingTimeInterval(-180)),
            ("feed-busy", 1200, true, Date().addingTimeInterval(-180)),
            ("reader-idle", 360, false, Date().addingTimeInterval(-180)),
            ("never-refreshed", 1200, false, nil),
        ]

        for variant in variants {
            let view = RecommendationFeedView(
                matches: { _ in true },
                width: variant.width,
                snapshotOverride: snapshot,
                isRefreshing: variant.refreshing,
                lastRefreshAt: variant.updatedAt
            )
            .environment(settings)
            .frame(width: variant.width, height: 720)

            let image = try Self.render(view, size: CGSize(width: variant.width, height: 720))
            XCTAssertGreaterThan(image.count, 2_000, "\(variant.name) should render")
            try image.write(to: output.appendingPathComponent("\(variant.name).png"))
        }
    }

    // MARK: - Back to top

    func testBackToTopButtonRendersInBothThemes() throws {
        let settings = AppSettings()
        defer {
            settings.appTheme = .modern
            settings.appLanguage = .zh
        }

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/browse-panes-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (name, theme) in [("modern", AppTheme.modern), ("retro", AppTheme.retroEditorial)] {
            settings.appTheme = theme
            let view = BrowseBackToTopButton {}
                .padding(18)
                .environment(settings)
                .frame(width: 76, height: 76)

            let image = try Self.render(view, size: CGSize(width: 76, height: 76))
            XCTAssertGreaterThan(image.count, 800, "\(name) button should render")
            try image.write(to: output.appendingPathComponent("back-to-top-\(name).png"))
        }
    }

    // MARK: - Helpers

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
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        window.contentView = nil
        return data
    }

    private func makeSnapshot() -> RecommendationSnapshot {
        let items = (0..<4).map { index in
            NewsItem(
                title: "刷新控件渲染检查用的推荐标题 \(index)",
                url: "https://example.com/refresh-\(index)",
                source: .rss(name: "少数派", url: "https://sspai.com/feed-\(index)")
            )
        }
        let recommendations = items.enumerated().map { index, item in
            ScoredRecommendation(
                item: item,
                contentID: "refresh-content-\(index)",
                clusterID: "refresh-cluster-\(index)",
                score: 0.5,
                components: [:],
                reason: "recent",
                topic: nil
            )
        }
        return RecommendationSnapshot(
            asOf: Date(),
            profileVersion: 1,
            policyVersion: 3,
            profileConfidence: 0.5,
            semanticDegraded: false,
            items: recommendations
        )
    }
}
