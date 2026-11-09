import SwiftUI

/// A width-aware waterfall of following posts. Used by the standalone
/// following page and by the recommendation page's "关注动态" block, so both
/// surfaces get the same card and column behavior.
struct FollowingMasonryFeed: View {
    let entries: [FollowingPostEntry]
    let width: CGFloat
    var initialVisibleCount: Int = 24
    var showsLoadMore = true
    let onOpen: (WeiboPost) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var visibleCount: Int

    init(
        entries: [FollowingPostEntry],
        width: CGFloat,
        initialVisibleCount: Int = 24,
        showsLoadMore: Bool = true,
        onOpen: @escaping (WeiboPost) -> Void
    ) {
        self.entries = entries
        self.width = width
        self.initialVisibleCount = initialVisibleCount
        self.showsLoadMore = showsLoadMore
        self.onOpen = onOpen
        _visibleCount = State(initialValue: initialVisibleCount)
    }

    private var visibleEntries: [FollowingPostEntry] {
        Array(entries.prefix(visibleCount))
    }

    private var columnCount: Int {
        voiceOverEnabled ? 1 : FollowingMasonryLayout.columnCount(for: max(1, width))
    }

    private var columnWidth: CGFloat {
        FollowingMasonryLayout.columnWidth(for: max(1, width), columns: columnCount)
    }

    private var columns: [[Int]] {
        FollowingMasonryLayout.columns(
            for: visibleEntries,
            columnCount: columnCount,
            columnWidth: columnWidth
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: WaterfallLayout.columnSpacing) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, indexes in
                    LazyVStack(spacing: WaterfallLayout.cardSpacing) {
                        ForEach(indexes.map { visibleEntries[$0] }) { entry in
                            FollowingPostCard(
                                entry: entry,
                                columnWidth: columnWidth,
                                onOpen: { onOpen(entry.post) }
                            )
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: columnWidth, alignment: .topLeading)
                }
            }

            if showsLoadMore, entries.count > visibleCount {
                Button {
                    visibleCount += initialVisibleCount
                } label: {
                    Text(L10n.string("weibo.feed.loadMore", language: settings.appLanguage))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: entries.map(\.id)) { _, _ in
            visibleCount = max(initialVisibleCount, min(visibleCount, entries.count))
        }
    }
}
