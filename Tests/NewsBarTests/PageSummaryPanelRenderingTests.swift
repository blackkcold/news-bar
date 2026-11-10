import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class PageSummaryPanelRenderingTests: XCTestCase {
    private func makeInput(language: AppLanguage) -> PageSummaryInput {
        PageSummaryInput.article(
            title: language == .en ? "A new view of technology" : "科技与生活的新视角",
            url: "https://www.ifanr.com/story",
            text: String(repeating: "正文内容。", count: 240),
            language: language,
            isPrivate: false
        )
    }

    private func makeSummary(language: AppLanguage) -> PageSummary {
        let item = NewsItem(
            title: language == .en ? "The original report" : "原始报道",
            url: "https://www.ifanr.com/story",
            source: .weibo
        )
        return PageSummary(
            scope: .article,
            oneLine: language == .en
                ? "The article argues that on-device AI is moving from demos to everyday tools."
                : "文章认为端侧 AI 正在从演示走向日常工具。",
            points: [
                PageSummaryPoint(
                    text: language == .en
                        ? "The writer separates useful assistance from speculative automation."
                        : "作者把有用的辅助与投机的自动化区分开来。",
                    citationIndex: 1
                ),
                PageSummaryPoint(
                    text: language == .en
                        ? "Privacy is framed as a product constraint, not an afterthought."
                        : "隐私被视为产品约束，而不是事后补丁。",
                    citationIndex: nil
                ),
                PageSummaryPoint(
                    text: language == .en
                        ? "The conclusion is cautious about replacing human judgment."
                        : "结论对取代人的判断保持谨慎。",
                    citationIndex: nil
                ),
            ],
            citations: [PageSummaryCitation(index: 1, position: 0, item: item)],
            generatedAt: Date(),
            model: "test-model",
            providerID: "test-provider",
            providerName: "Test Provider",
            inputCharacters: 1200,
            wasTruncated: false
        )
    }

    func testOverviewPhasesRenderAtRailWidth() throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/auxiliary-rail-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let languages: [AppLanguage] = [.zh, .en]

        for language in languages {
            let context = PageSummaryPanelContext(
                title: language == .en ? "A new view of technology" : "科技与生活的新视角",
                url: "https://www.ifanr.com/story",
                isPrivate: false,
                language: language
            )
            let input = makeInput(language: language)
            let summary = makeSummary(language: language)

            let variants: [(String, PageSummaryPanelPhase, PageSummary?, Bool)] = [
                ("preparing", .preparing, nil, false),
                ("disclosure", .disclosure, nil, true),
                ("ready-to-generate", .readyToGenerate, nil, true),
                ("generating-with-previous", .generating, summary, true),
                ("ready", .ready, summary, true),
                ("failed", .failed("Test Provider did not answer."), nil, true),
                ("failed-with-previous", .failed("Test Provider did not answer."), summary, true),
                ("unavailable", .unavailable(language == .en ? "No readable page text" : "没有可读页面正文"), nil, false),
            ]

            for (name, phase, previous, showsInput) in variants {
                let panel = PageSummaryPanel(
                    context: context,
                    phase: phase,
                    input: showsInput ? input : nil,
                    summary: previous,
                    errorMessage: phase == .generating ? nil : (name == "failed-with-previous" ? "Test Provider did not answer." : nil),
                    providerName: "Test Provider",
                    onGenerate: { _ in },
                    onCancelDisclosure: {},
                    onRetry: {},
                    onOpenSettings: {},
                    onOpenCitation: { _ in }
                )
                .frame(width: 332, height: 520)
                .environment(\.colorScheme, .light)

                let image = try Self.render(panel, size: CGSize(width: 332, height: 520))
                XCTAssertGreaterThan(image.count, 500, "\(name) should render in \(language)")
                try image.write(to: output.appendingPathComponent("overview-\(name)-\(language.rawValue).png"))
            }
        }
    }

    private func makeExternalSummary(language: AppLanguage) -> PageSummary {
        let page = PageSummarySource(
            index: 1,
            url: "https://www.ifanr.com/story",
            title: language == .en ? "A new view of technology" : "科技与生活的新视角",
            host: "www.ifanr.com",
            publishedAt: nil,
            kind: .currentPage,
            type: nil,
            adoption: nil,
            reason: nil
        )
        let external = PageSummarySource(
            index: 2,
            url: "https://example.com/report",
            title: language == .en ? "The original report" : "原始报道",
            host: "example.com",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .external,
            type: .secondary,
            adoption: .supporting,
            reason: .assessed
        )
        return PageSummary(
            scope: .article,
            oneLine: language == .en
                ? "The article argues that on-device AI is moving from demos to everyday tools."
                : "文章认为端侧 AI 正在从演示走向日常工具。",
            points: [
                PageSummaryPoint(
                    text: language == .en
                        ? "The writer separates useful assistance from speculative automation."
                        : "作者把有用的辅助与投机的自动化区分开来。",
                    citationIndex: nil,
                    citationIndices: [2]
                ),
            ],
            citations: [],
            generatedAt: Date(),
            model: "test-model",
            providerID: "test-provider",
            providerName: "Test Provider",
            inputCharacters: 2400,
            wasTruncated: false,
            sources: [page, external],
            basis: .externalSupported,
            retrieval: PageSummaryRetrieval(
                foundCount: 2,
                readCount: 2,
                adoptedCount: 1,
                rejectedCount: 1,
                queryCount: 2,
                httpAttempts: 2,
                notes: [.conflictingSources]
            )
        )
    }

    func testOverviewWithExternalSourcesRendersAtRailWidth() throws {
        let language = AppLanguage.zh
        let input = makeInput(language: language)
        let panel = PageSummaryPanel(
            context: PageSummaryPanelContext(
                title: input.title,
                url: input.url,
                isPrivate: false,
                language: language
            ),
            phase: .ready,
            input: input,
            summary: makeExternalSummary(language: language),
            errorMessage: nil,
            providerName: "Test Provider",
            webSupplement: true,
            stage: .idle,
            assessmentEnabled: true
        )
        .frame(width: 332, height: 520)
        .environment(\.colorScheme, .light)

        let image = try Self.render(panel, size: CGSize(width: 332, height: 520))
        XCTAssertGreaterThan(image.count, 500)

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/auxiliary-rail-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try image.write(to: output.appendingPathComponent("overview-external-zh.png"))

        let host = NSHostingView(rootView: panel)
        host.frame = NSRect(x: 0, y: 0, width: 332, height: 520)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 332.5)
    }

    func testExternalStageRowRendersDuringGeneration() throws {
        let language = AppLanguage.zh
        let input = makeInput(language: language)
        let panel = PageSummaryPanel(
            context: PageSummaryPanelContext(
                title: input.title,
                url: input.url,
                isPrivate: false,
                language: language
            ),
            phase: .generating,
            input: input,
            summary: nil,
            errorMessage: nil,
            providerName: "Test Provider",
            webSupplement: true,
            stage: .reading(index: 2, total: 3),
            assessmentEnabled: true
        )
        .frame(width: 332, height: 520)

        let image = try Self.render(panel, size: CGSize(width: 332, height: 520))
        XCTAssertGreaterThan(image.count, 500)
    }

    func testPrivateDisclosureRendersWithoutExternalSearch() throws {
        let language = AppLanguage.en
        let input = makeInput(language: language)
        let panel = PageSummaryPanel(
            context: PageSummaryPanelContext(
                title: input.title,
                url: input.url,
                isPrivate: true,
                language: language
            ),
            phase: .disclosure,
            input: input,
            summary: nil,
            errorMessage: nil,
            providerName: "Test Provider",
            webSupplement: true
        )
        .frame(width: 332, height: 520)

        let image = try Self.render(panel, size: CGSize(width: 332, height: 520))
        XCTAssertGreaterThan(image.count, 500)
    }

    func testOverviewPanelDoesNotAskForMoreThanTheRailWidth() {
        let language = AppLanguage.en
        let panel = PageSummaryPanel(
            context: PageSummaryPanelContext(
                title: "A new view of technology",
                url: "https://www.ifanr.com/story",
                isPrivate: false,
                language: language
            ),
            phase: .ready,
            input: makeInput(language: language),
            summary: makeSummary(language: language),
            errorMessage: nil,
            providerName: "Test Provider"
        )
        .frame(width: 332, height: 520)

        let host = NSHostingView(rootView: panel)
        host.frame = NSRect(x: 0, y: 0, width: 332, height: 520)
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
