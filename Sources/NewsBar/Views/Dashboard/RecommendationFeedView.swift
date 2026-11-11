import AppKit
import Combine
import SwiftUI

private enum ExposureClock {
    static let ticks = Timer.publish(every: 1, on: .main, in: .common).autoconnect().share()
}

/// Whether the compact reader is covering the list. Set by the dashboard from
/// its own transition phase; the feed never infers this from key-window state.
private struct DashboardListObscuredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dashboardListObscured: Bool {
        get { self[DashboardListObscuredKey.self] }
        set { self[DashboardListObscuredKey.self] = newValue }
    }
}

/// One timer and one set of window/session checks for the whole feed. Previously
/// every visible row performed these system calls on every tick. Visibility is
/// based on the feed's own window, not whichever window happens to be key.
@MainActor
private final class ExposureEnvironment {
    static let shared = ExposureEnvironment()

    private(set) var isActive = false
    private weak var window: NSWindow?
    private var timer: Timer?

    func attach(_ window: NSWindow?) {
        self.window = window
        refresh()
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window = nil
        isActive = false
    }

    private func refresh() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        // NSWindow can tell us its own visibility/occlusion, not exact
        // unobstructed screen pixels.
        isActive = NSApp.isActive
            && !locked
            && window?.isVisible == true
            && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
    }
}

private struct ExposureWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    final class ProbeView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindow = onWindow
    }
}

private struct QualifiedImpression: ViewModifier {
    let item: NewsItem
    let sessionID: UUID
    let epoch: UUID
    let contextID: String
    let position: Int
    let policyVersion: String
    let profileVersion: Int
    @Environment(\.dashboardListObscured) private var listObscured
    @State private var visible = false
    @State private var exposure = QualifiedExposure()

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: 0.5) { visible = $0 }
            // The one-shot latch belongs to a consent epoch. Turning learning
            // off and on again is a new epoch, so the same row may record a new
            // impression in the same list session instead of staying latched.
            .onChange(of: epoch) { _, _ in exposure = QualifiedExposure() }
            .onReceive(ExposureClock.ticks) { _ in
                // One gate for window/session/reader state, evaluated every tick
                // so an inactive interval resets continuity instead of pausing it.
                let active = ExposureEnvironment.shared.isActive
                    && !listObscured
                    && InterestController.shared.canLearn
                let fraction = (active && visible) ? 1.0 : 0.0
                if exposure.update(
                    visibleFraction: fraction,
                    active: active,
                    now: ProcessInfo.processInfo.systemUptime
                ) {
                    InterestController.shared.record(
                        item,
                        kind: .impression,
                        epoch: epoch,
                        sessionID: sessionID,
                        surface: "recommendation",
                        contextID: contextID,
                        position: position,
                        policyVersion: policyVersion,
                        profileVersion: profileVersion
                    )
                }
            }
    }
}

struct RecommendationCardFrame: Equatable, Sendable {
    let id: String
    let frame: CGRect
}

struct RecommendationCardFramePreferenceKey: PreferenceKey {
    static let defaultValue: [RecommendationCardFrame] = []

    static func reduce(
        value: inout [RecommendationCardFrame],
        nextValue: () -> [RecommendationCardFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

struct RecommendationFeedView: View {
    let matches: (NewsItem) -> Bool
    /// The width the dashboard is actually giving this feed. When the reader
    /// opens, the list pane is clamped to 320–480 pt; passing that width down
    /// makes the masonry choose one column in the same layout pass instead of
    /// waiting for a content-width measurement that can still be stale.
    let width: CGFloat
    /// Test seam: render a frozen batch without touching the local interest DB.
    var snapshotOverride: RecommendationSnapshot? = nil
    /// Test seam: report each card's frame in the masonry coordinate space.
    var onCardFrames: (([RecommendationCardFrame]) -> Void)? = nil
    var hasFilter = false
    var onOpenSettings: () -> Void = {}
    var onResetFilters: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onShowSources: () -> Void = {}
    /// A refresh is running elsewhere in the dashboard (the newsroom bar and
    /// this control drive the same orchestrator).
    var isRefreshing = false
    /// Newest successful fetch across the sources this feed ranks.
    var lastRefreshAt: Date? = nil
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var controller = InterestController.shared
    @State private var visibleCount = 20
    /// One automatic page per approach to the end of the feed.
    @State private var prefetch = MasonryPrefetchLatch()
    /// Width the masonry actually received. The dashboard hands us a width it
    /// computed from its own arithmetic; a scroll view scroller, safe-area
    /// inset or a mid-transition pane can make the real slot a few points
    /// narrower. Laying cards out for the wider hint pushes the last column
    /// past the feed and paints it over the neighbouring pane.
    @State private var measuredWidth: CGFloat = 0
    private var english: Bool { settings.appLanguage == .en }

    /// A feed-local refresh entry. The newsroom bar refreshes every source too,
    /// but on this page the control belongs next to the ranking it changes, and
    /// it can say how old the current batch is.
    private var refreshControl: some View {
        Button(action: onRefresh) {
            HStack(spacing: 5) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                if showsRefreshCaption {
                    Text(refreshCaption)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isRefreshing ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .help(isRefreshing
              ? (english ? "Refreshing sources…" : "正在刷新来源…")
              : (english ? "Refresh sources, then re-rank" : "刷新来源后重新排序"))
        .accessibilityLabel(english ? "Refresh recommendations" : "刷新推荐")
    }

    /// The caption needs a full line; the icon alone carries the action on the
    /// reader's 320–480 pt list pane.
    private var showsRefreshCaption: Bool { width >= 440 }

    private var refreshCaption: String {
        if isRefreshing {
            return english ? "Refreshing…" : "刷新中…"
        }
        guard let lastRefreshAt else {
            return english ? "Refresh" : "刷新"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: settings.appLanguage.bcp47)
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: lastRefreshAt, relativeTo: Date())
        return english ? "Updated \(relative)" : "更新于 \(relative)"
    }

    private var learningOptOutText: some View {
        Text(english
             ? "Public ranking is available without recording your reading behavior."
             : "未开启阅读行为记录，仍可使用公共推荐。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var personalizationButton: some View {
        Button(english ? "Set up personalization" : "设置个性化", action: onOpenSettings)
            .buttonStyle(.borderless)
            .font(.caption)
            .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(english ? "For you" : "为你推荐", systemImage: "sparkles").editorialHeading(size: 20)
                    .lineLimit(1)
                Spacer(minLength: 8)
                refreshControl
                if width >= 400 {
                    Text(controller.learningStatus.title(language: settings.appLanguage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !controller.learningEnabled {
                // At the reader's 320–480 pt list pane the sentence and the
                // button do not fit side by side; stack them instead of
                // clipping the button at the trailing edge.
                if width < 420 {
                    VStack(alignment: .leading, spacing: 4) {
                        learningOptOutText
                        personalizationButton
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        learningOptOutText
                        Spacer(minLength: 0)
                        personalizationButton
                    }
                }
            }
            if controller.learningPaused || controller.privateReading {
                Label(english ? "Learning paused for this activity" : "当前活动不参与学习", systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot = snapshotOverride ?? controller.recommendations {
                // One filter pass per render: the count, the page slice and the
                // masonry all read this array. Previously `filteredRows` walked
                // the whole snapshot once for the count and again for layout.
                let rows = filteredRows(snapshot)
                if !rows.isEmpty {
                    recommendationsMasonry(snapshot: snapshot, rows: rows)
                }
                if rows.count > visibleCount {
                    Button(english ? "Show more" : "加载更多") {
                        loadNextPage(rowCount: rows.count)
                    }
                    .frame(maxWidth: .infinity)
                    // Prefetch one page each time the control enters the
                    // viewport; the button stays for keyboard/VoiceOver and for
                    // every further page.
                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                        guard prefetch.visibilityChanged(visible) else { return }
                        loadNextPage(rowCount: rows.count)
                    }
                } else if !rows.isEmpty {
                    Text(english ? "You're all caught up for this batch" : "本批推荐已展示完")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                if rows.isEmpty {
                    emptyState
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            Text(english ? "Ranked on this Mac · original source order is unchanged" : "在本机排序 · 不改变来源原榜顺序")
                .font(.caption2).foregroundStyle(.secondary)
        }
        // Without a concrete width the feed's lazy columns size themselves to
        // their content; a long title or a wide cover can then push a card past
        // its column and over the neighbouring column. The parent now passes
        // the real slot width, so this frame only anchors the feed and keeps
        // the background/summary aligned with the masonry.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ExposureWindowReader { window in
                ExposureEnvironment.shared.attach(window)
            }
            .frame(width: 0, height: 0)
        }
        .onAppear { ExposureEnvironment.shared.start() }
        .onDisappear { ExposureEnvironment.shared.stop() }
    }

    private struct RankedRecommendation {
        let position: Int
        let row: ScoredRecommendation
    }

    private func filteredRows(
        _ snapshot: RecommendationSnapshot
    ) -> [RankedRecommendation] {
        var result: [RankedRecommendation] = []
        for (position, row) in snapshot.items.enumerated() where matches(row.item) {
            result.append(RankedRecommendation(position: position, row: row))
        }
        return result
    }

    /// Reads the live page count rather than the render's capture: a delayed
    /// visibility callback must never step the page back.
    private func loadNextPage(rowCount: Int) {
        guard rowCount > visibleCount else { return }
        visibleCount = min(rowCount, visibleCount + 20)
    }

    private var layoutWidth: CGFloat {
        let hinted = max(1, width)
        guard measuredWidth.isFinite, measuredWidth > 1 else { return hinted }
        // Keep the hint when the measurement is stale and smaller (the first
        // pass after the reader opens), but never lay out wider than the room
        // the feed really has.
        return min(hinted, measuredWidth)
    }

    private var effectiveColumnCount: Int {
        voiceOverEnabled ? 1 : RecommendationMasonryLayout.columnCount(for: layoutWidth)
    }

    private func recommendationsMasonry(
        snapshot: RecommendationSnapshot,
        rows: [RankedRecommendation]
    ) -> some View {
        let visibleRows = Array(rows.prefix(visibleCount))
        let columnCount = effectiveColumnCount
        let columnWidth = RecommendationMasonryLayout.columnWidth(
            for: layoutWidth,
            columns: columnCount
        )
        let entries = visibleRows.map { ranked in
            RecommendationMasonryEntry(
                id: ranked.row.item.id,
                title: ranked.row.item.displayTitle,
                hasImage: RecommendationCardMedia.validatedURL(for: ranked.row.item) != nil
            )
        }
        let columns = RecommendationMasonryLayout.columns(
            for: entries,
            columnCount: columnCount,
            columnWidth: columnWidth
        )

        return HStack(alignment: .top, spacing: RecommendationMasonryLayout.columnSpacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, indexes in
                LazyVStack(spacing: RecommendationMasonryLayout.cardSpacing) {
                    // Key cards by the article, not by their slot in the column.
                    // Filtering or a ranking refresh can put a different article
                    // at the same index; an index identity would then reuse the
                    // old card state (and its already-loaded cover) for a new row.
                    ForEach(indexes.map { visibleRows[$0] }, id: \.row.item.id) { ranked in
                        RecommendationCardView(
                            row: ranked.row,
                            contextID: snapshot.id.uuidString,
                            position: ranked.position,
                            policyVersion: "ranking-v\(snapshot.policyVersion)",
                            profileVersion: snapshot.profileVersion,
                            columnWidth: columnWidth
                        )
                        .frame(maxWidth: .infinity, alignment: .top)
                        .background {
                            if onCardFrames != nil {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: RecommendationCardFramePreferenceKey.self,
                                        value: [
                                            RecommendationCardFrame(
                                                id: ranked.row.item.id,
                                                frame: proxy.frame(in: .named("recommendationMasonry"))
                                            )
                                        ]
                                    )
                                }
                            }
                        }
                        .modifier(QualifiedImpression(
                            item: ranked.row.item,
                            sessionID: controller.feedSessionID,
                            epoch: controller.consentEpoch,
                            contextID: snapshot.id.uuidString,
                            position: ranked.position,
                            policyVersion: "ranking-v\(snapshot.policyVersion)",
                            profileVersion: snapshot.profileVersion
                        ))
                    }
                }
                // A hard ceiling, not a hard width: the column follows the room
                // the feed actually has and only caps at the computed column
                // width. `width` is only a hint from the dashboard's arithmetic.
                .frame(minWidth: 0, maxWidth: columnWidth, alignment: .topLeading)
            }
        }
        .coordinateSpace(name: "recommendationMasonry")
        .onPreferenceChange(RecommendationCardFramePreferenceKey.self) { frames in
            onCardFrames?(frames)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Measure after the flexible frame: this reports the room the feed was
        // actually given, not the width the columns asked for.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            guard newWidth > 1, abs(newWidth - measuredWidth) > 0.5 else { return }
            measuredWidth = newWidth
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: hasFilter ? "line.3.horizontal.decrease.circle" : "newspaper")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(hasFilter
                ? (english ? "No matching recommendations" : "暂无匹配推荐")
                : (english ? "No news collected yet" : "还没有采集到新闻"))
                .font(.headline)
            Text(hasFilter
                ? (english ? "Try clearing filters, or browse all items by source." : "可以清除筛选，或切换按源浏览查看全部内容。")
                : (english ? "Refresh to collect news, or add an RSS source in Settings." : "刷新以采集新闻，或到设置中添加 RSS 来源。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if hasFilter {
                    Button(english ? "Clear filters" : "清除筛选", action: onResetFilters)
                    Button(english ? "Browse by source" : "按源浏览", action: onShowSources)
                } else {
                    Button(english ? "Refresh news" : "刷新新闻", action: onRefresh)
                    Button(english ? "Open settings" : "打开设置", action: onOpenSettings)
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
