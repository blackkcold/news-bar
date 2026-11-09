import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import NewsBar

final class ReaderRenderingTests: XCTestCase {
    @MainActor
    func testReaderRecoveryChromeRendersAcrossThemesAndNarrowSplit() throws {
        let settings = AppSettings()
        let originalTheme = settings.appTheme
        let originalLanguage = settings.appLanguage
        defer { settings.appTheme = originalTheme; settings.appLanguage = originalLanguage }
        let variants: [(String, AppTheme, ColorScheme, CGFloat, AppLanguage, ReaderAuxiliaryTab?)] = [
            ("reader-modern-light", .modern, .light, 960, .zh, nil),
            ("reader-modern-dark", .modern, .dark, 960, .en, nil),
            ("reader-retro-narrow", .retroEditorial, .light, 560, .zh, nil),
            ("reader-modern-min-split", .modern, .light, 760, .en, nil),
            ("reader-modern-light-rail-search", .modern, .light, 960, .zh, .search),
            ("reader-modern-dark-rail-search", .modern, .dark, 960, .en, .search),
            ("reader-retro-narrow-rail-search", .retroEditorial, .light, 760, .zh, .search),
            ("reader-modern-min-split-rail-overview", .modern, .light, 760, .en, .overview),
        ]
        for (name, theme, colorScheme, width, language, auxiliaryTab) in variants {
            settings.appTheme = theme
            settings.appLanguage = language
            let request = NewsReaderRequest(url: "https://www.ifanr.com/story", title: language == .en ? "A new view of technology and everyday life" : "爱范儿：科技与生活的新视角", item: nil, surface: "renderFixture", contextID: nil, consentEpoch: UUID(), privateSession: true)
            let model = NewsReaderModel(request: request)
            model.webView(WKWebView(), didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
            let view = ReaderContentView(
                model: model,
                onClose: {},
                initialAuxiliaryTab: auxiliaryTab
            )
            .environment(settings)
            .environment(\.newsBarTheme, theme)
            .preferredColorScheme(colorScheme)
            .frame(width: width, height: 600)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("Native reader rendering unavailable") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 2000)
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/reader-ui-validation")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent(name + ".png"))
            window.contentView = nil
            model.stop()
        }
    }
}
