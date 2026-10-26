import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

final class AISettingsRenderingTests: XCTestCase {
    @MainActor
    func testDynamicCatalogSettingsRenderLiveStaleAndEmptyStates() async throws {
        let variants: [(String, AppTheme, ColorScheme, AppLanguage, Bool, Bool)] = [
            ("models-modern-live", .modern, .light, .zh, false, false),
            ("models-dark-stale", .modern, .dark, .en, true, false),
            ("models-retro-empty", .retroEditorial, .light, .zh, false, true)
        ]
        for (name, theme, scheme, language, stale, empty) in variants {
            let fixture = SettingsCatalogFixture(empty: empty)
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("models.json")
            let service = ProviderModelService(fileURL: cache, transport: { try await fixture.send($0) })
            let settings = AppSettings(modelService: service)
            let provider = settings.aiProvider, model = settings.aiModel, oldTheme = settings.appTheme, oldLanguage = settings.appLanguage
            defer {
                settings.aiProvider = provider; settings.aiModel = model
                settings.appTheme = oldTheme; settings.appLanguage = oldLanguage
            }
            settings.aiProvider = "ollamaCloud"
            settings.cachedAPIKey = "render-fixture-key"
            settings.appTheme = theme
            settings.appLanguage = language
            let usable = await settings.refreshModelCatalog()
            XCTAssertEqual(usable, !empty)
            if stale {
                await fixture.failRefresh()
                let fallback = await settings.refreshModelCatalog(force: true)
                XCTAssertTrue(fallback)
                XCTAssertTrue(settings.modelCatalogIsStale)
            }
            let view = AITab().appThemeSurface()
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(settings).preferredColorScheme(scheme).frame(width: 720, height: 1040)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 1040), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // The view starts its own metadata refresh. Snapshot the settled
            // state on the actual settings surface, not transparent form rows.
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !settings.isLoadingModelCatalog }, object: nil)
            await fulfillment(of: [settled], timeout: 3)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 2000)
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/provider-ui-validation")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent(name + ".png"))
            window.contentView = nil
        }
    }
}

private actor SettingsCatalogFixture {
    let empty: Bool
    var failing = false
    init(empty: Bool) { self.empty = empty }
    func failRefresh() { failing = true }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let body = empty ? #"{"models":[]}"# : #"{"models":[{"name":"deepseek-current","capabilities":["completion"]},{"name":"general-text","capabilities":["completion"]}]}"#
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: failing ? 503 : 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
