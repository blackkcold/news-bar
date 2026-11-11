import SwiftUI

/// A width-aware waterfall of following posts. Used by the standalone
/// following page; every column is a hard width so a long body or a wide
/// table image can never paint into the neighbouring column.
struct FollowingMasonryFeed: View {
    let entries: [FollowingPostEntry]
    let width: CGFloat
    var initialVisibleCount: Int = 24
    var showsLoadMore = true
    /// Test seam for a wide image without hitting the network. Production
    /// callers leave this empty and the card uses AsyncImage.
    var imageOverrides: [String: Image] = [:]
    let onOpen: (WeiboPost) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var visibleCount: Int
    /// One automatic page per approach to the end; reset when the "load more"
    /// control leaves the viewport.
    @State private var prefetch = MasonryPrefetchLatch()

    private func loadNextPage() {
        guard entries.count > visibleCount else { return }
        visibleCount = min(entries.count, visibleCount + initialVisibleCount)
    }

    init(
        entries: [FollowingPostEntry],
        width: CGFloat,
        initialVisibleCount: Int = 24,
        showsLoadMore: Bool = true,
        imageOverrides: [String: Image] = [:],
        onOpen: @escaping (WeiboPost) -> Void
    ) {
        self.entries = entries
        self.width = width
        self.initialVisibleCount = initialVisibleCount
        self.showsLoadMore = showsLoadMore
        self.imageOverrides = imageOverrides
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

    var body: some View {
        // Resolve the page slice and the column plan once per render. Both were
        // computed properties read from inside the `ForEach`, so the slice was
        // rebuilt and the height estimates re-run once per column.
        let visible = visibleEntries
        let columns = FollowingMasonryLayout.columns(
            for: visible,
            columnCount: columnCount,
            columnWidth: columnWidth
        )

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: WaterfallLayout.columnSpacing) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, indexes in
                    LazyVStack(spacing: WaterfallLayout.cardSpacing) {
                        ForEach(indexes.map { visible[$0] }) { entry in
                            FollowingPostCard(
                                entry: entry,
                                columnWidth: columnWidth,
                                imageOverride: imageOverrides[entry.id],
                                onOpen: { onOpen(entry.post) }
                            )
                            .frame(width: columnWidth, alignment: .top)
                        }
                    }
                    .frame(width: columnWidth, alignment: .topLeading)
                }
            }

            if showsLoadMore, entries.count > visibleCount {
                Button {
                    loadNextPage()
                } label: {
                    Text(L10n.string("weibo.feed.loadMore", language: settings.appLanguage))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
                // Prefetch the next page once when the end of the feed comes
                // into view; the latch re-arms when the control leaves the
                // viewport. The button stays as the keyboard/VoiceOver path.
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    guard prefetch.visibilityChanged(visible) else { return }
                    loadNextPage()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only the number of entries feeds the clamp; comparing every id built
        // an id array on each render for no extra safety.
        .onChange(of: entries.count) { _, _ in
            visibleCount = max(initialVisibleCount, min(visibleCount, entries.count))
        }
    }
}
