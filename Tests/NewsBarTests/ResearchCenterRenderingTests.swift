import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class ResearchCenterRenderingTests: XCTestCase {
    func testEmptyCenterRendersAtMinimumSize() throws {
        let settings = AppSettings()
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
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 660)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 2_000)
        window.contentView = nil
    }
}
