import SwiftUI

struct NewsItemRow: View {
    let item: NewsItem
    let showRank: Bool

    @State private var isHovering = false

    var body: some View {
        Button {
            URLOpener.open(item.url)
        } label: {
            HStack(spacing: 8) {
                if showRank, let rank = item.rank {
                    rankBadge(rank)
                }

                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private func rankBadge(_ rank: Int) -> some View {
        Text("\(rank)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(rank <= 3 ? .white : .secondary)
            .frame(width: 18, height: 18)
            .background(rank <= 3 ? rankColor(rank) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        default: return .secondary.opacity(0.3)
        }
    }
}
