import SwiftUI

struct ReaderHeroState: Identifiable {
    let id = UUID()
    let origin: CGRect
    let target: CGRect
    let title: String
    let host: String
    let isRetro: Bool
}

/// Owns the morph animation so the Dashboard root does not re-evaluate on every
/// frame. The card is a cheap stand-in, not the WKWebView.
struct ReaderHeroOverlay: View {
    let state: ReaderHeroState
    let onFinished: () -> Void

    @State private var frame: CGRect
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: ReaderHeroState, onFinished: @escaping () -> Void) {
        self.state = state
        self.onFinished = onFinished
        _frame = State(initialValue: state.origin)
    }

    var body: some View {
        ReaderHeroCard(
            title: state.title,
            host: state.host,
            isRetro: state.isRetro,
            cornerRadius: 14
        )
        .frame(width: max(1, frame.width), height: max(1, frame.height))
        .offset(x: frame.minX, y: frame.minY)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .task {
            guard !reduceMotion else {
                onFinished()
                return
            }
            // Let the origin frame render before starting the spring; otherwise
            // SwiftUI can coalesce both writes into the target frame.
            await Task.yield()
            withAnimation(DashboardMotion.structural) {
                frame = state.target
            }
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            withAnimation(DashboardMotion.reveal) {
                visible = false
            }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }
}
