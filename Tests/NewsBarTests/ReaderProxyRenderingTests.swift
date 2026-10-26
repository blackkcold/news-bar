import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

final class ReaderProxyRenderingTests: XCTestCase {
    @MainActor
    func testProxyConsentAndPausedSettingsRenderAcrossThemes() async throws {
        let settings = AppSettings()
        let theme = settings.appTheme, language = settings.appLanguage
        defer { settings.appTheme = theme; settings.appLanguage = language }
        let variants: [(String, AppTheme, ColorScheme, AppLanguage, CGFloat, Bool)] = [
            ("proxy-modern-untrusted", .modern, .light, .zh, 720, false),
            ("proxy-dark-authorized", .modern, .dark, .en, 720, true),
            ("proxy-retro-narrow", .retroEditorial, .light, .zh, 560, false)
        ]
        for (name, chosenTheme, scheme, chosenLanguage, width, authorized) in variants {
            settings.appTheme = chosenTheme
            settings.appLanguage = chosenLanguage
            let controller = ReaderProxyController(defaults: try XCTUnwrap(UserDefaults(suiteName: "reader-proxy-render-\(UUID())")),
                                                   credentials: ReaderProxyCredentialStore(read: { _ in nil }, save: { _, _ in true }), monitor: nil)
            controller.mode = .trustedProxy
            controller.updateNetwork(available: true)
            if authorized {
                try await controller.trust(endpoint: ReaderProxyEndpoint(host: "192.168.0.14", port: 7890), username: "fixture-user", password: "fixture-secret")
            }
            let view = Form { ReaderProxySettingsSection(controller: controller) }
                .formStyle(.grouped).scrollContentBackground(.hidden)
                .appThemeSurface().background(Color(nsColor: .windowBackgroundColor))
                .environment(settings).preferredColorScheme(scheme).frame(width: width, height: 820)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 2000)
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/reader-proxy-ui-validation")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent(name + ".png"))
            window.contentView = nil
        }
    }
}
