import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

/// Geometry and rendering checks for the answer canvas.
///
/// These are the numbers the paper design could not answer: does a six-section
/// answer fit a reader-sized panel, and does a two-line answer stay a small
/// card instead of an empty 400 pt box.
final class AnswerCanvasRenderingTests: XCTestCase {
    // MARK: - Geometry rule

    func testClampedHeightHugsShortContentAndCapsLongContent() {
        XCTAssertEqual(AnswerDocumentView.clampedHeight(contentHeight: 0, maxHeight: 380), 380)
        XCTAssertEqual(AnswerDocumentView.clampedHeight(contentHeight: 180, maxHeight: 380), 180)
        XCTAssertEqual(AnswerDocumentView.clampedHeight(contentHeight: 900, maxHeight: 380), 380)
        XCTAssertEqual(AnswerDocumentView.clampedHeight(contentHeight: 20, maxHeight: 380), 96)
    }

    // MARK: - Canvas

    @MainActor
    func testLongAnswerStaysWithinItsCap() {
        let view = AnswerDocumentView(
            document: Self.eventDocument(blocks: 6),
            language: .zh,
            maxHeight: 380,
            onOpenSource: { _ in }
        )
        .frame(width: 392)

        let size = Self.fittingSize(view)
        XCTAssertLessThanOrEqual(size.height, 381)
        XCTAssertGreaterThanOrEqual(size.height, 96)
    }

    // MARK: - Streaming canvas

    /// While text streams the canvas holds its cap. A card that resizes on every
    /// revealed character resized the scroll view ~15 times a second, which is
    /// where the previous frame's glyphs were left on screen.
    func testStreamingCanvasHoldsItsCapAndOnlyTheFinishedAnswerHugs() {
        XCTAssertEqual(AnswerDocumentView.canvasHeight(contentHeight: 120, maxHeight: 380, isStreaming: true), 380)
        XCTAssertEqual(AnswerDocumentView.canvasHeight(contentHeight: 120, maxHeight: 380, isStreaming: false), 120)
        XCTAssertEqual(AnswerDocumentView.canvasHeight(contentHeight: 900, maxHeight: 380, isStreaming: false), 380)
        XCTAssertEqual(AnswerDocumentView.canvasHeight(contentHeight: 0, maxHeight: 380, isStreaming: false), 380)
    }

    @MainActor
    func testStreamingAnswerFillsTheCapAndTheFinishedOneShrinks() {
        let document = Self.eventDocument(blocks: 3)
        let streaming = AnswerDocumentView(
            document: document,
            language: .zh,
            maxHeight: 380,
            onOpenSource: { _ in },
            isStreaming: true
        )
        .frame(width: 392)
        XCTAssertEqual(Self.fittingSize(streaming).height, 380, accuracy: 0.5)

        let finished = AnswerDocumentView(
            document: document,
            language: .zh,
            maxHeight: 380,
            onOpenSource: { _ in }
        )
        .frame(width: 392)
        let height = Self.fittingSize(finished).height
        XCTAssertLessThanOrEqual(height, 380.5)
        XCTAssertGreaterThanOrEqual(height, 96)
    }

    @MainActor
    func testDegradedAnswerWithoutBlocksStillRenders() {
        let document = AnswerDocument(
            kind: .event,
            oneLine: L10n.string("reader.search.noCitations", language: .zh),
            blocks: [],
            sources: [Self.source(1)],
            mode: .web,
            model: "m",
            thinking: .medium,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            question: "q"
        )
        let view = AnswerDocumentView(
            document: document,
            language: .zh,
            maxHeight: 380,
            onOpenSource: { _ in }
        )
        .frame(width: 392)

        let size = Self.fittingSize(view)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThanOrEqual(size.height, 381)
    }

    // MARK: - Definition rows

    @MainActor
    func testWritesSelectionLayoutFixtures() throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/answer-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let cases: [(String, AnswerDocument)] = [
            ("selection-spec-zh", Self.specDocument()),
            ("selection-quote-zh", Self.quoteDocument())
        ]
        for (name, document) in cases {
            let view = ZStack {
                Color(nsColor: .windowBackgroundColor)
                AnswerDocumentView(
                    document: document,
                    language: .zh,
                    maxHeight: 380,
                    onOpenSource: { _ in }
                )
                .padding(14)
            }
            .frame(width: 420, height: 420)
            let data = try Self.snapshot(view, size: CGSize(width: 420, height: 420))
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }

        let notice = ZStack {
            Color(nsColor: .windowBackgroundColor)
            AnswerDocumentView(
                document: Self.specDocument(mode: .offline),
                language: .zh,
                maxHeight: 380,
                onOpenSource: { _ in },
                notice: L10n.string("answer.auto.failed", language: .zh)
            )
            .padding(14)
        }
        .frame(width: 420, height: 460)
        let noticeData = try Self.snapshot(notice, size: CGSize(width: 420, height: 460))
        try noticeData.write(to: output.appendingPathComponent("selection-auto-fallback-zh.png"))
    }

    // MARK: - Panel

    @MainActor
    func testExplainPanelKeepsItsWidthAndFitsAReaderWindow() async {
        let model = await Self.readyModel(Self.eventDocument(blocks: 6))
        let view = SelectionExplainPanel(
            model: model,
            language: .zh,
            providerName: "Provider",
            onClose: {},
            onCopy: { _ in },
            onRetry: {},
            onOpenSettings: {},
            onOpenSource: { _ in },
            canLookUp: false,
            onLookUp: {},
            onConfirmLookUp: {},
            onCancelLookUp: {}
        )

        let size = Self.fittingSize(view)
        XCTAssertEqual(size.width, 420, accuracy: 1)
        // The reader area on a 720 pt window is about 600 pt after toolbar and
        // footer; the card must leave the article visible behind it.
        XCTAssertLessThanOrEqual(size.height, 620)
    }

    @MainActor
    func testShortAnswerProducesAShorterPanel() async {
        let short = await Self.readyModel(Self.eventDocument(blocks: 1))
        let long = await Self.readyModel(Self.eventDocument(blocks: 6))
        let shortHeight = Self.fittingSize(Self.panel(short)).height
        let longHeight = Self.fittingSize(Self.panel(long)).height
        XCTAssertLessThan(shortHeight, longHeight)
    }

    // MARK: - Visual fixtures

    /// Writes the two card states the work is judged on, so a design or
    /// contrast regression is visible without launching the app.
    @MainActor
    func testWritesUIValidationSnapshots() async throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/answer-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let offline = await Self.readyModel(Self.termDocument())
        let web = Self.eventDocument(blocks: 6)
        let searchModel = await Self.readySearchModel(web)

        let cases: [(String, AnyView, ColorScheme)] = [
            ("explain-offline-zh", AnyView(Self.panel(offline).padding(16)), .light),
            ("search-web-zh", AnyView(Self.searchPanel(searchModel).padding(16)), .light),
            ("explain-offline-dark", AnyView(Self.panel(offline).padding(16)), .dark)
        ]

        for (name, view, scheme) in cases {
            let data = try Self.snapshot(
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    view
                }
                .frame(width: 460, height: 720)
                .environment(\.colorScheme, scheme),
                size: CGSize(width: 460, height: 720)
            )
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }
    }

    @MainActor
    private static func searchPanel(_ model: AISearchPanelModel) -> some View {
        AISearchPanel(
            model: model,
            language: .zh,
            providerName: "Provider",
            modelName: "test-model",
            webEnabled: true,
            onSubmit: {},
            onRetry: {},
            onClose: {},
            onOpenCitation: { _ in },
            onCopy: { _ in },
            onOpenSettings: {}
        )
    }

    @MainActor
    private static func readySearchModel(_ document: AnswerDocument) async -> AISearchPanelModel {
        let model = AISearchPanelModel(runner: { _, _, _, _ in document })
        model.runInjected(question: document.question ?? "q", scope: .web, page: nil)
        for _ in 0..<200 {
            if model.state == .done { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return model
    }

    @MainActor
    private static func snapshot<Content: View>(_ view: Content, size: CGSize) throws -> Data {
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
        XCTAssertGreaterThan(data.count, 4_000)
        window.contentView = nil
        return data
    }

    private static func termDocument() -> AnswerDocument {
        AnswerDocument(
            kind: .term,
            oneLine: "量化宽松是央行通过购买资产向市场注入流动性的政策工具。",
            blocks: [
                AnswerBlock(
                    id: 0,
                    heading: "定义",
                    body: "央行在利率已经很低时，通过买入国债等资产压低长期利率，向银行体系注入资金。"
                ),
                AnswerBlock(
                    id: 1,
                    heading: "要点",
                    body: "目的是压低融资成本、提振需求，而不是直接印钞发钱。"
                ),
                AnswerBlock(
                    id: 2,
                    heading: "常见误解",
                    body: "把它等同于财政刺激、或认为一定引发恶性通胀。\n两者都要看当时的产出缺口。"
                )
            ],
            sources: [],
            mode: .offline,
            model: "test-model",
            thinking: .off,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            question: nil
        )
    }

    // MARK: - Fixtures

    @MainActor
    private static func panel(_ model: SelectionExplainModel) -> some View {
        SelectionExplainPanel(
            model: model,
            language: .zh,
            providerName: "Provider",
            onClose: {},
            onCopy: { _ in },
            onRetry: {},
            onOpenSettings: {},
            onOpenSource: { _ in },
            canLookUp: false,
            onLookUp: {},
            onConfirmLookUp: {},
            onCancelLookUp: {}
        )
    }

    @MainActor
    private static func readyModel(_ document: AnswerDocument) async -> SelectionExplainModel {
        let model = SelectionExplainModel(explainer: { _ in document })
        model.explain("选中的文字", settings: AppSettings())
        for _ in 0..<200 {
            if case .ready = model.state { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return model
    }

    @MainActor
    private static func fittingSize<Content: View>(_ view: Content) -> CGSize {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.contentView = nil
        return size
    }

    private static func eventDocument(blocks: Int) -> AnswerDocument {
        let headings = ["概览", "时间线", "前因", "经过", "后果", "待观察"]
        let bodies = [
            "一款新芯片在本周发布，厂商称其能效比上一代提升 30%[1]。",
            "3 月 4 日发布，3 月 18 日开售[1]。\n- 首批备货 20 万台[2]\n- 定价与上一代持平",
            "上一代产品在散热上被批评，这一代换了封装[2]。",
            "发布会当天公布了完整规格，媒体已在现场实测[1][2]。",
            "对轻薄本市场影响最大，服务器产品线要等到下半年[3]。",
            "需要观察首销后的实际功耗表现，以及第三方拆解结果。"
        ]
        let items = (0..<blocks).map { index in
            AnswerBlock(
                id: index,
                heading: headings[index % headings.count],
                body: bodies[index % bodies.count]
            )
        }
        return AnswerDocument(
            kind: .event,
            oneLine: "新芯片发布，能效提升是重点，实际表现仍待首销验证。",
            blocks: items,
            sources: (1...3).map(source),
            mode: .web,
            model: "test-model",
            thinking: .medium,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            question: "这次发布有什么变化？"
        )
    }

    // MARK: - Fixtures

    private static func specDocument(mode: AnswerMode = .web) -> AnswerDocument {
        AnswerDocument(
            kind: .number,
            oneLine: "这一代在厚度与重量上都有变化，价格保持不变。",
            blocks: [
                AnswerBlock(
                    id: 0,
                    heading: "关键规格",
                    body: """
                    - 尺寸与重量：7.9 毫米厚、199 克重，支持 IP68 防水防尘，浸水仍可使用[1]
                    - 参考价格：127.71 元
                    - 电池：5000 毫安时
                    """
                )
            ],
            sources: [source(1)],
            mode: .web,
            model: "test-model",
            thinking: .medium,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            question: "有什么变化？"
        )
    }

    private static func quoteDocument() -> AnswerDocument {
        AnswerDocument(
            kind: .event,
            oneLine: "厂商在发布会上说明了这一代的变化。",
            blocks: [
                AnswerBlock(
                    id: 0,
                    heading: "原话",
                    body: """
                    > 这一代换了封装，散热是重点，功耗表现要等首销之后才能确认。
                    > 我们也在现场做了实测，长时间负载下温度比上一代低。
                    > 具体数据会在评测里公布。
                    """
                ),
                AnswerBlock(
                    id: 1,
                    heading: "关键规格",
                    body: "厚度与重量都有变化，价格保持不变。"
                )
            ],
            sources: [source(1)],
            mode: .web,
            model: "test-model",
            thinking: .medium,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            question: "有什么变化？"
        )
    }

    private static func source(_ index: Int) -> AISearchSource {
        AISearchSource(
            index: index,
            url: "https://source\(index).example/story",
            title: "来源 \(index)：一篇足够长的标题用来测试两行截断",
            text: String(repeating: "正文", count: 200)
        )
    }
}
