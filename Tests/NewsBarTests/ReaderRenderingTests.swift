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
        let variants: [(String, AppTheme, ColorScheme, CGFloat, AppLanguage)] = [
            ("reader-modern-light", .modern, .light, 960, .zh),
            ("reader-modern-dark", .modern, .dark, 960, .en),
            ("reader-retro-narrow", .retroEditorial, .light, 560, .zh)
        ]
        for (name, theme, colorScheme, width, language) in variants {
            settings.appTheme = theme
            settings.appLanguage = language
            let request = NewsReaderRequest(url: "https://www.ifanr.com/story", title: language == .en ? "A new view of technology and everyday life" : "爱范儿：科技与生活的新视角", item: nil, surface: "renderFixture", contextID: nil, consentEpoch: UUID(), privateSession: true)
            let model = NewsReaderModel(request: request)
            model.webView(WKWebView(), didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
            let view = ReaderContentView(model: model, onClose: {})
                .environment(settings)
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
