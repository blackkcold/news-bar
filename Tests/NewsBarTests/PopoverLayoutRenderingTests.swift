import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

final class PopoverLayoutRenderingTests: XCTestCase {
    @MainActor
    func testRenderPopoverSummaryLayout() throws {
        let items: [NewsItem] = [
            NewsItem(title: "苹果 iPhone Duo 订单被取消", url: "https://example.com/1", source: .weibo, rank: 1),
            NewsItem(title: "全球总决赛 IG vs HLE", url: "https://example.com/2", source: .bilibili, rank: 1),
            NewsItem(title: "苹果回应 iPhone Duo 破发", url: "https://example.com/3", source: .rss(name: "36氪", url: "https://example.com/feed-1")),
            NewsItem(title: "美团拟发债募资 10 亿美元", url: "https://example.com/4", source: .rss(name: "IT 之家", url: "https://example.com/feed-2")),
        ]
        let summary = ParsedSummary(
            trendOverview: [
                ("苹果 iPhone Duo 订单被取消", "苹果称很多客户取消 iPhone Duo 订单。", 0),
                ("全球总决赛 IG vs HLE", "10月26日 IG 对阵 HLE，赛事热度居前。", 1),
            ],
            dailyEssentials: [
                ("苹果回应 iPhone Duo 破发", "苹果回应破发；iPhone Duo 2 曝光，FaceID 与长焦或回归。", 2),
                ("美团拟发债募资 10 亿美元", "消息称美团计划通过债券发行募资 10 亿美元。", 3),
            ],
            isLegacyFallback: false
        )

        let settings = AppSettings()
        let oldTheme = settings.appTheme
        let oldLanguage = settings.appLanguage
        defer {
            settings.appTheme = oldTheme
            settings.appLanguage = oldLanguage
        }
        settings.appLanguage = .zh

        let variants: [(name: String, theme: AppTheme, scheme: ColorScheme)] = [
            ("summary-modern", .modern, .light),
            ("summary-modern-dark", .modern, .dark),
            ("summary-retro", .retroEditorial, .light),
        ]

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/popover-layout-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for variant in variants {
            settings.appTheme = variant.theme
            let view = VStack(spacing: 0) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .quaternaryLabelColor)).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("NEWS BAR").font(.system(size: 22, weight: .black))
                        Text("THE DAILY SIGNAL").font(.system(size: 7, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("NO. 26").font(.system(size: 9, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                    Text("×").font(.system(size: 12, weight: .black))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)

                ScrollView {
                    VStack(spacing: 0) {
                        AISummaryCard(
                            state: .done("fixture"),
                            isExpanded: .constant(true),
                            allItems: items,
                            parsedSummary: summary,
                            maxSectionsPerCategory: nil,
                            isRegenerating: false,
                            onRegenerate: {},
                            contextID: nil
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                        EditorialSectionHeading(
                            index: "03",
                            title: "RSS 主版",
                            subtitle: "4 个已启用源 · 86 条内容"
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }
                }
            }
            .frame(width: 400, height: 900)
            .background(AppThemeBackground())
            // The hosting view is transparent; the real popover supplies the
            // material. Use the window colour as a stable layout backdrop.
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(settings)
            .preferredColorScheme(variant.scheme)

            let host = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 900),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            // `AppThemeBackground` is clear for the modern theme; the window
            // supplies the backdrop. This PNG is a layout fixture, not a
            // material reference.
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 900)
            host.layoutSubtreeIfNeeded()

            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 2_000)
            try data.write(to: output.appendingPathComponent(variant.name + ".png"))
            window.contentView = nil
        }
    }

    @MainActor
    func testResearchChipFitsInOnePopoverRow() throws {
        let settings = AppSettings()
        let view = VStack(spacing: 0) {
            PopoverResearchChip(
                summary: ResearchSummary(burstCount: 3, unreadBurstCount: 2),
                onOpen: {}
            )
        }
        .frame(width: 400)
        .environment(settings)
        .preferredColorScheme(.light)

        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(host.fittingSize.height, 40)

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 500)
        window.contentView = nil
    }

    func testResearchChipReportsUnreadOnlyAndFallsBackToTheCenter() {
        let unread = ResearchSummary(burstCount: 25, unreadBurstCount: 3)
        XCTAssertEqual(
            PopoverResearchChip.displayTitle(language: .zh, summary: unread),
            "3 条新爆款研究"
        )
        XCTAssertEqual(
            PopoverResearchChip.displayTitle(language: .en, summary: unread),
            "3 new burst studies"
        )

        let read = ResearchSummary(burstCount: 25, unreadBurstCount: 0)
        XCTAssertEqual(
            PopoverResearchChip.displayTitle(language: .zh, summary: read),
            "研究中心"
        )
        XCTAssertEqual(
            PopoverResearchChip.displayTitle(language: .en, summary: read),
            "Research Center"
        )
    }

    func testFollowChipDropsTheUnreadNumberWhenItsBadgeIsOff() {
        XCTAssertEqual(
            PopoverWeiboFollowChip.displayTitle(language: .zh, unreadCount: 61, showsBadge: true),
            "关注 61"
        )
        XCTAssertEqual(
            PopoverWeiboFollowChip.displayTitle(language: .zh, unreadCount: 61, showsBadge: false),
            "关注"
        )
        XCTAssertEqual(
            PopoverWeiboFollowChip.displayTitle(language: .en, unreadCount: 61, showsBadge: true),
            "Following 61"
        )
        XCTAssertEqual(
            PopoverWeiboFollowChip.displayTitle(language: .en, unreadCount: 61, showsBadge: false),
            "Following"
        )
        // A zero unread count must never read as "Following 0", even when the
        // badge switch is on.
        XCTAssertEqual(
            PopoverWeiboFollowChip.displayTitle(language: .zh, unreadCount: 0, showsBadge: true),
            "关注"
        )
        XCTAssertEqual(
            PopoverWeiboFollowChip.displayTitle(language: .en, unreadCount: 0, showsBadge: true),
            "Following"
        )
    }

    func testFollowEntryRequiresTheSettingAndAtLeastOneAccount() {
        XCTAssertTrue(
            PopoverWeiboFollowChip.shouldShowEntry(settingEnabled: true, accountCount: 1)
        )
        XCTAssertFalse(
            PopoverWeiboFollowChip.shouldShowEntry(settingEnabled: false, accountCount: 1)
        )
        XCTAssertFalse(
            PopoverWeiboFollowChip.shouldShowEntry(settingEnabled: true, accountCount: 0)
        )
        XCTAssertFalse(
            PopoverWeiboFollowChip.shouldShowEntry(settingEnabled: false, accountCount: 0)
        )
    }

    @MainActor
    func testFollowChipShowsANeutralEntryAtZeroUnread() throws {
        let settings = AppSettings()
        for theme in [AppTheme.modern, .retroEditorial] {
            settings.appTheme = theme
            let view = VStack(spacing: 0) {
                PopoverWeiboFollowChip(
                    unreadCount: 0,
                    showsBadge: true,
                    onOpen: {},
                    compact: true
                )
            }
            .padding(.horizontal, PopoverLayout.horizontalInset)
            .frame(width: 400)
            .environment(settings)
            .preferredColorScheme(.light)

            let host = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
            host.layoutSubtreeIfNeeded()

            XCTAssertLessThanOrEqual(host.fittingSize.height, 40, "theme: \(theme)")

            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 500, "theme: \(theme)")
            window.contentView = nil
        }
    }

    @MainActor
    func testNeutralChipsFitInOnePopoverRow() throws {
        let settings = AppSettings()
        let view = HStack(spacing: 6) {
            PopoverResearchChip(
                summary: ResearchSummary(burstCount: 25, unreadBurstCount: 0),
                onOpen: {},
                compact: true
            )
            PopoverWeiboFollowChip(
                unreadCount: 61,
                showsBadge: false,
                onOpen: {},
                compact: true
            )
        }
        .padding(.horizontal, PopoverLayout.horizontalInset)
        .frame(width: 400)
        .environment(settings)
        .preferredColorScheme(.light)

        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(host.fittingSize.height, 40)

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 500)
        window.contentView = nil
    }
}
