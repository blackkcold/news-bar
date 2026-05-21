import SwiftUI

extension View {

    @ViewBuilder
    func glassBackground() -> some View {
        self.background(.ultraThinMaterial)
    }

    func materialCard() -> some View {
        self
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func glassButton() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6))
            .clipShape(Capsule())
    }
}
