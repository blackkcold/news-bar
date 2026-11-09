import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class ReaderAuxiliaryRailRenderingTests: XCTestCase {
    private let pageContext = PageSummaryPanelContext(
        title: "A new view of technology",
        url: "https://www.ifanr.com/story",
        isPrivate: false,
        language: .en
    )

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testRailRendersSearchTabAcrossThemes() throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/auxiliary-rail-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (name, theme, scheme) in [
            ("rail-search-modern-light", AppTheme.modern, ColorScheme.light),
            ("rail-search-modern-dark", AppTheme.modern, ColorScheme.dark),
            ("rail-search-retro", AppTheme.retroEditorial, ColorScheme.light),
        ] {
            let settings = AppSettings()
            settings.appTheme = theme
            let auxiliary = ReaderAuxiliaryModel()
            auxiliary.open(.search)
            let rail = ReaderAuxiliaryRail(
                auxiliary: auxiliary,
                searchModel: AISearchPanelModel(privacyAcknowledged: false),
                quickSearchModel: QuickSearchModel(),
                archiveController: AISearchArchiveController(),
                activeNewsItems: [],
                readingHistory: [],
                pageContext: pageContext,
                language: .en,
                isActiveTab: true,
                onOpenResult: { _ in },
                onOpenSource: { _ in },
                onConfigureAI: {},
                onClose: {},
                onOpenCitation: { _ in },
                onSwitchToReaderMode: {}
            )
            .environment(settings)
            .environment(\.newsBarTheme, theme)
            .preferredColorScheme(scheme)
            .frame(width: 360, height: 520)

            let image = try Self.render(rail, size: CGSize(width: 360, height: 520))
            XCTAssertGreaterThan(image.count, 500, "\(name) should render")
            try image.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    func testRailRendersOverviewTabAtTwoHeights() async throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/auxiliary-rail-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for height in [520.0, 720.0] {
            let settings = AppSettings()
            let auxiliary = ReaderAuxiliaryModel()
            auxiliary.open(.overview)
            auxiliary.prepareOverview(
                context: ReaderOverviewContext(
                    title: pageContext.title,
                    url: pageContext.url,
                    isPrivate: false,
                    language: .en
                )
            ) {
                String(repeating: "The article explores on-device AI. ", count: 60)
            }
            await waitUntil { auxiliary.overviewInput != nil }

            let rail = ReaderAuxiliaryRail(
                auxiliary: auxiliary,
                searchModel: AISearchPanelModel(privacyAcknowledged: true),
                quickSearchModel: QuickSearchModel(),
                archiveController: AISearchArchiveController(),
                activeNewsItems: [],
                readingHistory: [],
                pageContext: pageContext,
                language: .en,
                isActiveTab: true,
                onOpenResult: { _ in },
                onOpenSource: { _ in },
                onConfigureAI: {},
                onClose: {},
                onOpenCitation: { _ in },
                onSwitchToReaderMode: {}
            )
            .environment(settings)
            .environment(\.newsBarTheme, AppTheme.modern)
            .preferredColorScheme(.light)
            .frame(width: 360, height: height)

            let image = try Self.render(rail, size: CGSize(width: 360, height: height))
            XCTAssertGreaterThan(image.count, 500, "overview at \(height) should render")
            try image.write(to: output.appendingPathComponent("rail-overview-\(Int(height)).png"))
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
