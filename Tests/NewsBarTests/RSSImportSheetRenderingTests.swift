import XCTest
import SwiftUI
import AppKit
@testable import NewsBar

/// The import sheet is the one new surface that is not reachable from the
/// settings-pane snapshot tests, so it gets its own layout check.
final class RSSImportSheetRenderingTests: XCTestCase {

    @MainActor
    func testFilePreviewRenders() throws {
        let settings = AppSettings()
        let plan = RSSImportPlan(
            accepted: [
                .init(name: "中国新闻网", url: "https://www.chinanews.com.cn/rss/scroll-news.xml"),
                .init(name: "量子位", url: "https://www.qbitai.com/feed"),
                .init(name: "FT 中文网", url: "https://www.ftchinese.com/rss/news"),
            ],
            rejections: [
                .init(name: "少数派", url: "https://sspai.com/feed", kind: .duplicate),
                .init(name: "坏地址", url: "not a url", kind: .invalidURL),
            ]
        )
        let sheet = RSSImportSheet(
            mode: .file(format: .opml, plan: plan),
            existingSources: []
        ) { _ in }
            .environment(settings)
            .background(Color(nsColor: .windowBackgroundColor))

        let data = try snapshot(sheet, size: NSSize(width: 640, height: 520), name: "file-preview")
        XCTAssertGreaterThan(data.count, 2_000)
    }

    @MainActor
    func testGoogleNewsInputRenders() throws {
        let settings = AppSettings()
        let sheet = RSSImportSheet(
            mode: .googleNews,
            existingSources: []
        ) { _ in }
            .environment(settings)
            .background(Color(nsColor: .windowBackgroundColor))

        let data = try snapshot(sheet, size: NSSize(width: 640, height: 520), name: "google-news")
        XCTAssertGreaterThan(data.count, 2_000)
    }

    @MainActor
    private func snapshot<V: View>(_ view: V, size: NSSize, name: String) throws -> Data {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.title = "NewsBar Import"
        window.isOpaque = true
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("Could not create a bitmap for \(name)")
            return Data()
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(name)")
            return Data()
        }

        let directory = URL(fileURLWithPath: ".build/import-sheet-validation", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
        window.contentView = nil
        return data
    }
}
