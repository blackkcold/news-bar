import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

/// Guards the settings re-organization: every sidebar pane must exist, be
/// localized in both languages, and actually render. The PNGs are written for
/// manual review, not compared pixel by pixel.
final class SettingsWindowLayoutTests: XCTestCase {
    @MainActor
    func testEveryPaneAndAIPageIsLocalized() {
        for pane in SettingsPane.allCases {
            for key in [pane.titleKey, pane.headingKey, pane.subtitleKey] {
                XCTAssertNotEqual(L10n.string(key, language: .zh), key, "missing zh localization for \(key)")
                XCTAssertNotEqual(L10n.string(key, language: .en), key, "missing en localization for \(key)")
            }
            XCTAssertFalse(pane.symbol.isEmpty, "pane \(pane.rawValue) has no symbol")
        }

        for page in AITab.Page.allCases {
            XCTAssertNotEqual(L10n.string(page.titleKey, language: .zh), page.titleKey)
            XCTAssertNotEqual(L10n.string(page.titleKey, language: .en), page.titleKey)
        }

        XCTAssertEqual(SettingsPane.allCases.count, 7)
    }

    @MainActor
    func testEveryPaneRenders() async throws {
        let settings = AppSettings(modelService: makeModelService())
        settings.cachedAPIKey = "render-fixture-key"
        let original = (settings.appTheme, settings.appLanguage, settings.colorScheme)
        defer {
            settings.appTheme = original.0
            settings.appLanguage = original.1
            settings.colorScheme = original.2
        }

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/settings-ia-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let size = CGSize(width: 860, height: 620)
        // Retro/zh covers the panes. Modern/dark/en covers the material sidebar
        // and the wider English labels on the three densest panes.
        // Modern/light/zh exists because the sidebar regression only showed in
        // light mode: in dark the same fill differed from the content by 3/255.
        let variants: [(name: String, theme: AppTheme, language: AppLanguage, scheme: String)] = [
            ("retro-zh", .retroEditorial, .zh, "light"),
            ("modern-zh-light", .modern, .zh, "light"),
            ("modern-en-dark", .modern, .en, "dark")
        ]
        for variant in variants {
            settings.appTheme = variant.theme
            settings.appLanguage = variant.language
            settings.colorScheme = variant.scheme
            // `.notifications` is left out: ReminderTab asks UNUserNotificationCenter
            // for its status on appear, and that call raises when the xctest host
            // has no app bundle. The pane itself is unchanged by this refactor.
            let panes: [SettingsPane] = variant.name == "modern-en-dark"
                ? [.general, .ai, .privacy]
                : SettingsPane.allCases.filter { $0 != .notifications }
            for pane in panes {
                let view = SettingsWindow(initialPane: pane)
                    .environment(settings)
                    .frame(width: size.width, height: size.height)
                try await snapshot(view, size: size, name: "\(variant.name)-\(pane.rawValue)", to: output)
            }
        }

        // The three AI pages are internal to AITab; render them at the width the
        // detail pane actually gives them (860 - 194 sidebar - 1 divider).
        settings.appTheme = .retroEditorial
        settings.appLanguage = .zh
        settings.colorScheme = "light"
        let contentSize = CGSize(width: 665, height: 540)
        for page in AITab.Page.allCases {
            let view = AITab(page: page)
                .appThemeSurface()
                .frame(width: contentSize.width, height: contentSize.height)
                .adaptiveColorScheme()
                .environment(settings)
            try await snapshot(view, size: contentSize, name: "ai-\(page.rawValue)", to: output)
        }
    }

    @MainActor
    func testPricingSheetRenders() async throws {
        let settings = AppSettings(modelService: makeModelService())
        let original = (settings.appTheme, settings.appLanguage, settings.colorScheme)
        defer {
            settings.appTheme = original.0
            settings.appLanguage = original.1
            settings.colorScheme = original.2
        }
        settings.appTheme = .retroEditorial
        settings.appLanguage = .zh
        settings.colorScheme = "light"

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/settings-ia-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let size = CGSize(width: 760, height: 560)
        for plan in [OpenCodePricingPlan.go, .zen] {
            let view = OpenCodePricingView(currentModel: "deepseek-v4.1-flash", initialPlan: plan)
                .adaptiveColorScheme()
                .environment(settings)
            try await snapshot(view, size: size, name: "pricing-\(plan.rawValue)", to: output)
        }
    }

    /// The Go/Zen providers get a one-line summary plus a button; every other
    /// provider keeps its prose rows. This is the entry point, so it is worth a
    /// picture of its own.
    @MainActor
    func testUsagePageShowsThePricingEntryForOpenCode() async throws {
        let settings = AppSettings(modelService: makeModelService())
        let original = (
            settings.aiProvider,
            settings.appTheme,
            settings.appLanguage,
            settings.colorScheme
        )
        defer {
            settings.aiProvider = original.0
            settings.appTheme = original.1
            settings.appLanguage = original.2
            settings.colorScheme = original.3
        }
        settings.aiProvider = AIProvider.opencodeGo.rawValue
        settings.appTheme = .retroEditorial
        settings.appLanguage = .zh
        settings.colorScheme = "light"

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/settings-ia-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let size = CGSize(width: 665, height: 540)
        let view = AITab(page: .usage)
            .appThemeSurface()
            .frame(width: size.width, height: size.height)
            .adaptiveColorScheme()
            .environment(settings)
        try await snapshot(view, size: size, name: "ai-usage-go", to: output)
    }

    @MainActor
    private func snapshot(
        _ view: some View,
        size: CGSize,
        name: String,
        to output: URL
    ) async throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let the panes' first async pass (key status, cookie store, logs) land
        // before the picture is taken.
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 2000, "\(name) rendered nearly empty")
        try data.write(to: output.appendingPathComponent(name).appendingPathExtension("png"))
        window.contentView = nil
    }

    private func makeModelService() -> ProviderModelService {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("models.json")
        return ProviderModelService(fileURL: cache, transport: { request in
            let body = #"{"models":[{"name":"deepseek-v4.1-flash","capabilities":["completion"]}]}"#
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (Data(body.utf8), response)
        })
    }
}
