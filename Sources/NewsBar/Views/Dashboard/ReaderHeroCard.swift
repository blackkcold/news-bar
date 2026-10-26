import SwiftUI

/// A lightweight stand-in that morphs from the tapped card to the reader panel.
/// It deliberately does not host the WKWebView: animating an NSViewRepresentable's
/// layer produces white/black frames.
struct ReaderHeroCard: View {
    let title: String
    let host: String
    let isRetro: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(isRetro ? RetroEditorialTokens.paper : Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NEWS BAR")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(isRetro ? RetroEditorialTokens.brick : Color.secondary)
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isRetro ? RetroEditorialTokens.ink : Color.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if !host.isEmpty {
                        Text(host)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(16)
                .frame(maxWidth: 360, alignment: .leading)
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    isRetro ? RetroEditorialTokens.ink.opacity(0.2) : Color.primary.opacity(0.1),
                    lineWidth: 1
                )
            )
    }
}
