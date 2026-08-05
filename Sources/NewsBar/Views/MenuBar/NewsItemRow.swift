import SwiftUI

struct NewsItemRow: View, Equatable {
    let item: NewsItem
    let showRank: Bool
    var presentation: NewsSectionPresentation = .standard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var settings
    @State private var isHovering = false

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    static func == (lhs: NewsItemRow, rhs: NewsItemRow) -> Bool {
        lhs.item == rhs.item
            && lhs.showRank == rhs.showRank
            && lhs.presentation == rhs.presentation
    }

    private var isCompactPresentation: Bool {
        presentation.isCompactTrend
    }

    private var rowHorizontalPadding: CGFloat { isCompactPresentation ? 8 : 10 }
    private var rowVerticalPadding: CGFloat { isCompactPresentation ? 6 : 8 }
    private var rowSpacing: CGFloat { isCompactPresentation ? 6 : 8 }
    private var titleFontSize: CGFloat { isCompactPresentation ? 12 : 13 }
    private var titleLineLimit: Int { isCompactPresentation ? 3 : 2 }
    private var titleSpacing: CGFloat { isCompactPresentation ? 2 : 4 }
    private var rankBadgeSize: CGFloat { isCompactPresentation ? 18 : 20 }
    private var rankBadgeFontSize: CGFloat { isCompactPresentation ? 9.5 : 10.5 }
    private var arrowIconSize: CGFloat { isCompactPresentation ? 7.5 : 8 }
    private var sourceMetadataSpacing: CGFloat { 4 }

    var body: some View {
        Button {
            URLOpener.open(item.url)
        } label: {
            HStack(alignment: .top, spacing: rowSpacing) {
                if showRank, let rank = item.rank {
                    rankBadge(rank)
                }

                VStack(alignment: .leading, spacing: titleSpacing) {
                    Text(item.displayTitle)
                        .font(.system(size: titleFontSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(titleLineLimit)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isCompactPresentation {
                        HStack(spacing: sourceMetadataSpacing) {
                            sourcePill

                            if let host = URL(string: item.url)?.host, !host.isEmpty {
                                Text(host)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: arrowIconSize, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0.55)
            }
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, rowVerticalPadding)
            .background(rowBackground)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("news.openInBrowser".localized)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
        }
    }

    private var accessibilityLabel: String {
        if let rank = item.rank, showRank {
            return L10n.string("news.rank", rank, item.displayTitle, item.source.displayName)
        }
        return "\(item.displayTitle)，\(item.source.displayName)"
    }

    private func rankBadge(_ rank: Int) -> some View {
        Text("\(rank)")
            .font(.system(size: rankBadgeFontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(rank <= 3 ? .white : accent)
            .frame(width: rankBadgeSize, height: rankBadgeSize)
            .background(rank <= 3 ? rankColor(rank) : accent.opacity(0.12))
            .editorialClipShape(cornerRadius: rankBadgeSize / 2)
            .accessibilityLabel(L10n.string("news.rankBadge", rank))
    }

    private var sourcePill: some View {
        HStack(spacing: 4) {
            EditorialSourceBadge(
                mark: sourceMark,
                fallbackTint: accent,
                size: 17
            )
            Text(item.source.displayName)
                .font(.system(size: 10, weight: isRetro ? .black : .medium, design: isRetro ? .serif : .default))
                .lineLimit(1)
        }
            .foregroundStyle(accent)
            .padding(.horizontal, isRetro ? 4 : 6)
            .padding(.vertical, isRetro ? 3 : 2)
            .background(accent.opacity(0.12))
            .editorialClipShape(cornerRadius: 20)
            .accessibilityHidden(true)
    }

    private var rowShape: AnyShape {
        isRetro
            ? AnyShape(Rectangle())
            : AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var rowBackground: some View {
        rowShape
            .fill(isHovering ? accent.opacity(0.06) : Color.clear)
            .overlay {
                rowShape.stroke(rowStrokeStyle, lineWidth: 1)
            }
    }

    private var rowStrokeStyle: AnyShapeStyle {
        isHovering ? AnyShapeStyle(accent.opacity(0.16)) : AnyShapeStyle(.separator.opacity(0.08))
    }

    private var accent: Color {
        switch item.source {
        case .weibo:
            return .orange
        case .bilibili:
            return .pink
        case let .rss(name, _):
            return paletteTint(for: name)
        }
    }

    private var sourceMark: EditorialSourceMark {
        switch item.source {
        case .weibo: return .weibo
        case .bilibili: return .bilibili
        case .rss: return .rss
        }
    }

    private func paletteTint(for key: String) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .green, .orange, .pink, .indigo, .cyan]
        let seed = key.unicodeScalars.reduce(0) { partial, scalar in
            partial &* 31 &+ Int(scalar.value)
        }
        let index = (seed & 0x7fffffff) % colors.count
        return colors[index]
    }

    private func rankColor(_ rank: Int) -> Color {
        if isRetro {
            return rank <= 3 ? RetroEditorialTokens.brick : RetroEditorialTokens.ink
        }
        switch rank {
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        default: return .secondary.opacity(0.3)
        }
    }
}
