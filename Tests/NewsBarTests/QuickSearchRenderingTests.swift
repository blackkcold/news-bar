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
            QuickSearchContent.allowedReaderURL(for: .news(allowedNews))?.absoluteString,
            "https://news.example/story"
        )
        XCTAssertNil(QuickSearchContent.allowedReaderURL(for: .news(unsafeNews)))
        XCTAssertNil(QuickSearchContent.allowedReaderURL(for: unsafeHit))
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
        XCTAssertFalse(QuickSearchEdgeButton.shouldBeVisible(
            readerPresented: true,
            researchOpen: false,
            searchOrArchiveOpen: false,
            selectionExplanationOpen: false,
            auxiliaryRailOpen: true
        ))
    }

    func testQuickSearchSurfacesRenderAtRailWidthInChineseAndEnglish() throws {
        let settings = AppSettings()
        let archiveController = AISearchArchiveController()
        let languages: [AppLanguage] = [.zh, .en]
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/auxiliary-rail-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

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
                let content = QuickSearchContent(
                    model: QuickSearchModel(),
                    aiModel: AISearchPanelModel(privacyAcknowledged: false),
                    archiveController: archiveController,
                    activeNewsItems: [],
                    readingHistory: [],
                    settings: settings,
                    language: language,
                    surface: .constant(surface),
                    selectedArchiveEntry: .constant(nil),
                    isActive: true,
                    fillsAvailableHeight: true,
                    availableHeight: 451,
                    onOpenResult: { _ in },
                    onOpenSource: { _ in },
                    onConfigureAI: {}
                )
                .frame(width: 332, height: 451)

                let image = try Self.render(content, size: CGSize(width: 332, height: 451))
                XCTAssertGreaterThan(image.count, 500, "\(surface) should render in \(language)")
                try image.write(to: output.appendingPathComponent("quick-search-\(surface.rawValue)-\(language.rawValue).png"))
            }
        }
    }

    func testQuickSearchContentFitsTheRailWithoutHorizontalOverflow() throws {
        let settings = AppSettings()
        let content = QuickSearchContent(
            model: QuickSearchModel(),
            aiModel: AISearchPanelModel(privacyAcknowledged: true),
            archiveController: AISearchArchiveController(),
            activeNewsItems: [],
            readingHistory: [],
            settings: settings,
            language: .en,
            surface: .constant(.archive),
            selectedArchiveEntry: .constant(nil),
            isActive: true,
            fillsAvailableHeight: true,
            availableHeight: 451,
            onOpenResult: { _ in },
            onOpenSource: { _ in },
            onConfigureAI: {}
        )
        .frame(width: 332, height: 451)

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 332, height: 451)
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(host.fittingSize.width, 332.5)
    }

    private static func render<Content: View>(_ view: Content, size: CGSize) throws -> Data {
        let host = NSHostingView(rootView: ZStack {
            Color(nsColor: .windowBackgroundColor)
            view
        })
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
