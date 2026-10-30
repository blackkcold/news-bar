import SwiftUI

/// Placeholder shown between "reading" and the first streamed token. Static by
/// design: it must not compete with the answer that replaces it, and it must
/// respect Reduce Motion without any extra branch.
struct AnswerSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            bar(width: 0.72, height: 13)
            bar(width: 0.96, height: 9)
            bar(width: 0.88, height: 9)
            bar(width: 0.54, height: 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(reduceMotion ? 0.7 : (pulse ? 0.55 : 0.9))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityLabel(Text(L10n.string("reader.search.stage.answer", language: L10n.currentLanguage)))
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(.quaternary)
                .frame(width: proxy.size.width * width, height: height)
        }
        .frame(height: height)
    }
}
