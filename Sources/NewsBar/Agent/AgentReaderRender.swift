import AppKit
import Foundation
import SwiftUI

/// Renders the following reader off-screen to a PNG.
///
/// The window is never ordered front and the app is put in the prohibited
/// activation policy, so an agent can inspect a layout while the real app keeps
/// running. Fixtures carry content only; width, theme and language can be
/// overridden on the command line.
enum AgentReaderRender {
    struct Fixture: Decodable {
        struct Post: Decodable {
            var mid: String
            var bid: String?
            var uid: String
            var screenName: String
            var text: String
            var createdAt: Date
            var fetchedAt: Date?
            var isLongText: Bool?
            var isRetweet: Bool?
            var retweetText: String?
            var imageURLs: [String]?
            var commentCount: Int?
            var repostCount: Int?
            var likeCount: Int?
        }

        struct User: Decodable {
            var uid: String
            var screenName: String
            var avatarURL: String?
            var priority: String?
        }

        var width: Double?
        var height: Double?
        var theme: String?
        var language: String?
        var post: Post
        var user: User
        var comments: [WeiboComment]?
    }

    static func run(
        _ arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) async -> Int32 {
        var fixturePath: String?
        var outPath: String?
        var width: Double?
        var height: Double?
        var theme: String?
        var language: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--out":
                outPath = next(arguments, index)
                index += 2
            case "--width":
                width = next(arguments, index).flatMap(Double.init)
                index += 2
            case "--height":
                height = next(arguments, index).flatMap(Double.init)
                index += 2
            case "--theme":
                theme = next(arguments, index)
                index += 2
            case "--language":
                language = next(arguments, index)
                index += 2
            default:
                if argument.hasPrefix("-") {
                    stderr("Unknown option: \(argument)")
                    return 2
                }
                fixturePath = argument
                index += 1
            }
        }

        guard let fixturePath else {
            stderr("render-reader wants a fixture path")
            return 2
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        } catch {
            stderr("Cannot read \(fixturePath): \(error.localizedDescription)")
            return 2
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture: Fixture
        do {
            fixture = try decoder.decode(Fixture.self, from: data)
        } catch {
            stderr("Cannot decode fixture: \(error.localizedDescription)")
            return 2
        }

        let out = URL(fileURLWithPath: outPath ?? ".build/agent-test/reader.png")
        try? FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let resolvedWidth = width ?? fixture.width ?? 558
        let resolvedHeight = height ?? fixture.height ?? 900

        let result = await render(
            fixture,
            width: resolvedWidth,
            height: resolvedHeight,
            theme: theme ?? fixture.theme ?? "modern",
            language: language ?? fixture.language ?? "zh",
            out: out
        )

        switch result {
        case .success(let report):
            return AgentHeadless.emit(report, stdout: stdout, stderr: stderr)
        case .failure(let failure):
            stderr(failure.message)
            return 2
        }
    }

    @MainActor
    private static func render(
        _ fixture: Fixture,
        width: Double,
        height: Double,
        theme: String,
        language: String,
        out: URL
    ) async -> Result<Report, RenderFailure> {
        let settings = AppSettings()
        settings.appTheme = AppTheme(rawValue: theme) ?? .modern
        settings.appLanguage = AppLanguage(rawValue: language) ?? .zh
        settings.weiboCommentsAutoLoad = false

        let post = makePost(fixture.post)
        let user = makeUser(fixture.user, post: post)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarAgentRender-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let fetcher = StaticCommentFetcher(comments: fixture.comments ?? [], now: Date())
        let viewModel = WeiboMonitorViewModel(
            settings: settings,
            commentFetcher: fetcher,
            commentCache: WeiboCommentCache(root: cacheRoot)
        )
        await viewModel.comments.load(post: post, credentials: .none, force: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let view = FollowingReaderPane(
            entry: FollowingPostEntry(post: post, user: user),
            monitor: viewModel,
            imageSelection: .constant(nil)
        )
        .environment(settings)
        .frame(width: width, height: height)

        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return fail("Cannot allocate a bitmap for \(Int(width))x\(Int(height))")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return fail("Cannot encode the rendered bitmap as PNG")
        }
        guard png.count > 3_000 else {
            return fail("Rendered image is nearly empty (\(png.count) bytes)")
        }
        do {
            try png.write(to: out)
        } catch {
            return fail("Cannot write \(out.path): \(error.localizedDescription)")
        }
        window.contentView = nil

        return .success(
            Report(
                ok: true,
                out: out.path,
                width: width,
                height: height,
                theme: settings.appTheme.rawValue,
                language: settings.appLanguage.rawValue,
                comments: viewModel.comments.thread(for: post.mid).comments.count
            )
        )
    }

    private static func makePost(_ fixture: Fixture.Post) -> WeiboPost {
        WeiboPost(
            mid: fixture.mid,
            bid: fixture.bid,
            uid: fixture.uid,
            screenName: fixture.screenName,
            text: fixture.text,
            createdAt: fixture.createdAt,
            fetchedAt: fixture.fetchedAt ?? fixture.createdAt,
            isLongText: fixture.isLongText ?? false,
            isRetweet: fixture.isRetweet ?? false,
            retweetText: fixture.retweetText,
            imageURLs: fixture.imageURLs ?? [],
            url: WeiboPost.makeURL(uid: fixture.uid, bid: fixture.bid ?? fixture.mid, mid: fixture.mid),
            commentCount: fixture.commentCount,
            repostCount: fixture.repostCount,
            likeCount: fixture.likeCount
        )
    }

    private static func makeUser(_ fixture: Fixture.User, post: WeiboPost) -> WeiboMonitorUser {
        WeiboMonitorUser(
            uid: fixture.uid,
            screenName: fixture.screenName,
            avatarURL: fixture.avatarURL,
            priority: WeiboMonitorPriority(rawValue: fixture.priority ?? "") ?? .p0,
            addedAt: post.createdAt,
            nextDueAt: post.createdAt.addingTimeInterval(3600)
        )
    }

    private static func next(_ arguments: [String], _ index: Int) -> String? {
        let next = index + 1
        return arguments.indices.contains(next) ? arguments[next] : nil
    }

    private static func fail(_ message: String) -> Result<Report, RenderFailure> {
        .failure(RenderFailure(message: message))
    }

    private struct Report: Encodable {
        let ok: Bool
        let out: String
        let width: Double
        let height: Double
        let theme: String
        let language: String
        let comments: Int
    }

    /// Keeps `Result` on a real error type while the guard sites stay readable.
    private struct RenderFailure: Error {
        let message: String
    }
}

/// Serves the fixture's comments once; the reader never hits the network in a
/// render check.
private actor StaticCommentFetcher: WeiboCommentFetching {
    let comments: [WeiboComment]
    let now: Date

    init(comments: [WeiboComment], now: Date) {
        self.comments = comments
        self.now = now
    }

    func fetchComments(
        mid: String,
        uid: String,
        authorUID: String?,
        cursor: String?,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboCommentOutcome {
        .success(
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
