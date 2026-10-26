import SwiftUI

/// A dashboard row that records its own frame before opening the reader, so the
/// reader can animate out of the exact card the user tapped.
struct HeroOpenButton<Label: View>: View {
    let item: NewsItem
    let surface: String
    var contextID: String? = nil

    @State private var frame: CGRect = .zero
    @State private var isHovering = false
    private let label: Label

    init(
        item: NewsItem,
        surface: String,
        contextID: String? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.item = item
        self.surface = surface
        self.contextID = contextID
        self.label = label()
    }

    var body: some View {
        Button {
            if isHovering, frame.width > 1, frame.height > 1 {
                ReaderTransitionCoordinator.shared.captureSnapshot()
                ReaderTransitionCoordinator.shared.register(frame: frame, title: item.displayTitle)
            }
            NewsNavigationRouter.shared.open(item, surface: surface, contextID: contextID)
        } label: {
            label
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background {
            // Measure only the hovered row. Measuring every row on every
            // layout/scroll pass makes the list write state continuously.
            if isHovering {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("dashboardRoot"))
                    } action: { newFrame in
                        frame = newFrame
                    }
            }
        }
    }
}
