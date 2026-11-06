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

struct RecommendationFeedView: View {
    let matches: (NewsItem) -> Bool
    /// The width the dashboard is actually giving this feed. When the reader
    /// opens, the list pane is clamped to 320–480 pt; passing that width down
    /// makes the masonry choose one column in the same layout pass instead of
    /// waiting for a content-width measurement that can still be stale.
    var width: CGFloat? = nil
    var hasFilter = false
    var onOpenSettings: () -> Void = {}
    var onResetFilters: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onShowSources: () -> Void = {}
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var controller = InterestController.shared
    @State private var visibleCount = 20
    @State private var feedWidth: CGFloat = 720
    private var english: Bool { settings.appLanguage == .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(english ? "For you" : "为你推荐", systemImage: "sparkles").editorialHeading(size: 20)
                Spacer()
                Text(controller.learningStatus.title(language: settings.appLanguage))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !controller.state.learningEnabled {
                HStack(alignment: .top, spacing: 12) {
                    Text(english ? "Public ranking is available without recording your reading behavior." : "未开启阅读行为记录，仍可使用公共推荐。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(english ? "Set up personalization" : "设置个性化", action: onOpenSettings)
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            if controller.state.learningPaused || controller.privateReading {
                Label(english ? "Learning paused for this activity" : "当前活动不参与学习", systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot = controller.recommendations {
                recommendationsMasonry(snapshot)
                let filteredCount = filteredRows(snapshot, limit: nil).count
                if filteredCount > visibleCount {
                    Button(english ? "Show more" : "加载更多") { visibleCount += 20 }
                        .frame(maxWidth: .infinity)
                } else if filteredCount > 0 {
                    Text(english ? "You're all caught up for this batch" : "本批推荐已展示完")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                if filteredCount == 0 {
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
        // its column and over the neighbouring column. Fill the available width
        // before measuring, and give every card the same fixed column width.
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if width > 0, abs(width - feedWidth) > 0.5 { feedWidth = width }
        }
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
        _ snapshot: RecommendationSnapshot,
        limit: Int?
    ) -> [RankedRecommendation] {
        var result: [RankedRecommendation] = []
        for (position, row) in snapshot.items.enumerated() where matches(row.item) {
            result.append(RankedRecommendation(position: position, row: row))
            if let limit, result.count >= limit { break }
        }
        return result
    }

    private var layoutWidth: CGFloat {
        max(1, width ?? feedWidth)
    }

    private var effectiveColumnCount: Int {
        voiceOverEnabled ? 1 : RecommendationMasonryLayout.columnCount(for: layoutWidth)
    }

    private func recommendationsMasonry(_ snapshot: RecommendationSnapshot) -> some View {
        let rows = filteredRows(snapshot, limit: visibleCount)
        let columnCount = effectiveColumnCount
        let columnWidth = RecommendationMasonryLayout.columnWidth(
            for: layoutWidth,
            columns: columnCount
        )
        let entries = rows.map { ranked in
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
                    ForEach(indexes, id: \.self) { index in
                        let ranked = rows[index]
                        RecommendationCardView(
                            row: ranked.row,
                            contextID: snapshot.id.uuidString,
                            position: ranked.position,
                            policyVersion: "ranking-v\(snapshot.policyVersion)",
                            profileVersion: snapshot.profileVersion,
                            columnWidth: columnWidth
                        )
                        .frame(width: columnWidth, alignment: .top)
                        .modifier(QualifiedImpression(
                            item: ranked.row.item,
                            sessionID: controller.feedSessionID,
                            epoch: controller.state.consentEpoch,
                            contextID: snapshot.id.uuidString,
                            position: ranked.position,
                            policyVersion: "ranking-v\(snapshot.policyVersion)",
                            profileVersion: snapshot.profileVersion
                        ))
                    }
                }
                .frame(width: columnWidth, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
