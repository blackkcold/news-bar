import AppKit
import Observation
import SwiftUI

struct DashboardReaderPresentationContext: Equatable {
    let phase: ReaderPresentationPhase
    let isWide: Bool
    let isReaderCompact: Bool
    let listObscured: Bool
    let readerVisible: Bool

    var browseAccessibilityHidden: Bool { phase != .idle && !isWide }
    var readerAccessibilityHidden: Bool { !readerVisible }
}

@MainActor
@Observable
final class DashboardReaderPresentationState {
    private(set) var phase: ReaderPresentationPhase = .idle
    private(set) var displayedRequest: NewsReaderRequest?
    private(set) var readerVisible = false
    private(set) var hero: ReaderHeroState?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openingTask: Task<Void, Never>?
    @ObservationIgnored private var dismissalTask: Task<Void, Never>?

    func present(
        request: NewsReaderRequest,
        size: CGSize,
        isWide: Bool,
        listWidth: CGFloat,
        reduceMotion: Bool,
        isRetro: Bool,
        origin: ReaderTransitionOrigin?
    ) {
        generation += 1
        let currentGeneration = generation
        openingTask?.cancel()
        dismissalTask?.cancel()
        openingTask = nil
        dismissalTask = nil

        // An already presented reader swaps documents without replaying the open
        // transition; retain the current visible frame and list geometry.
        if phase == .presented, displayedRequest != nil {
            displayedRequest = request
            hero = nil
            if !readerVisible {
                revealReader(requestID: request.id, generation: currentGeneration, reduceMotion: reduceMotion)
            }
            return
        }

        displayedRequest = request
        phase = .presented
        readerVisible = false

        if !reduceMotion, let origin, origin.frame.width > 2, origin.frame.height > 2 {
            hero = ReaderHeroState(
                origin: origin.frame,
                target: Self.readerFrame(for: size, isWide: isWide, listWidth: listWidth),
                title: origin.title.isEmpty ? request.title : origin.title,
                host: URL(string: request.url)?.host ?? "",
                isRetro: isRetro
            )
        } else {
            hero = nil
        }

        revealReader(requestID: request.id, generation: currentGeneration, reduceMotion: reduceMotion)
    }

    private func revealReader(requestID: UUID, generation: Int, reduceMotion: Bool) {
        openingTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.generation == generation,
                  self.displayedRequest?.id == requestID,
                  self.phase == .presented
            else { return }

            withAnimation(reduceMotion ? DashboardMotion.reduced : DashboardMotion.structural) {
                self.readerVisible = true
            }
            self.openingTask = nil
        }
    }

    func dismiss(reduceMotion: Bool) {
        guard phase == .presented else { return }
        generation += 1
        let currentGeneration = generation
        openingTask?.cancel()
        dismissalTask?.cancel()
        openingTask = nil
        dismissalTask = nil
        hero = nil
        phase = .dismissing
        withAnimation(reduceMotion ? DashboardMotion.reduced : DashboardMotion.reveal) {
            readerVisible = false
        }

        let settleDelay = reduceMotion ? 80 : 180
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(settleDelay + 120))
            guard let self,
                  !Task.isCancelled,
                  self.generation == currentGeneration,
                  self.phase == .dismissing
            else { return }
            withAnimation(reduceMotion ? DashboardMotion.reduced : DashboardMotion.structural) {
                self.displayedRequest = nil
                self.phase = .idle
            }
            self.dismissalTask = nil
        }
    }

    func finishHero(id: UUID) {
        guard hero?.id == id else { return }
        hero = nil
    }

    static func readerFrame(for size: CGSize, isWide: Bool, listWidth: CGFloat) -> CGRect {
        guard isWide else { return CGRect(origin: .zero, size: size) }
        let splitX = min(480, max(320, listWidth)) + 9
        return CGRect(x: splitX, y: 0, width: max(0, size.width - splitX), height: size.height)
    }
}

struct DashboardReaderPresentation<BrowseContent: View, ReaderContent: View>: View {
    @Binding private var selection: NewsReaderRequest?
    @Binding private var listWidth: CGFloat
    @State private var presentationState: DashboardReaderPresentationState

    private let isRetro: Bool
    private let reduceMotion: Bool
    private let transitionOriginProvider: () -> ReaderTransitionOrigin?
    private let browseContent: (DashboardReaderPresentationContext) -> BrowseContent
    private let readerContent: (NewsReaderRequest, Bool) -> ReaderContent

    @MainActor
    init(
        selection: Binding<NewsReaderRequest?>,
        listWidth: Binding<CGFloat>,
        isRetro: Bool,
        reduceMotion: Bool,
        transitionOriginProvider: @escaping () -> ReaderTransitionOrigin?,
        presentationState: DashboardReaderPresentationState? = nil,
        @ViewBuilder browseContent: @escaping (DashboardReaderPresentationContext) -> BrowseContent,
        @ViewBuilder readerContent: @escaping (NewsReaderRequest, Bool) -> ReaderContent
    ) {
        _selection = selection
        _listWidth = listWidth
        self.isRetro = isRetro
        self.reduceMotion = reduceMotion
        self.transitionOriginProvider = transitionOriginProvider
        _presentationState = State(initialValue: presentationState ?? DashboardReaderPresentationState())
        self.browseContent = browseContent
        self.readerContent = readerContent
    }

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width >= 1100
            let isReaderCompact = presentationState.phase == .presented || presentationState.phase == .dismissing
            let clampedListWidth = min(480, max(320, listWidth))
            let listWidthForPhase = isReaderCompact ? clampedListWidth : geometry.size.width
            let context = DashboardReaderPresentationContext(
                phase: presentationState.phase,
                isWide: isWide,
                isReaderCompact: isReaderCompact,
                listObscured: isReaderCompact && !isWide,
                readerVisible: presentationState.readerVisible
            )
            let readerFrame = DashboardReaderPresentationState.readerFrame(
                for: geometry.size,
                isWide: isWide,
                listWidth: clampedListWidth
            )

            ZStack(alignment: .topLeading) {
                browseContent(context)
                    .environment(\.dashboardListObscured, context.listObscured)
                    .frame(width: listWidthForPhase, height: geometry.size.height, alignment: .topLeading)
                    .allowsHitTesting(!(presentationState.phase == .presented && !isWide))
                    .accessibilityHidden(context.browseAccessibilityHidden)
                    .zIndex(0)

                if let request = presentationState.displayedRequest {
                    readerContent(request, presentationState.readerVisible)
                        .id(request.id)
                        .frame(width: readerFrame.width, height: readerFrame.height, alignment: .topLeading)
                        .offset(x: readerFrame.minX, y: readerFrame.minY)
                        .opacity(presentationState.readerVisible ? 1 : 0)
                        .allowsHitTesting(presentationState.readerVisible)
                        .accessibilityHidden(context.readerAccessibilityHidden)
                        .zIndex(2)
                }

                if isWide, presentationState.phase == .presented, presentationState.displayedRequest != nil {
                    DashboardSplitter(width: $listWidth)
                        .frame(width: 9, height: geometry.size.height)
                        .offset(x: clampedListWidth)
                        .zIndex(3)
                }

                if let hero = presentationState.hero {
                    ReaderHeroOverlay(state: hero) {
                        presentationState.finishHero(id: hero.id)
                    }
                    .id(hero.id)
                    .zIndex(20)
                }
            }
            .coordinateSpace(name: "dashboardRoot")
            .onAppear {
                if let request = selection, presentationState.displayedRequest == nil {
                    presentationState.present(
                        request: request,
                        size: geometry.size,
                        isWide: isWide,
                        listWidth: clampedListWidth,
                        reduceMotion: reduceMotion,
                        isRetro: isRetro,
                        origin: transitionOriginProvider()
                    )
                }
            }
            .onChange(of: selection?.id) { _, _ in
                if let request = selection {
                    presentationState.present(
                        request: request,
                        size: geometry.size,
                        isWide: isWide,
                        listWidth: clampedListWidth,
                        reduceMotion: reduceMotion,
                        isRetro: isRetro,
                        origin: transitionOriginProvider()
                    )
                } else if presentationState.displayedRequest != nil {
                    presentationState.dismiss(reduceMotion: reduceMotion)
                }
            }
        }
    }
}

private struct DashboardSplitter: View {
    @Binding var width: CGFloat
    @State private var dragStart: CGFloat?
    @State private var proposedWidth: CGFloat?

    private let minWidth: CGFloat = 320
    private let maxWidth: CGFloat = 480

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            if let proposedWidth {
                // Show the target position while dragging; commit the real
                // width once on release so the list does not reflow per frame.
                Rectangle()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .offset(x: proposedWidth - width)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear { NSCursor.arrow.set() }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil { dragStart = width }
                    let start = dragStart ?? width
                    proposedWidth = min(maxWidth, max(minWidth, start + value.translation.width))
                }
                .onEnded { _ in
                    if let proposedWidth {
                        width = proposedWidth
                    }
                    dragStart = nil
                    proposedWidth = nil
                }
        )
        .onTapGesture(count: 2) {
            dragStart = nil
            proposedWidth = nil
            width = 400
        }
        .accessibilityLabel("Resize news list")
    }
}
