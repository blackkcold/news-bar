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
    var hasFilter = false
    var onOpenSettings: () -> Void = {}
    var onResetFilters: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onShowSources: () -> Void = {}
    @Environment(AppSettings.self) private var settings
    @State private var controller = InterestController.shared
    @State private var expandedReason: String?
    @State private var visibleCount = 20
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(snapshot.items.enumerated().filter { matches($0.element.item) }.prefix(visibleCount)), id: \.element.id) { position, row in
                        VStack(alignment: .leading, spacing: 9) {
                            HeroOpenButton(
                                item: row.item,
                                surface: "recommendation",
                                contextID: snapshot.id.uuidString,
                                policyVersion: "ranking-v\(snapshot.policyVersion)",
                                profileVersion: snapshot.profileVersion,
                                position: position
                            ) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.item.displayTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Text(row.item.source.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .modifier(QualifiedImpression(
                                item: row.item,
                                sessionID: controller.feedSessionID,
                                epoch: controller.state.consentEpoch,
                                contextID: snapshot.id.uuidString,
                                position: position,
                                policyVersion: "ranking-v\(snapshot.policyVersion)",
                                profileVersion: snapshot.profileVersion
                            ))
                            HStack(spacing: 10) {
                                Button(reason(row)) { expandedReason = expandedReason == row.id ? nil : row.id }
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Menu {
                                    Button(english ? "Bookmark / remove" : "收藏／取消收藏") {
                                        if let id = controller.toggleBookmark(row.item) {
                                            ActionToastCenter.shared.show(english ? "Bookmarked" : "已收藏") {
                                                controller.undo(id)
                                            }
                                        }
                                    }
                                    Button(english ? "More like this (session)" : "更多同类（本次会话）") {
                                        if let id = controller.feedback(row.item, kind: .moreLikeThis) {
                                            ActionToastCenter.shared.show(english ? "More like this" : "已记录：更多同类") {
                                                controller.undo(id)
                                            }
                                        }
                                    }
                                    .disabled(!controller.canLearn)
                                    .help(softFeedbackHelp)

                                    Divider()

                                    Menu(english ? "Less like this" : "少推荐") {
                                        Button(english ? "This article" : "这条内容") {
                                            if let id = controller.feedback(row.item, kind: .lessLikeContent) {
                                                ActionToastCenter.shared.show(english ? "Fewer like this" : "已减少推荐：这条") {
                                                    controller.undo(id)
                                                }
                                            }
                                        }
                                        if let topic = row.topic {
                                            Button(english ? "This topic" : "这个主题") {
                                                if let id = controller.feedback(row.item, kind: .reduceTopic, topic: topic) {
                                                    ActionToastCenter.shared.show(english ? "Fewer like this topic" : "已减少推荐：这个主题") {
                                                        controller.undo(id)
                                                    }
                                                }
                                            }
                                        }
                                        Button(english ? "This source" : "这个来源") {
                                            if let id = controller.feedback(row.item, kind: .lessLikeSource) {
                                                ActionToastCenter.shared.show(english ? "Fewer like this source" : "已减少推荐：这个来源") {
                                                    controller.undo(id)
                                                }
                                            }
                                        }
                                    }
                                    .disabled(!controller.canLearn)
                                    .help(softFeedbackHelp)

                                    Menu(english ? "Hide" : "屏蔽") {
                                        Button(english ? "This article" : "不再看这条") {
                                            if let id = controller.feedback(row.item, kind: .notInterested) {
                                                ActionToastCenter.shared.show(english ? "Hidden: this article" : "已屏蔽：这条") {
                                                    controller.undo(id)
                                                }
                                            }
                                        }
                                        Button(english ? "This event" : "不再看这个事件") {
                                            if let id = controller.feedback(row.item, kind: .hideEvent) {
                                                ActionToastCenter.shared.show(english ? "Hidden: this event" : "已屏蔽：这个事件") {
                                                    controller.undo(id)
                                                }
                                            }
                                        }
                                        Button(english ? "This source" : "屏蔽这个来源") {
                                            if let id = controller.feedback(row.item, kind: .muteSource) {
                                                ActionToastCenter.shared.show(english ? "Muted source" : "已屏蔽：这个来源") {
                                                    controller.undo(id)
                                                }
                                            }
                                        }
                                    }
                                } label: { Image(systemName: "ellipsis").frame(minWidth: 28, minHeight: 28) }
                                .disabled(!controller.canManagePreferences)
                                .accessibilityLabel(english ? "Reading preferences" : "阅读偏好操作")
                                .help(controller.canManagePreferences ? (english ? "Reading preferences" : "阅读偏好") : (english ? "Local preference storage is unavailable" : "本地偏好存储暂不可用"))
                            }
                            .buttonStyle(.borderless)
                            if expandedReason == row.id {
                                Text(explanation(row)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .newsCardSurface(cornerRadius: 14)
                    }
                }
                if snapshot.items.filter({ matches($0.item) }).count > visibleCount {
                    Button(english ? "Show more" : "加载更多") { visibleCount += 20 }.frame(maxWidth: .infinity)
                }
                if snapshot.items.filter({ matches($0.item) }).isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: hasFilter ? "line.3.horizontal.decrease.circle" : "newspaper").font(.largeTitle).foregroundStyle(.secondary)
                        Text(hasFilter ? (english ? "No matching recommendations" : "暂无匹配推荐") : (english ? "No news collected yet" : "还没有采集到新闻"))
                            .font(.headline)
                        Text(hasFilter ? (english ? "Try clearing filters, or browse all items by source." : "可以清除筛选，或切换按源浏览查看全部内容。")
                             : (english ? "Refresh to collect news, or add an RSS source in Settings." : "刷新以采集新闻，或到设置中添加 RSS 来源。"))
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            if hasFilter {
                                Button(english ? "Clear filters" : "清除筛选", action: onResetFilters)
                                Button(english ? "Browse by source" : "按源浏览", action: onShowSources)
                            } else {
                                Button(english ? "Refresh news" : "刷新新闻", action: onRefresh)
                                Button(english ? "Open settings" : "打开设置", action: onOpenSettings)
                            }
                        }.buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 32)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            Text(english ? "Ranked on this Mac · original source order is unchanged" : "在本机排序 · 不改变来源原榜顺序")
                .font(.caption2).foregroundStyle(.secondary)
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

    private var softFeedbackHelp: String {
        controller.canLearn
            ? (english ? "Uses this session's short-term interest only." : "仅影响本次会话的短期兴趣。")
            : InterestFeedbackCopy.softFeedbackUnavailable(settings.appLanguage)
    }

    private func reason(_ row: ScoredRecommendation) -> String {
        switch row.reason {
        case "interest": return english ? "Related to your interests" : "与你的阅读与关注主题相关"
        case "publicHeat": return english ? "Public chart signal" : "公开榜单热度"
        case "exploration": return english ? "Source rotation" : "来源补位"
        default: return english ? "Recently discovered" : "近期采集内容"
        }
    }

    private func explanation(_ row: ScoredRecommendation) -> String {
        let labels = english
            ? ["interest": "Topic match", "source": "Source preference", "recency": "Recency", "novelty": "Novelty", "publicHeat": "Public heat"]
            : ["interest": "主题相关", "source": "来源偏好", "recency": "时效", "novelty": "新颖性", "publicHeat": "公开热度"]
        let values = row.components.sorted { $0.key < $1.key }.map { "\(labels[$0.key] ?? $0.key)：\(String(format: "%.2f", $0.value))" }.joined(separator: " · ")
        return reason(row) + "\n" + values + (english ? "\nMissing features are unknown; scores are heuristics, not predicted reading probabilities." : "\n缺失特征按未知处理；分数是启发式排序，不是阅读概率。")
    }
}
