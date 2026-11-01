import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NewsBar

@MainActor
final class DashboardReaderPresentationRenderingTests: XCTestCase {
    func testOlderDismissalDoesNotFinishNewerDismissal() async throws {
        let state = DashboardReaderPresentationState()
        let first = makeRequest(title: "First synthetic article")
        let replacement = makeRequest(title: "Replacement synthetic article")

        state.present(
            request: first,
            size: CGSize(width: 1180, height: 860),
            isWide: true,
            listWidth: 400,
            reduceMotion: false,
            isRetro: false,
            origin: nil
        )
        try await Task.sleep(for: .milliseconds(30))
        state.dismiss(reduceMotion: false)
        try await Task.sleep(for: .milliseconds(100))
        state.present(
            request: replacement,
            size: CGSize(width: 1180, height: 860),
            isWide: true,
            listWidth: 400,
            reduceMotion: false,
            isRetro: false,
            origin: nil
        )
        try await Task.sleep(for: .milliseconds(20))
        state.dismiss(reduceMotion: false)

        // The first dismissal's 300 ms deadline has passed, but the newer
        // dismissal still has about 100 ms left to settle.
        try await Task.sleep(for: .milliseconds(220))

        XCTAssertEqual(state.phase, .dismissing)
        XCTAssertEqual(state.displayedRequest?.id, replacement.id)
        try await Task.sleep(for: .milliseconds(340))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.displayedRequest)
    }

    func testOpenThenCloseBeforeFirstYieldDoesNotRevealReader() async throws {
        let state = DashboardReaderPresentationState()
        state.present(
            request: makeRequest(title: "Synthetic article"),
            size: CGSize(width: 960, height: 720),
            isWide: false,
            listWidth: 400,
            reduceMotion: false,
            isRetro: false,
            origin: nil
        )
        state.dismiss(reduceMotion: false)

        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(state.phase, .dismissing)
        XCTAssertFalse(state.readerVisible)
        try await Task.sleep(for: .milliseconds(340))
    }

    func testOldHeroCompletionDoesNotClearReplacement() async throws {
        let state = DashboardReaderPresentationState()
        let origin = makeOrigin(title: "Synthetic hero")
        state.present(
            request: makeRequest(title: "First synthetic article"),
            size: CGSize(width: 1180, height: 860),
            isWide: true,
            listWidth: 400,
            reduceMotion: false,
            isRetro: false,
            origin: origin
        )
        let oldHeroID = try XCTUnwrap(state.hero?.id)

        state.dismiss(reduceMotion: false)
        state.present(
            request: makeRequest(title: "Replacement synthetic article"),
            size: CGSize(width: 1180, height: 860),
            isWide: true,
            listWidth: 400,
            reduceMotion: false,
            isRetro: false,
            origin: origin
        )
        let replacementHeroID = try XCTUnwrap(state.hero?.id)

        XCTAssertNotEqual(oldHeroID, replacementHeroID)
        state.finishHero(id: oldHeroID)
        XCTAssertEqual(state.hero?.id, replacementHeroID)

        state.dismiss(reduceMotion: false)
        try await Task.sleep(for: .milliseconds(340))
    }

    func testAccessibilityVisibilityMatchesPresentedPanes() {
        let idle = DashboardReaderPresentationContext(
            phase: .idle,
            isWide: false,
            isReaderCompact: false,
            listObscured: false,
            readerVisible: false
        )
        XCTAssertFalse(idle.browseAccessibilityHidden)
        XCTAssertTrue(idle.readerAccessibilityHidden)

        let compact = DashboardReaderPresentationContext(
            phase: .presented,
            isWide: false,
            isReaderCompact: true,
            listObscured: true,
            readerVisible: true
        )
        XCTAssertTrue(compact.browseAccessibilityHidden)
        XCTAssertFalse(compact.readerAccessibilityHidden)

        let compactDismissal = DashboardReaderPresentationContext(
            phase: .dismissing,
            isWide: false,
            isReaderCompact: true,
            listObscured: true,
            readerVisible: false
        )
        XCTAssertTrue(compactDismissal.browseAccessibilityHidden)
        XCTAssertTrue(compactDismissal.readerAccessibilityHidden)

        let split = DashboardReaderPresentationContext(
            phase: .presented,
            isWide: true,
            isReaderCompact: true,
            listObscured: false,
            readerVisible: true
        )
        XCTAssertFalse(split.browseAccessibilityHidden)
        XCTAssertFalse(split.readerAccessibilityHidden)
    }

    func testReduceMotionSkipsHeroTravel() async throws {
        let state = DashboardReaderPresentationState()
        state.present(
            request: makeRequest(title: "Synthetic article"),
            size: CGSize(width: 1180, height: 860),
            isWide: true,
            listWidth: 400,
            reduceMotion: true,
            isRetro: false,
            origin: makeOrigin(title: "Synthetic hero")
        )

        XCTAssertNil(state.hero)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(state.readerVisible)
        state.dismiss(reduceMotion: true)
        try await Task.sleep(for: .milliseconds(220))
    }

    func testReaderGeometryAtCompactAndSplitWidths() async throws {
        let cases: [(windowSize: CGSize, readerSize: CGSize)] = [
            (CGSize(width: 960, height: 720), CGSize(width: 960, height: 720)),
            (CGSize(width: 1100, height: 720), CGSize(width: 691, height: 720)),
            (CGSize(width: 1180, height: 860), CGSize(width: 771, height: 860)),
        ]

        for (index, testCase) in cases.enumerated() {
            let model = PresentationHarnessModel(selection: makeRequest(title: "Geometry \(index)"))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: testCase.windowSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let host = NSHostingView(rootView: PresentationHarnessView(model: model))
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: testCase.windowSize)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(420))
            host.layoutSubtreeIfNeeded()

            XCTAssertEqual(model.browseSize.width, 400, accuracy: 1)
            XCTAssertEqual(model.readerSize.width, testCase.readerSize.width, accuracy: 1)
            XCTAssertEqual(model.readerSize.height, testCase.readerSize.height, accuracy: 1)
            window.contentView = nil
        }
    }

    func testPresentedReaderTracksWindowResize() async throws {
        let model = PresentationHarnessModel(selection: makeRequest(title: "Resize fixture"))
        let initialSize = CGSize(width: 960, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: PresentationHarnessView(model: model))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: initialSize)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(model.readerSize.width, 960, accuracy: 1)

        let resized = CGSize(width: 1180, height: 860)
        host.frame = NSRect(origin: .zero, size: resized)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(model.readerSize.width, 771, accuracy: 1)
        XCTAssertEqual(model.readerSize.height, 860, accuracy: 1)
        window.contentView = nil
    }

    func testCompactBrowseWidthRestorationUsesAnimationTransaction() async throws {
        let model = PresentationHarnessModel(selection: makeRequest(title: "Dismissal layout fixture"))
        let size = CGSize(width: 960, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: PresentationHarnessView(model: model))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let openDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !model.presentationState.readerVisible, ContinuousClock.now < openDeadline {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(model.presentationState.readerVisible)
        XCTAssertEqual(model.browseSize.width, 400, accuracy: 1)

        model.selection = nil
        let dismissalDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.presentationState.phase != .idle, ContinuousClock.now < dismissalDeadline {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(model.presentationState.phase, .idle)
        XCTAssertEqual(model.lastDismissalTransactionHasAnimation, true)

        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.browseSize.width, size.width, accuracy: 1)
        window.contentView = nil
    }

    func testReaderShellWritesInspectableSwiftUISnapshots() async throws {
        let variants: [(
            name: String,
            size: CGSize,
            isRetro: Bool,
            colorScheme: ColorScheme,
            isEnglish: Bool,
            reduceMotion: Bool,
            origin: ReaderTransitionOrigin?
        )] = [
            ("shell-compact-960-modern-light-zh", CGSize(width: 960, height: 720), false, .light, false, false, nil),
            ("shell-split-1100-modern-dark-en", CGSize(width: 1100, height: 720), false, .dark, true, false, makeOrigin(title: "Synthetic hero title")),
            ("shell-wide-1180-retro-light-zh", CGSize(width: 1180, height: 860), true, .light, false, false, nil),
            ("shell-reduce-motion-1180-modern-light-en", CGSize(width: 1180, height: 860), false, .light, true, true, makeOrigin(title: "Must not travel")),
        ]

        for variant in variants {
            let title = variant.isEnglish ? "A synthetic article fixture" : "合成阅读器测试文章标题"
            let model = PresentationHarnessModel(selection: makeRequest(title: title))
            let root = PresentationHarnessView(
                model: model,
                isRetro: variant.isRetro,
                colorScheme: variant.colorScheme,
                isEnglish: variant.isEnglish,
                reduceMotion: variant.reduceMotion,
                transitionOrigin: variant.origin
            )
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: variant.size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let host = NSHostingView(rootView: root)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: variant.size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            let opening = try snapshot(host: host, size: variant.size)
            try await Task.sleep(for: .milliseconds(420))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(model.presentationState.phase, .presented)
            XCTAssertTrue(model.presentationState.readerVisible)
            if variant.reduceMotion {
                XCTAssertNil(model.presentationState.hero)
            }
            let settled = try snapshot(host: host, size: variant.size)

            model.selection = nil
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(model.presentationState.phase, .dismissing)
            let dismissing = try snapshot(host: host, size: variant.size)

            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(model.presentationState.phase, .idle)
            let idle = try snapshot(host: host, size: variant.size)

            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/dashboard-reader-ui-validation")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try opening.write(to: output.appendingPathComponent("\(variant.name)-opening.png"))
            try settled.write(to: output.appendingPathComponent("\(variant.name)-settled.png"))
            try dismissing.write(to: output.appendingPathComponent("\(variant.name)-dismissing.png"))
            try idle.write(to: output.appendingPathComponent("\(variant.name)-idle.png"))
            XCTAssertGreaterThan(settled.count, 2_000, "Unexpectedly empty render: \(variant.name)")
            window.contentView = nil
        }
    }

    func testReaderHeroIsExcludedFromAccessibilityTree() throws {
        let state = ReaderHeroState(
            origin: CGRect(x: 20, y: 40, width: 220, height: 130),
            target: CGRect(x: 400, y: 20, width: 480, height: 640),
            title: "Decorative hero fixture title",
            host: "example.invalid",
            isRetro: false
        )
        let size = CGSize(width: 900, height: 700)
        let view = ReaderHeroOverlay(state: state, onFinished: {})
            .frame(width: size.width, height: size.height, alignment: .topLeading)
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

        let labels = accessibilityLabels(in: host)
        guard !labels.isEmpty else {
            window.contentView = nil
            throw XCTSkip("NSHostingView did not expose an accessibility tree while off-screen")
        }

        XCTAssertFalse(
            labels.contains { $0.contains("Decorative hero fixture title") },
            "The decorative reader hero should not be announced by VoiceOver"
        )
        window.contentView = nil
    }

    func testReaderHeroCardRendersAtOriginAndDestinationSizes() throws {
        let variants: [(String, Bool, ColorScheme, CGSize)] = [
            ("hero-origin-modern-light", false, .light, CGSize(width: 220, height: 130)),
            ("hero-destination-modern-dark", false, .dark, CGSize(width: 640, height: 700)),
            ("hero-destination-retro-light", true, .light, CGSize(width: 640, height: 700)),
        ]

        for (name, isRetro, colorScheme, size) in variants {
            let view = ZStack {
                Color(nsColor: .windowBackgroundColor)
                ReaderHeroCard(
                    title: "A synthetic article title for the reader transition",
                    host: "example.invalid",
                    isRetro: isRetro,
                    cornerRadius: 14
                )
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .preferredColorScheme(colorScheme)

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
            XCTAssertGreaterThan(data.count, 2_000, "Unexpectedly empty render: \(name)")

            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/dashboard-reader-ui-validation")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("\(name).png"))
            window.contentView = nil
        }
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

    private func makeRequest(title: String) -> NewsReaderRequest {
        NewsReaderRequest(
            url: "https://example.invalid/article",
            title: title,
            item: nil,
            surface: "visual-test",
            contextID: nil,
            consentEpoch: UUID(),
            privateSession: true
        )
    }

    private func makeOrigin(title: String) -> ReaderTransitionOrigin {
        ReaderTransitionOrigin(frame: CGRect(x: 20, y: 40, width: 220, height: 130), title: title)
    }

    private func snapshot(host: NSHostingView<some View>, size: CGSize) throws -> Data {
        let bounds = NSRect(origin: .zero, size: size)
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor
@Observable
private final class PresentationHarnessModel {
    var selection: NewsReaderRequest?
    var listWidth: CGFloat = 400
    var browseSize: CGSize = .zero
    var readerSize: CGSize = .zero
    var lastContext: DashboardReaderPresentationContext?
    var lastReaderVisible = false
    var lastDismissalTransactionHasAnimation: Bool?
    let presentationState = DashboardReaderPresentationState()

    init(selection: NewsReaderRequest? = nil) {
        self.selection = selection
    }
}

@MainActor
private struct ReaderAnimationTransactionProbe: NSViewRepresentable {
    let phase: ReaderPresentationPhase
    let onPhaseChange: (ReaderPresentationPhase, ReaderPresentationPhase, Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let oldPhase = context.coordinator.previousPhase,
           oldPhase == .dismissing,
           phase == .idle {
            onPhaseChange(oldPhase, phase, context.transaction.animation != nil)
        }
        context.coordinator.previousPhase = phase
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var previousPhase: ReaderPresentationPhase?
    }
}

@MainActor
private struct PresentationHarnessView: View {
    @Bindable var model: PresentationHarnessModel
    var isRetro = false
    var colorScheme: ColorScheme = .light
    var isEnglish = false
    var reduceMotion = false
    var transitionOrigin: ReaderTransitionOrigin?

    private var surfaceColor: Color {
        if isRetro { return Color(red: 0.94, green: 0.88, blue: 0.75) }
        if colorScheme == .dark { return Color(red: 0.12, green: 0.12, blue: 0.13) }
        return Color.white
    }

    var body: some View {
        ZStack {
            surfaceColor.ignoresSafeArea()
            DashboardReaderPresentation(
                selection: $model.selection,
                listWidth: $model.listWidth,
                isRetro: isRetro,
                reduceMotion: reduceMotion,
                transitionOriginProvider: { transitionOrigin },
                presentationState: model.presentationState
            ) { context in
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        context.isReaderCompact ? Color.blue : Color.gray
                        VStack(alignment: .leading) {
                            Text(verbatim: isEnglish ? "Synthetic browse pane" : "合成浏览列表")
                            Text(verbatim: "phase: \(String(describing: context.phase))")
                            Text(verbatim: "compact: \(context.isReaderCompact)")
                        }
                        .padding(12)
                    }
                    .onAppear {
                        model.browseSize = proxy.size
                        model.lastContext = context
                    }
                    .onChange(of: proxy.size) { _, size in model.browseSize = size }
                    .onChange(of: context) { _, value in model.lastContext = value }
                    .overlay {
                        ReaderAnimationTransactionProbe(phase: context.phase) { oldPhase, newPhase, hasAnimation in
                            if oldPhase == .dismissing, newPhase == .idle {
                                model.lastDismissalTransactionHasAnimation = hasAnimation
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
            } readerContent: { request, visible in
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        Color.orange
                        VStack(alignment: .leading) {
                            Text(verbatim: isEnglish ? "Synthetic reader" : "合成阅读器")
                            Text(request.title)
                            Text(verbatim: "visible: \(visible)")
                        }
                        .padding(16)
                    }
                    .onAppear {
                        model.readerSize = proxy.size
                        model.lastReaderVisible = visible
                    }
                    .onChange(of: proxy.size) { _, size in model.readerSize = size }
                    .onChange(of: visible) { _, value in model.lastReaderVisible = value }
                }
            }
        }
        .preferredColorScheme(colorScheme)
    }
}
