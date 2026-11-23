import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

/// Deterministic comment pages for the reader's design snapshot. No network,
/// no cookies, no clock drift: the page is stamped with the real `now`.
private actor ReaderRenderFeed: WeiboCommentFetching {
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
                text: "夜景那张的高光压得住，这份样张里 5x 之后的锐度掉了。",
                createdAt: now.addingTimeInterval(-900),
                likeCount: 12,
                replyToName: nil,
                isAuthor: false,
                runs: [
                    WeiboCommentRun(kind: .text, text: "夜景那张的高光压得住，参考"),
                    WeiboCommentRun(kind: .link, text: "这份样张", url: "https://example.com/gallery"),
                    WeiboCommentRun(kind: .text, text: "里 5x 之后的锐度掉了。"),
                ]
            ),
            WeiboComment(
                id: "c2-\(mid)",
                mid: mid,
                uid: "77",
                screenName: "李蘑菇",
                avatarURL: nil,
                text: "5x 之后确实会软一点，我补一组 raw 到评论区。",
                createdAt: now.addingTimeInterval(-600),
                likeCount: 34,
                replyToName: "读者甲",
                isAuthor: true
            ),
            WeiboComment(
                id: "c3-\(mid)",
                mid: mid,
                uid: "3",
                screenName: "摄影爱好者",
                avatarURL: nil,
                text: "抓拍成功率确实比参数更重要，等一个夜景长焦的对比。[吃瓜]",
                createdAt: now.addingTimeInterval(-300),
                likeCount: 3,
                replyToName: nil,
                isAuthor: false
            ),
        ]
        return .success(
            page: WeiboCommentPage(
                comments: comments,
                total: 128,
                nextCursor: nil,
                fetchedAt: now,
                tier: .desktop
            ),
            latency: 0.01
        )
    }
}

/// Renders the following reader's reading column at the widths the dashboard
/// actually gives it. The PNGs go to `.build/following-reader-validation` for
/// design review; they are not compared pixel by pixel.
final class FollowingReaderRenderingTests: XCTestCase {
    @MainActor
    func testFollowingReaderRendersAcrossThemesAndWidths() async throws {
        let settings = AppSettings()
        settings.appLanguage = .zh
        // The pane re-loads comments on appearance; this fixture seeds the
        // thread first so the snapshot never shows the skeleton.
        settings.weiboCommentsAutoLoad = false

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FollowingReaderRender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let viewModel = WeiboMonitorViewModel(
            settings: settings,
            commentFetcher: ReaderRenderFeed(),
            commentCache: WeiboCommentCache(root: root)
        )

        let now = Date()
        let entry = FollowingPostEntry(
            post: WeiboPost(
                mid: "9001",
                bid: "B9001",
                uid: "77",
                screenName: "李蘑菇",
                text: """
                夜景样张对比：主摄在 1/15s 下的噪点控制比上一代好一档，长焦的锐度在 5x 之后开始下降。\
                这段正文用来验证 560pt 的阅读量宽，大约每行 36 个汉字，不再像旧版那样铺满整个面板。
                """,
                createdAt: now.addingTimeInterval(-7200),
                fetchedAt: now,
                isRetweet: true,
                retweetText: "上一代在 5x 就开始软，这一代把可用区间推到了 8x。",
                url: WeiboPost.makeURL(uid: "77", bid: "B9001", mid: "9001"),
                commentCount: 128,
                repostCount: 36,
                likeCount: 356,
                metricsFetchedAt: now.addingTimeInterval(-600)
            ),
            user: WeiboMonitorUser(
                uid: "77",
                screenName: "李蘑菇",
                priority: .p0,
                addedAt: now,
                nextDueAt: now.addingTimeInterval(3600)
            )
        )

        let credentials = WeiboCredentials(
            desktopCookieHeader: "SUB=render-fixture; XSRF-TOKEN=render-fixture",
            mobileCookieHeader: nil,
            hasDesktopLogin: true,
            hasMobileLogin: false
        )
        await viewModel.comments.load(post: entry.post, credentials: credentials, force: true)

        let output = URL(fileURLWithPath: ".build/following-reader-validation", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // 1180 window: measured split is [240, 380, 558]; 960 is [380, 579].
        // Render at the real reader width, not at a width derived from ideal
        // column sizes, or the snapshot stops matching the shipping layout.
        settings.appTheme = .modern
        settings.colorScheme = "light"
        try await snapshot(
            pane(entry, viewModel, settings: settings, width: 558),
            size: CGSize(width: 558, height: 900),
            name: "reader-1180-modern-zh",
            appearance: .aqua,
            to: output
        )

        settings.appTheme = .retroEditorial
        try await snapshot(
            pane(entry, viewModel, settings: settings, width: 558),
            size: CGSize(width: 558, height: 900),
            name: "reader-1180-retro-zh",
            appearance: .aqua,
            to: output
        )

        settings.appTheme = .modern
        settings.colorScheme = "dark"
        try await snapshot(
            pane(entry, viewModel, settings: settings, width: 558),
            size: CGSize(width: 558, height: 900),
            name: "reader-1180-modern-dark",
            appearance: .darkAqua,
            to: output
        )

        // 960 window: no account rail, 380pt list leaves 579.
        settings.colorScheme = "light"
        try await snapshot(
            pane(entry, viewModel, settings: settings, width: 579),
            size: CGSize(width: 579, height: 860),
            name: "reader-960-modern-zh",
            appearance: .aqua,
            to: output
        )
    }

    /// Documents the three caps. They are independent constants on purpose: a
    /// single `maxWidth` on the column is what made the body render at 620pt.
    func testReaderMetricsKeepProseNarrowerThanTheColumn() {
        XCTAssertEqual(FollowingReaderMetrics.proseMax, 560)
        XCTAssertEqual(FollowingReaderMetrics.mediaMax, 640)
        XCTAssertEqual(FollowingReaderMetrics.contentMax, 700)
        XCTAssertLessThan(FollowingReaderMetrics.proseMax, FollowingReaderMetrics.contentMax)
        XCTAssertLessThanOrEqual(FollowingReaderMetrics.mediaMax, FollowingReaderMetrics.contentMax)
        XCTAssertEqual(
            FollowingReaderMetrics.commentDividerInset,
            FollowingReaderMetrics.commentInset + FollowingReaderMetrics.commentAvatar + 8,
            "The divider must start where the comment text starts, not under the avatar"
        )
    }

    @MainActor
    private func pane(
        _ entry: FollowingPostEntry,
        _ viewModel: WeiboMonitorViewModel,
        settings: AppSettings,
        width: CGFloat
    ) -> some View {
        FollowingReaderPane(
            entry: entry,
            monitor: viewModel,
            imageSelection: .constant(nil)
        )
        .environment(settings)
        .frame(width: width, height: 900)
    }

    @MainActor
    private func snapshot(
        _ view: some View,
        size: CGSize,
        name: String,
        appearance: NSAppearance.Name,
        to output: URL
    ) async throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NewsBar Following Reader"
        window.isOpaque = true
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 3_000, "\(name) rendered nearly empty")
        try data.write(to: output.appendingPathComponent(name).appendingPathExtension("png"))
        window.contentView = nil
    }

    // MARK: - New comments entry point

    @MainActor
    func testRefreshedCommentsAreReachableFromTheReader() async throws {
        let settings = AppSettings()
        settings.appLanguage = .zh
        // Keep the pane's own `.task` from issuing a third request; the test
        // seeds the thread explicitly so the pending state is deterministic.
        settings.weiboCommentsAutoLoad = false

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FollowingReaderPending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let viewModel = WeiboMonitorViewModel(
            settings: settings,
            commentFetcher: RefreshingReaderFeed(),
            commentCache: WeiboCommentCache(root: root)
        )
        let now = Date()
        let post = WeiboPost(
            mid: "9101",
            bid: "B9101",
            uid: "77",
            screenName: "李蘑菇",
            text: "刷新后应该能看到新评论。",
            createdAt: now.addingTimeInterval(-600),
            fetchedAt: now,
            isRetweet: false,
            retweetText: nil,
            url: WeiboPost.makeURL(uid: "77", bid: "B9101", mid: "9101"),
            commentCount: 3,
            repostCount: nil,
            likeCount: nil,
            metricsFetchedAt: nil
        )
        let credentials = WeiboCredentials(
            desktopCookieHeader: "SUB=render-fixture",
            mobileCookieHeader: nil,
            hasDesktopLogin: true,
            hasMobileLogin: false
        )

        await viewModel.comments.load(post: post, credentials: credentials)
        XCTAssertEqual(viewModel.comments.thread(for: post.mid).comments.count, 2)

        await viewModel.comments.load(post: post, credentials: credentials, force: true)
        let refreshed = viewModel.comments.thread(for: post.mid)
        XCTAssertGreaterThan(refreshed.newComments, 0, "A refresh must surface the fresh comments as pending")
        XCTAssertEqual(refreshed.comments.count, 2, "Pending comments must not reorder the visible rows")

        // The pane renders the banner from this seam. Without asserting it a
        // deleted banner would leave the pending queue unreachable and every
        // controller test would still be green.
        XCTAssertNil(FollowingDiscussionBanner.title(newComments: 0, language: .zh))
        let bannerTitle = try XCTUnwrap(
            FollowingDiscussionBanner.title(newComments: refreshed.newComments, language: .zh)
        )
        XCTAssertTrue(bannerTitle.contains("新评论"))
        XCTAssertTrue(
            FollowingDiscussionBanner.accessibilityLabel(newComments: 2, language: .zh).contains("新评论")
        )

        let entry = FollowingPostEntry(
            post: post,
            user: WeiboMonitorUser(
                uid: "77",
                screenName: "李蘑菇",
                priority: .p0,
                addedAt: now,
                nextDueAt: now.addingTimeInterval(3600)
            )
        )
        let host = NSHostingView(
            rootView: FollowingReaderPane(
                entry: entry,
                monitor: viewModel,
                imageSelection: .constant(nil)
            )
            .environment(settings)
        )
        let size = CGSize(width: 558, height: 860)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()

        let labels = accessibilityLabels(in: host)
        window.contentView = nil
        guard !labels.isEmpty else {
            // Matches the existing precedent: SwiftUI does not build the tree
            // for an off-screen host in every environment. The seam assertion
            // above already ran; this skip only drops the tree check.
            throw XCTSkip("NSHostingView did not expose an accessibility tree while off-screen")
        }
        XCTAssertTrue(
            labels.contains { $0.contains("新评论") },
            "Pending comments need an apply control in the reader; labels: \(labels)"
        )
    }

    private func accessibilityLabels(in element: any NSAccessibilityProtocol, depth: Int = 0) -> [String] {
        guard depth < 12 else { return [] }
        var labels: [String] = []
        if let label = element.accessibilityLabel() {
            labels.append(label)
        }
        for child in element.accessibilityChildren() ?? [] {
            guard let child = child as? any NSAccessibilityProtocol else { continue }
            labels.append(contentsOf: accessibilityLabels(in: child, depth: depth + 1))
        }
        return labels
    }
}

/// Two requests: the first page, then a refresh that returns one new comment.
private actor RefreshingReaderFeed: WeiboCommentFetching {
    private var calls = 0

    func fetchComments(
        mid: String,
        uid: String,
        authorUID: String?,
        cursor: String?,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboCommentOutcome {
        calls += 1
        let ids = calls == 1 ? ["a", "b"] : ["new", "a", "b"]
        let comments = ids.enumerated().map { index, id in
            WeiboComment(
                id: id,
                mid: mid,
                uid: "\(index + 1)",
                screenName: "读者\(id)",
                avatarURL: nil,
                text: "评论 \(id)",
                createdAt: now.addingTimeInterval(-Double(index) * 60),
                likeCount: nil,
                replyToName: nil,
                isAuthor: false,
                runs: nil
            )
        }
        return .success(
            page: WeiboCommentPage(
                comments: comments,
                total: comments.count,
                nextCursor: nil,
                fetchedAt: now,
                tier: .desktop
            ),
            latency: 0.01
        )
    }
}
