import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class DashboardFollowingNavigationTests: XCTestCase {
    func testOpeningFollowingPostActivatesItsReader() async throws {
        let router = NewsNavigationRouter.shared
        let tabs = WorkspaceTabStore.shared
        router.close()
        tabs.terminateAll()
        let settings = AppSettings()
        let previousLanguage = settings.appLanguage
        settings.appLanguage = .en
        let monitor = WeiboMonitorViewModel(settings: settings)
        defer {
            monitor.stop()
            settings.appLanguage = previousLanguage
            router.close()
            tabs.terminateAll()
        }

        let size = CGSize(width: 1180, height: 860)
        let presentation = DashboardReaderPresentationState()
        let host = NSHostingView(rootView: DashboardWindow(
            orchestrator: NewsOrchestrator(),
            weiboMonitor: monitor,
            readerPresentationState: presentation
        ).environment(settings))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        NotificationCenter.default.post(name: .openWeiboFollowFeed, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        var post = WeiboMonitorTestSupport.post()
        post.url = "invalid-fixture-url"
        monitor.openPost(post)
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(router.selection?.url, post.url)
        XCTAssertEqual(tabs.activeRequest?.id, router.selection?.id)
        XCTAssertNotNil(tabs.activeID, "Opening a following post must activate its reader tab")
        XCTAssertEqual(presentation.displayedRequest?.id, router.selection?.id)
        XCTAssertEqual(presentation.phase, .presented)
        XCTAssertTrue(presentation.readerVisible)

        var secondPost = WeiboMonitorTestSupport.post(mid: "1003")
        secondPost.url = "another-invalid-fixture-url"
        monitor.openPost(secondPost)
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(router.selection?.url, secondPost.url)
        XCTAssertEqual(tabs.activeRequest?.id, router.selection?.id)
        XCTAssertEqual(presentation.displayedRequest?.id, router.selection?.id)
        XCTAssertEqual(presentation.phase, .presented)
        XCTAssertTrue(presentation.readerVisible)
    }

    func testShowingFollowingDoesNotCloseAnOpenReader() async throws {
        let router = NewsNavigationRouter.shared
        let tabs = WorkspaceTabStore.shared
        router.close()
        tabs.terminateAll()
        defer {
            router.close()
            tabs.terminateAll()
        }

        let request = NewsReaderRequest(
            url: "invalid-fixture-url",
            title: "Fixture",
            item: nil,
            surface: "test",
            contextID: nil,
            consentEpoch: UUID(),
            privateSession: true
        )
        router.selection = request

        let size = CGSize(width: 1180, height: 860)
        let host = NSHostingView(rootView: DashboardWindow(orchestrator: NewsOrchestrator())
            .environment(AppSettings()))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        NotificationCenter.default.post(name: .openWeiboFollowFeed, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(router.selection?.id, request.id, "Showing the following feed must not dismiss an open reader")
        XCTAssertEqual(tabs.activeRequest?.id, request.id)
    }

}
