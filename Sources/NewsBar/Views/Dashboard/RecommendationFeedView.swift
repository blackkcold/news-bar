import AppKit
import Combine
import SwiftUI

private enum ExposureClock {
    static let ticks = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().share()
}

private struct QualifiedImpression: ViewModifier {
    let item: NewsItem
    let sessionID: UUID
    let epoch: UUID
    @State private var visible = false
    @State private var exposure = QualifiedExposure()

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: 0.5) { visible = $0 }
            .onReceive(ExposureClock.ticks) { _ in
                guard InterestController.shared.canLearn else { return }
                let window = NSApp.keyWindow
                let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
                let active = NSApp.isActive && window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !locked
                if exposure.update(visibleFraction: visible ? 1 : 0, active: active, now: ProcessInfo.processInfo.systemUptime) {
                    InterestController.shared.record(item, kind: .impression, epoch: epoch, sessionID: sessionID)
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
    @State private var listSession = UUID()
    @State private var lastFeedback: UUID?
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
                    ForEach(Array(snapshot.items.filter { matches($0.item) }.prefix(visibleCount))) { row in
                        VStack(alignment: .leading, spacing: 9) {
                            Button {
                                NewsNavigationRouter.shared.open(row.item, surface: "recommendation", contextID: snapshot.id.uuidString)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.item.displayTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Text(row.item.source.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .modifier(QualifiedImpression(item: row.item, sessionID: listSession, epoch: controller.state.consentEpoch))
                            HStack(spacing: 10) {
                                Button(reason(row)) { expandedReason = expandedReason == row.id ? nil : row.id }
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Menu {
                                    Button(english ? "Bookmark / remove" : "收藏／取消收藏") { lastFeedback = controller.toggleBookmark(row.item) }
                                    Button(english ? "More like this (session)" : "更多同类（本次会话）") { lastFeedback = controller.feedback(row.item, kind: .moreLikeThis) }
                                    Button(english ? "Not interested: this article" : "不感兴趣：仅这条") { lastFeedback = controller.feedback(row.item, kind: .notInterested) }
                                    Button(english ? "Hide this event" : "不再看这个事件") { lastFeedback = controller.feedback(row.item, kind: .hideEvent) }
                                    if let topic = row.topic {
                                        Button(english ? "Reduce this topic" : "减少这个主题") { lastFeedback = controller.feedback(row.item, kind: .reduceTopic, topic: topic) }
                                    }
                                    Button(english ? "Mute source" : "屏蔽来源") { lastFeedback = controller.feedback(row.item, kind: .muteSource) }
                                } label: { Image(systemName: "ellipsis").frame(minWidth: 28, minHeight: 28) }
                                .disabled(!controller.canLearn)
                                .accessibilityLabel(english ? "Reading preferences" : "阅读偏好操作")
                                .help(controller.canLearn ? (english ? "Reading preferences" : "阅读偏好") : (english ? "Enable personalization to give feedback" : "开启个性化后可反馈"))
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
            if let feedback = lastFeedback {
                Button(english ? "Undo last feedback" : "撤销上一次反馈") { controller.undo(feedback); lastFeedback = nil }
            }
            Text(english ? "Ranked on this Mac · original source order is unchanged" : "在本机排序 · 不改变来源原榜顺序")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func reason(_ row: ScoredRecommendation) -> String {
        switch row.reason {
        case "interest": return english ? "Related to your interests" : "与你的阅读与关注主题相关"
        case "publicHeat": return english ? "Public chart signal" : "公开榜单热度"
        case "exploration": return english ? "Explore another topic" : "探索推荐"
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
