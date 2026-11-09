import SwiftUI

/// One hot-search card for both built-in sources. The two old cards used a
/// full card each; the sidebar now spends one card and a compact source switch
/// on the same information, leaving room for following messages.
struct DashboardIntegratedHotTrendCard: View {
    let weiboItems: [NewsItem]
    let bilibiliItems: [NewsItem]

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var source: NewsSource
    @State private var isExpanded = false

    init(
        weiboItems: [NewsItem],
        bilibiliItems: [NewsItem],
        initialSource: NewsSource = .weibo
    ) {
        self.weiboItems = weiboItems
        self.bilibiliItems = bilibiliItems
        _source = State(initialValue: initialSource == .bilibili ? .bilibili : .weibo)
    }

    private var language: AppLanguage { settings.appLanguage }
    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var isWeibo: Bool { source == .weibo }
    private var items: [NewsItem] { isWeibo ? weiboItems : bilibiliItems }
    private var presentation: DashboardTrendPresentation {
        DashboardTrendPresentation(for: source)
    }
    private var visibleItems: [NewsItem] {
        isExpanded ? items : Array(items.prefix(5))
    }
    private var hiddenCount: Int {
        max(0, items.count - visibleItems.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            sourcePicker

            if items.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        DashboardTrendRow(
                            item: item,
                            sourceLabel: presentation.title,
                            sourceMark: presentation.mark,
                            accent: presentation.accent,
                            rankFallback: index + 1,
                            reduceMotion: reduceMotion
                        )

                        if index < visibleItems.count - 1 {
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }

                if hiddenCount > 0 {
                    footerButton
                }
            }
        }
        .padding(14)
        .newsCardSurface(rotation: isWeibo ? -0.12 : 0.12)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            EditorialSourceBadge(
                mark: presentation.mark,
                fallbackTint: presentation.accent,
                size: 30,
                rotation: isWeibo ? -2 : 2
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L10n.string("dash.hot.title", language: language))
                        .editorialHeading(size: 14)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    EditorialTag(
                        text: L10n.string("news.count", language: language, items.count),
                        fallbackTint: presentation.accent
                    )
                }

                Text(L10n.string("dash.hot.subtitle", language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.bottom, 8)
    }

    private var sourcePicker: some View {
        HStack(spacing: 2) {
            sourceButton(.weibo, count: weiboItems.count)
            sourceButton(.bilibili, count: bilibiliItems.count)
        }
        .padding(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isRetro {
                Rectangle().fill(RetroEditorialTokens.raisedPaper)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .overlay {
            if isRetro {
                Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 1)
            }
        }
        .padding(.bottom, 7)
        .accessibilityElement(children: .contain)
    }

    private func sourceButton(_ candidate: NewsSource, count: Int) -> some View {
        let selected = source == candidate
        let accent = DashboardTrendPresentation(for: candidate).accent

        return Button {
            guard source != candidate else { return }
            source = candidate
            isExpanded = false
        } label: {
            HStack(spacing: 4) {
                Text(L10n.string(
                    candidate == .weibo
                        ? "dash.hot.source.weibo"
                        : "dash.hot.source.bilibili",
                    language: language
                ))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                Text("\(count)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(selected ? accent : .secondary)
                    .monospacedDigit()
            }
            .font(.system(
                size: 10,
                weight: selected ? .semibold : .medium,
                design: isRetro ? .serif : .default
            ))
            .foregroundStyle(selected ? accent : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(accent.opacity(0.15))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(
            L10n.string(
                candidate == .weibo
                    ? "dash.hot.source.weibo"
                    : "dash.hot.source.bilibili",
                language: language
            )
        )
        .accessibilityValue(L10n.string("news.count", language: language, count))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footerButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                Text(isExpanded
                    ? L10n.string("news.collapse", language: language)
                    : L10n.string("dash.expandAll", language: language))
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(EditorialActionButtonStyle(compact: true))
        .controlSize(.small)
        .tint(presentation.accent)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(L10n.string("dash.noTrendData", language: language))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}
