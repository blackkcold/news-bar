import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class QuickSearchRenderingTests: XCTestCase {
    func testQuickSearchModeSwitchKeepsDraftQuery() {
        var quickQuery = "draft from local search"
        var aiQuestion = ""

        QuickSearchSurface.transferDraft(
            from: .local,
            to: .ai,
            quickQuery: &quickQuery,
            aiQuestion: &aiQuestion
        )
        XCTAssertEqual(aiQuestion, "draft from local search")

        aiQuestion = "draft edited in AI mode"
        QuickSearchSurface.transferDraft(
            from: .ai,
            to: .archive,
            quickQuery: &quickQuery,
            aiQuestion: &aiQuestion
        )
        XCTAssertEqual(quickQuery, "draft edited in AI mode")
    }

    func testQuickSearchOpensResultOnlyForAllowedHTTPSReaderURL() {
        let allowedNews = NewsItem(
            title: "Allowed",
            url: "https://news.example/story",
            source: .weibo
        )
        let unsafeNews = NewsItem(
            title: "Unsafe destination",
            url: "https://news.example/story",
            source: .weibo,
            readerURL: "javascript:alert(1)"
        )
        let unsafeHit = SearchHit(
            url: "http://search.example/result",
            title: "HTTP result",
            snippet: "Not allowed in the reader",
            provider: .tavily,
            providerRank: 1
        )

        XCTAssertEqual(
            QuickSearchPanel.allowedReaderURL(for: .news(allowedNews))?.absoluteString,
            "https://news.example/story"
        )
        XCTAssertNil(QuickSearchPanel.allowedReaderURL(for: .news(unsafeNews)))
        XCTAssertNil(QuickSearchPanel.allowedReaderURL(for: unsafeHit))
    }

    func testEdgeButtonHidesWhenResearchOrAnswerOverlayIsOpen() {
        XCTAssertTrue(QuickSearchEdgeButton.shouldBeVisible(
            readerPresented: true,
            researchOpen: false,
            searchOrArchiveOpen: false,
            selectionExplanationOpen: false
        ))
        XCTAssertFalse(QuickSearchEdgeButton.shouldBeVisible(
            readerPresented: true,
            researchOpen: true,
            searchOrArchiveOpen: false,
            selectionExplanationOpen: false
        ))
        XCTAssertFalse(QuickSearchEdgeButton.shouldBeVisible(
            readerPresented: true,
            researchOpen: false,
            searchOrArchiveOpen: true,
            selectionExplanationOpen: false
        ))
        XCTAssertFalse(QuickSearchEdgeButton.shouldBeVisible(
            readerPresented: true,
            researchOpen: false,
            searchOrArchiveOpen: false,
            selectionExplanationOpen: true
        ))
        XCTAssertFalse(QuickSearchEdgeButton.shouldBeVisible(
            readerPresented: false,
            researchOpen: false,
            searchOrArchiveOpen: false,
            selectionExplanationOpen: false
        ))
    }

    func testArchiveReplayCloseControlRenders() throws {
        let closeButton = QuickSearchArchiveReplayCloseButton(language: .en, action: {})

        let image = try Self.render(closeButton, size: CGSize(width: 160, height: 80))

        XCTAssertGreaterThan(image.count, 100)
        XCTAssertEqual(QuickSearchAccessibilityLabels.close(language: .en), "Close quick search")
    }

    func testQuickSearchSurfacesRenderInChineseAndEnglishWithAccessibleLabels() throws {
        let settings = AppSettings()
        let archiveController = AISearchArchiveController()
        let languages: [AppLanguage] = [.zh, .en]

        for language in languages {
            let labels = [
                QuickSearchAccessibilityLabels.surface(.local, language: language),
                QuickSearchAccessibilityLabels.surface(.web, language: language),
                QuickSearchAccessibilityLabels.surface(.ai, language: language),
                QuickSearchAccessibilityLabels.surface(.archive, language: language),
                QuickSearchAccessibilityLabels.close(language: language),
                QuickSearchAccessibilityLabels.copy(language: language),
                QuickSearchAccessibilityLabels.openSource("Source", language: language),
            ]
            XCTAssertTrue(labels.allSatisfy { !$0.isEmpty && !$0.contains("reader.quickSearch.") })

            for surface in QuickSearchSurface.allCases {
                let panel = QuickSearchPanel(
                    model: QuickSearchModel(),
                    aiModel: AISearchPanelModel(),
                    archiveController: archiveController,
                    activeNewsItems: [],
                    readingHistory: [],
                    settings: settings,
                    language: language,
                    initialSurface: surface,
                    onOpenResult: { _ in },
                    onOpenSource: { _ in },
                    onClose: {},
                    onConfigureAI: {}
                )
                let image = try Self.render(panel, size: CGSize(width: 520, height: 720))
                XCTAssertGreaterThan(image.count, 500, "\(surface) should render in \(language)")
            }
        }
    }

    private static func render<Content: View>(_ view: Content, size: CGSize) throws -> Data {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        window.contentView = nil
        return data
    }
}
