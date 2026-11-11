import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

/// Renders the real update badge in every state and both themes. The badge is
/// the only update affordance inside a 48pt header, so a clipped or invisible
/// state is a UX regression that a plain unit test would miss.
@MainActor
final class UpdateBadgeRenderingTests: XCTestCase {

    func testBadgeRendersEveryStateInBothThemes() throws {
        let settings = AppSettings()
        defer {
            settings.appTheme = .modern
            settings.appLanguage = .zh
        }
        settings.appLanguage = .zh

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/update-badge-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let states: [(String, SparkleUpdater.State)] = [
            ("available", .available("3.99.0")),
            ("ready", .ready("3.99.0")),
            ("checking", .checking),
            ("failed", .failed("无法连接更新服务器")),
            ("upToDate", .upToDate("3.0.0")),
        ]

        for (themeName, theme) in [("modern", AppTheme.modern), ("retro", AppTheme.retroEditorial)] {
            settings.appTheme = theme

            for (stateName, state) in states {
                let updater = SparkleUpdater(initialState: state)
                let view = HStack(spacing: 0) {
                    UpdateBadge(updater: updater)
                }
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(settings)
                .fixedSize()

                let host = NSHostingView(rootView: view)
                let size = host.fittingSize
                XCTAssertGreaterThan(size.width, 20, "\(themeName)-\(stateName) has no width")
                XCTAssertGreaterThan(size.height, 10, "\(themeName)-\(stateName) has no height")

                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()

                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 300, "\(themeName)-\(stateName) should render")
                try data.write(to: output.appendingPathComponent("\(themeName)-\(stateName).png"))
            }
        }
    }

    /// The idle state must occupy no space at all, otherwise the header keeps a
    /// gap where the old always-visible check button used to be.
    func testIdleBadgeTakesNoSpace() {
        let settings = AppSettings()
        let updater = SparkleUpdater(initialState: .idle)
        let view = HStack(spacing: 0) {
            UpdateBadge(updater: updater)
        }
        .environment(settings)
        .fixedSize()

        let host = NSHostingView(rootView: view)
        XCTAssertLessThan(host.fittingSize.width, 1)
    }
}
