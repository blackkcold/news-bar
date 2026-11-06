import SwiftUI

/// A dashboard row that records its own frame before opening the reader, so the
/// reader can animate out of the exact card the user tapped.
struct HeroOpenButton<Label: View>: View {
    /// Reference storage for the hovered card's frame. Writing this must not
    /// invalidate the view: while the pointer rests on a card, scrolling moves
    /// that card every frame, and a `@State` write here re-evaluated the card
    /// (and its reader chrome) on every scroll pass.
    private final class MeasuredFrame {
        var value: CGRect = .zero
    }

    let item: NewsItem
    let surface: String
    var contextID: String? = nil
    // Batch provenance carried into the reader; presentation is unchanged.
    var policyVersion: String? = nil
    var profileVersion: Int? = nil
    var position: Int? = nil

    @State private var measuredFrame = MeasuredFrame()
    @State private var isHovering = false
    private let label: Label

    init(
        item: NewsItem,
        surface: String,
        contextID: String? = nil,
        policyVersion: String? = nil,
        profileVersion: Int? = nil,
        position: Int? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.item = item
        self.surface = surface
        self.contextID = contextID
        self.policyVersion = policyVersion
        self.profileVersion = profileVersion
        self.position = position
        self.label = label()
    }

    var body: some View {
        Button {
            let frame = measuredFrame.value
            if isHovering, frame.width > 1, frame.height > 1 {
                ReaderTransitionCoordinator.shared.register(frame: frame, title: item.displayTitle)
            }
            NewsNavigationRouter.shared.open(
                item,
                surface: surface,
                contextID: contextID,
                policyVersion: policyVersion,
                profileVersion: profileVersion,
                position: position
            )
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
                        measuredFrame.value = newFrame
                    }
            }
        }
    }
}
