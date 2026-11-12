import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

private actor RenderFeed: WeiboFeedFetching {
    private var pages: [String: [WeiboPost]] = [:]
    private var names: [String: String] = [:]

    func setPage(uid: String, posts: [WeiboPost], name: String) {
        pages[uid] = posts
        names[uid] = name
    }

    func fetchPage(
        uid: String,
        screenName: String,
        page: Int,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboFetchOutcome {
        let posts = pages[uid] ?? []
        let parsed = WeiboParsedPage(
            posts: posts,
            screenName: names[uid] ?? screenName,
            avatarURL: nil,
            sinceMid: posts.first?.mid,
            rawCount: posts.count,
            dateMissing: false
        )
        return .success(page: parsed, tier: .desktop, latency: 0.01)
    }

    func fetchLongText(mid: String, credentials: WeiboCredentials) async -> String? {
        nil
    }
}

/// Deterministic comment pages for design review. No network, no cookies.
private actor RenderCommentFeed: WeiboCommentFetching {
    func fetchComments(
        mid: String,
        uid: String,
        authorUID: String?,
        cursor: String?,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboCommentOutcome {
        let comments = [
            WeiboComment(
                id: "c1-\(mid)",
                mid: mid,
                uid: "1",
                screenName: "读者甲",
                avatarURL: nil,
                text: "期待实际样张对比，尤其是夜景。[吃瓜]",
                createdAt: now.addingTimeInterval(-300),
                likeCount: 12,
                replyToName: nil,
                isAuthor: false
            ),
            WeiboComment(
                id: "c2-\(mid)",
                mid: mid,
                uid: "2",
                screenName: "摄影爱好者",
                avatarURL: nil,
                text: "抓拍成功率确实比参数更重要。",
                createdAt: now.addingTimeInterval(-120),
                likeCount: 3,
                replyToName: nil,
                isAuthor: false
            ),
        ]
        return .success(
            page: WeiboCommentPage(
                comments: comments,
                total: 2,
                nextCursor: nil,
                fetchedAt: now,
                tier: .desktop
            ),
            latency: 0.01
        )
    }
}

/// Renders the two new surfaces with realistic seeded state. The PNGs are for
/// design review (spacing, hierarchy, empty states), not pixel comparison.
final class WeiboMonitorRenderingTests: XCTestCase {
    @MainActor
    func testFollowingFeedAndMonitorSettingsRender() async throws {
        let settings = AppSettings(modelService: makeModelService())
        settings.appTheme = .modern
        settings.appLanguage = .zh
        settings.colorScheme = "light"
        settings.weiboMonitorEnabled = true

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeiboMonitorRender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WeiboMonitorStore(root: root)
        let feed = RenderFeed()
        let service = WeiboMonitorService(
            store: store,
            feed: feed,
            notifier: NoopWeiboAlertNotifier(),
            rng: WeiboRNG(seed: 7),
            sleeper: { _ in },
            autoFlushAlerts: false,
            changeNotifier: {},
            authAlertRecorder: { _ in }
        )
        let viewModel = WeiboMonitorViewModel(
            settings: settings,
            service: service,
            commentFetcher: RenderCommentFeed(),
            commentCache: WeiboCommentCache(root: root)
        )
        await viewModel.start()

        let now = Date()
        let uid0 = "1234567890"
        let uid1 = "9876543210"
        _ = try await service.addUser(input: uid0, priority: .p0, now: now)
        _ = try await service.addUser(input: uid1, priority: .p1, now: now)

        let old0 = post(
            mid: "100",
            uid: uid0,
            name: "数码闲聊站",
            text: "旧帖：已经在列表里，作为基线不推送。",
            createdAt: now.addingTimeInterval(-3600)
        )
        let old1 = post(
            mid: "200",
            uid: uid1,
            name: "科技美学",
            text: "P1 的旧帖，基线同样不推送。",
            createdAt: now.addingTimeInterval(-7200)
        )
        await feed.setPage(uid: uid0, posts: [old0], name: "数码闲聊站")
        await feed.setPage(uid: uid1, posts: [old1], name: "科技美学")
        await viewModel.tick(now: now)

        let later = now.addingTimeInterval(420)
        let new0a = post(
            mid: "101",
            uid: uid0,
            name: "数码闲聊站",
            text: "独家：一家厂商决定不做 Ultra 系列，评论区补充了厂商名。",
            createdAt: now.addingTimeInterval(-300)
        )
        var new0b = post(
            mid: "102",
            uid: uid0,
            name: "数码闲聊站",
            text: "另一条：新机将采用 2K 直屏，电池容量提升到 6000mAh。",
            createdAt: now.addingTimeInterval(-120)
        )
        new0b.commentCount = 128
        new0b.repostCount = 36
        new0b.likeCount = 356
        new0b.metricsFetchedAt = now
        let new1 = post(
            mid: "201",
            uid: uid1,
            name: "科技美学",
            text: "P1 新帖：今晚的直播会有拆机环节。",
            createdAt: now.addingTimeInterval(-60)
        )
        await feed.setPage(uid: uid0, posts: [new0b, new0a, old0], name: "数码闲聊站")
        await feed.setPage(uid: uid1, posts: [new1, old1], name: "科技美学")
        await viewModel.tick(now: later)
        await viewModel.refresh()

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/weibo-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let feedView = WeiboFollowingFeedView(
            monitor: viewModel,
            filter: .constant(.all),
            searchText: .constant(""),
            mode: .constant(.following),
            accountUID: .constant(nil),
            followingUnread: 0,
            badgeEnabled: true,
            availableWidth: 900,
            onOpenSettings: {}
        )
        .frame(width: 900, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .adaptiveColorScheme()
        .environment(settings)
        try await snapshot(
            feedView,
            size: CGSize(width: 900, height: 680),
            name: "following-modern-zh-light",
            to: output
        )

        let readerWorkspace = FollowingReaderWorkspace(
            monitor: viewModel,
            filter: .constant(.all),
            searchText: .constant(""),
            accountUID: .constant(nil),
            isActive: true,
            onOpenSettings: {}
        )
        .frame(width: 1180, height: 760)
        .adaptiveColorScheme()
        .environment(settings)
        try await snapshot(
            readerWorkspace,
            size: CGSize(width: 1180, height: 760),
            name: "following-reader-modern",
            to: output
        )

        let settingsView = WeiboMonitorTab(monitor: viewModel)
            .frame(width: 665, height: 620)
            .background(Color(nsColor: .windowBackgroundColor))
            .adaptiveColorScheme()
            .environment(settings)
        try await snapshot(
            settingsView,
            size: CGSize(width: 665, height: 620),
            name: "weibo-settings-modern-zh-light",
            to: output
        )

        settings.appTheme = .retroEditorial
        settings.colorScheme = "light"
        let retroReaderWorkspace = FollowingReaderWorkspace(
            monitor: viewModel,
            filter: .constant(.all),
            searchText: .constant(""),
            accountUID: .constant(nil),
            isActive: true,
            onOpenSettings: {}
        )
        .frame(width: 960, height: 720)
        .adaptiveColorScheme()
        .environment(settings)
        try await snapshot(
            retroReaderWorkspace,
            size: CGSize(width: 960, height: 720),
            name: "following-reader-retro-narrow",
            to: output
        )
        let retroFeed = WeiboFollowingFeedView(
            monitor: viewModel,
            filter: .constant(.all),
            searchText: .constant(""),
            mode: .constant(.following),
            accountUID: .constant(nil),
            followingUnread: 0,
            badgeEnabled: true,
            availableWidth: 900,
            onOpenSettings: {}
        )
        .frame(width: 900, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .adaptiveColorScheme()
        .environment(settings)
        try await snapshot(
            retroFeed,
            size: CGSize(width: 900, height: 680),
            name: "following-retro-zh-light",
            to: output
        )
        settings.appTheme = .modern
        settings.colorScheme = "light"
        let compactFeed = WeiboFollowingFeedView(
            monitor: viewModel,
            filter: .constant(.all),
            searchText: .constant(""),
            mode: .constant(.following),
            accountUID: .constant(nil),
            followingUnread: 0,
            badgeEnabled: true,
            availableWidth: 360,
            onOpenSettings: {}
        )
        .frame(width: 360, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .adaptiveColorScheme()
        .environment(settings)
        try await snapshot(
            compactFeed,
            size: CGSize(width: 360, height: 640),
            name: "following-compact-zh-light",
            to: output
        )

        let minimumFeed = WeiboFollowingFeedView(
            monitor: viewModel,
            filter: .constant(.all),
            searchText: .constant(""),
            mode: .constant(.following),
            accountUID: .constant(nil),
            followingUnread: 0,
            badgeEnabled: true,
            availableWidth: 280,
            onOpenSettings: {}
        )
        .frame(width: 280, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .adaptiveColorScheme()
        .environment(settings)
        try await snapshot(
            minimumFeed,
            size: CGSize(width: 280, height: 640),
            name: "following-280-minimum",
            to: output
        )

        let relevanceWasEnabled = settings.weiboMonitorRelevanceEnabled
        settings.weiboMonitorRelevanceEnabled = false

        let wideFeed = WeiboFollowingFeedView(
            monitor: viewModel,
            filter: .constant(.all),
            searchText: .constant(""),
            mode: .constant(.following),
            accountUID: .constant(nil),
            followingUnread: 0,
            badgeEnabled: true,
            availableWidth: 1140,
            onOpenSettings: {}
        )
        .padding(20)
        .frame(width: 1180, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .adaptiveColorScheme()
        .environment(settings)
        try await snapshot(
            wideFeed,
            size: CGSize(width: 1180, height: 760),
            name: "following-1180-window",
            to: output
        )

        let ultraWideFeed = WeiboFollowingFeedView(
            monitor: viewModel,
            filter: .constant(.all),
            searchText: .constant(""),
            mode: .constant(.following),
            accountUID: .constant(nil),
            followingUnread: 0,
            badgeEnabled: true,
            availableWidth: 1400,
            onOpenSettings: {}
        )
        .padding(20)
        .frame(width: 1440, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .adaptiveColorScheme()
        .environment(settings)
        try await snapshot(
            ultraWideFeed,
            size: CGSize(width: 1440, height: 760),
            name: "following-1440-window",
            to: output
        )

        let noMatchFeed = WeiboFollowingFeedView(
            monitor: viewModel,
            filter: .constant(.all),
            searchText: .constant("zzzz-no-match"),
            mode: .constant(.following),
            accountUID: .constant(nil),
            followingUnread: 0,
            badgeEnabled: true,
            availableWidth: 1400,
            onOpenSettings: {}
        )
        .padding(20)
        .frame(width: 1440, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .adaptiveColorScheme()
        .environment(settings)
        try await snapshot(
            noMatchFeed,
            size: CGSize(width: 1440, height: 760),
            name: "following-1440-no-match",
            to: output
        )
        settings.weiboMonitorRelevanceEnabled = relevanceWasEnabled

        // Opening the original web page must not discard the workspace's
        // independently scrolling panes; returning should keep their position.
        let router = NewsNavigationRouter.shared
        let tabs = WorkspaceTabStore.shared
        router.close()
        tabs.terminateAll()
        defer {
            router.close()
            tabs.terminateAll()
        }
        let dashboard = NSHostingView(rootView: DashboardWindow(
            orchestrator: NewsOrchestrator(), weiboMonitor: viewModel
        ).environment(settings))
        let dashboardWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        dashboardWindow.contentView = dashboard
        dashboard.frame = dashboardWindow.contentView?.bounds ?? .zero
        dashboard.layoutSubtreeIfNeeded()
        let initialScrolls = Set(scrollViews(in: dashboard).map(ObjectIdentifier.init))
        NotificationCenter.default.post(name: .openWeiboFollowFeed, object: nil)
        try await Task.sleep(for: .milliseconds(250))
        dashboard.layoutSubtreeIfNeeded()
        let workspaceScrolls = scrollViews(in: dashboard).filter { !initialScrolls.contains(ObjectIdentifier($0)) }
        XCTAssertFalse(workspaceScrolls.isEmpty, "Following should mount its own scrolling panes")
        XCTAssertTrue(WeiboFeedPresence.isVisible, "The active following workspace must be marked visible")

        router.selection = NewsReaderRequest(
            url: "invalid-fixture-url", title: "Fixture", item: nil, surface: "test",
            contextID: nil, consentEpoch: UUID(), privateSession: true
        )
        try await Task.sleep(for: .milliseconds(400))
        dashboard.layoutSubtreeIfNeeded()
        let duringReader = scrollViews(in: dashboard)
        XCTAssertTrue(workspaceScrolls.contains { original in duringReader.contains { $0 === original } }, "Opening the original must keep the following workspace mounted")
        router.selection = nil
        try await Task.sleep(for: .milliseconds(400))
        dashboard.layoutSubtreeIfNeeded()
        let afterReader = scrollViews(in: dashboard)
        XCTAssertTrue(workspaceScrolls.contains { original in afterReader.contains { $0 === original } }, "Closing the original must retain the following workspace")
        XCTAssertTrue(WeiboFeedPresence.isVisible, "Closing the original must not clear the active following presence")
        dashboardWindow.contentView = nil
    }

    @MainActor
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func post(
        mid: String,
        uid: String,
        name: String,
        text: String,
        createdAt: Date
    ) -> WeiboPost {
        WeiboPost(
            mid: mid,
            bid: "B\(mid)",
            uid: uid,
            screenName: name,
            text: text,
            createdAt: createdAt,
            fetchedAt: createdAt,
            url: WeiboPost.makeURL(uid: uid, bid: "B\(mid)", mid: mid)
        )
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
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NewsBar Weibo Monitor"
        window.isOpaque = true
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 2_000, "\(name) rendered nearly empty")
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
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (Data(body.utf8), response)
        })
    }
}
