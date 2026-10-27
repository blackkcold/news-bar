import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class ResearchCenterRenderingTests: XCTestCase {
    func testEmptyCenterRendersAcrossThemeLanguageAndSize() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-render-matrix", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let sizes = [
            NSSize(width: 1000, height: 660),
            NSSize(width: 1120, height: 760),
        ]

        for theme in AppTheme.allCases {
            for language in AppLanguage.allCases {
                for size in sizes {
                    let settings = AppSettings()
                    settings.appTheme = theme
                    settings.appLanguage = language

                    let store = ResearchFakeStore()
                    let coordinator = ResearchCoordinator(store: store, notifier: { _ in })
                    let orchestrator = NewsOrchestrator()
                    let model = ResearchCenterModel(
                        orchestrator: orchestrator,
                        settings: settings,
                        store: store,
                        coordinator: coordinator
                    )
                    let view = ResearchCenterView(model: model)
                        .environment(settings)

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

                    let bitmap = try XCTUnwrap(
                        host.bitmapImageRepForCachingDisplay(in: host.bounds)
                    )
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try XCTUnwrap(
                        bitmap.representation(using: .png, properties: [:])
                    )

                    let name = "empty-\(theme.rawValue)-\(language.rawValue)-\(Int(size.width))x\(Int(size.height)).png"
                    try data.write(to: output.appendingPathComponent(name))

                    XCTAssertGreaterThan(data.count, 2_000, name)
                    XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width), name)
                    XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height), name)

                    window.contentView = nil
                }
            }
        }
    }
}
