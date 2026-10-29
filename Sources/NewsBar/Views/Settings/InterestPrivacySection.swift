import SwiftUI

struct InterestPrivacySection: View {
    @Environment(AppSettings.self) private var settings
    @State private var controller: InterestController
    @State private var consentPrompt = false
    @State private var clearPrompt = false
    @State private var topic = ""
    @State private var topicMessage: String?
    @State private var showSavedRules = false
    @State private var explanationPresented = false
    @State private var frozenExplanation: RecommendationExplanationModel?
    @State private var isClearing = false
    @State private var clearMessage: String?
    private var english: Bool { settings.appLanguage == .en }

    @MainActor
    init(controller: InterestController = .shared) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        Section {
            Toggle(english ? "Local personalization" : "本地个性化推荐", isOn: Binding(
                get: { controller.state.learningEnabled },
                set: { enabled in
                    if enabled { consentPrompt = true } else { controller.setLearningEnabled(false) }
                }
            )).disabled(!controller.canManagePreferences)
            if controller.state.learningEnabled {
                Toggle(english ? "Pause learning" : "暂停学习（保留画像）", isOn: Binding(get: { controller.state.learningPaused }, set: controller.setPaused))
                    .disabled(!controller.canManagePreferences)
                Toggle(english ? "Private reading" : "隐私阅读（不记录当前浏览）", isOn: $controller.privateReading)
                HStack {
                    TextField(english ? "Topic or keyword" : "关注主题或关键词", text: $topic)
                        .disabled(!controller.canLearn)
                        .accessibilityLabel(english ? "Topic or keyword to follow" : "要关注的主题或关键词")
                        .help(controller.canLearn
                              ? (english ? "Adds a local topic or literal keyword." : "添加本地关注主题或字面关键词。")
                              : InterestFeedbackCopy.followRequiresLearning(settings.appLanguage))
                        .onSubmit { followTopic() }
                    Button(english ? "Follow" : "关注", action: followTopic)
                        .disabled(!controller.canLearn || topic.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help(controller.canLearn
                              ? (english ? "Adds a local topic or literal keyword." : "添加本地关注主题或字面关键词。")
                              : InterestFeedbackCopy.followRequiresLearning(settings.appLanguage))
                }
                if let topicMessage { Text(topicMessage).font(.caption).foregroundStyle(.secondary) }
                ForEach(controller.state.followedTopics, id: \.self) { value in
                    HStack {
                        Text(value)
                        Spacer()
                        Button(english ? "Unfollow" : "取消关注") { controller.unfollow(value) }.disabled(!controller.canManagePreferences)
                    }
                }
            }
            RecommendationExplanationEntry(
                statusTitle: controller.learningStatus.title(language: settings.appLanguage),
                detail: english
                    ? "Inspect the local profile, ranking trace and privacy scope. Read-only."
                    : "查看本地画像、排序链路与隐私范围（只读）",
                theme: settings.appTheme,
                language: settings.appLanguage,
                action: {
                    // Capture once so the sheet keeps showing the same frozen
                    // snapshot even if the controller publishes a newer ranking.
                    frozenExplanation = makeExplanationModel()
                    explanationPresented = true
                }
            )
            if !controller.state.feedbacks.isEmpty {
                DisclosureGroup(isExpanded: $showSavedRules) {
                ForEach(controller.state.feedbacks.filter { [.bookmark, .muteSource, .hideEvent, .notInterested, .reduceTopic, .lessLikeContent, .lessLikeSource].contains($0.kind) }.suffix(30).reversed()) { feedback in
                    HStack {
                        Image(systemName: feedback.kind == .bookmark ? "bookmark" : "minus.circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feedbackLabel(feedback.kind)).foregroundStyle(.secondary)
                            Text(feedback.kind == .muteSource || feedback.kind == .lessLikeSource ? feedback.item.source.displayName : feedback.item.displayTitle).lineLimit(2)
                            if let hint = decayHint(feedback.kind) {
                                Text(hint).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button(english ? "Remove / undo" : "移除／撤销") { controller.undo(feedback.id, restorePrevious: false) }.disabled(!controller.canManagePreferences)
                    }
                    .font(.caption)
                }
                if controller.state.feedbacks.count > 30 {
                    Text(english ? "Showing the latest 30 saved preferences." : "显示最近 30 项已保存偏好。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                } label: {
                    Text(english ? "Saved bookmarks and preferences (\(controller.state.feedbacks.count))" : "已保存的收藏与偏好（\(controller.state.feedbacks.count)）")
                }
            }
            if controller.storageError != nil {
                Text(english ? "Local reading data is unavailable. Learning has stopped." : "本地阅读数据暂不可用，已停止学习。")
                    .foregroundStyle(.red).font(.caption)
            }
            Button(english ? "Clear reading data and profile…" : "清空阅读数据与画像…", role: .destructive) { clearPrompt = true }
                // Recovery stays reachable while the store is unavailable, but a
                // reset in progress must not accept a second confirmation.
                .disabled(!controller.canResetStorage || isClearing)
            if isClearing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(english ? "Clearing local data…" : "正在清空本地数据…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let clearMessage {
                Text(clearMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(english ? "Raw events: 30 days · aggregate profile: 180 days · metadata: 7 days. Bookmarks are optional on clearing." : "原始行为保留 30 天，画像聚合 180 天，内容元数据 7 天；清空时可选择保留收藏。")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(english ? "Local interest & privacy" : "本地兴趣与隐私")
        } footer: {
            Text(english ? "Off by default. Behavior and profile stay on this Mac. Selected news titles still go to your configured AI provider for summaries. System browser history, passwords and cookies are never imported; the reader only keeps first-party cookies from sites you visit, managed in the Browser tab." : "默认关闭。行为与画像仅存本机；摘要仍会把选中的新闻标题发给配置的 AI 提供商。不导入系统浏览器的历史、密码或 Cookie；阅读器只保存你访问站点自身的第一方 Cookie，可在「浏览器」页签管理。")
        }
        .task { await controller.prepare() }
        .sheet(isPresented: $explanationPresented) {
            if let frozenExplanation {
                RecommendationExplanationView(model: frozenExplanation, theme: settings.appTheme)
                    .appThemeSurface()
                    .environment(settings)
            }
        }
        .confirmationDialog(english ? "Allow local reading-behavior learning?" : "允许在本机记录新闻阅读行为？", isPresented: $consentPrompt) {
            Button(english ? "Allow local personalization" : "允许本地个性化") { controller.setLearningEnabled(true) }
        } message: {
            Text(english ? "NewsBar stores qualified impressions, opens, aggregate reading evidence and your explicit feedback locally. Pause, private reading and data clearing are available at any time." : "NewsBar 将在本机保存合格曝光、打开、聚合阅读证据和明确反馈，用于推荐排序。可随时暂停、隐私阅读或清空。")
        }
        .confirmationDialog(english ? "Clear personal reading data?" : "清空个人阅读数据？", isPresented: $clearPrompt) {
            Button(english ? "Clear, keep bookmarks" : "清空，但保留收藏", role: .destructive) {
                Task { await runClear(keepBookmarks: true) }
            }
            .disabled(isClearing)
            Button(english ? "Clear everything including bookmarks" : "全部清空（包括收藏）", role: .destructive) {
                Task { await runClear(keepBookmarks: false) }
            }
            .disabled(isClearing)
        } message: {
            Text(english ? "Removes behavior, profile, feedback, followed keywords, personalized caches, research state, the public content cache and the current web session, and stops learning. Retained bookmarks do not automatically rebuild the profile. A failed clear is not shown as success." : "将清除行为、画像、反馈、关注词、个性化缓存、调研状态、公开内容缓存与当前网页会话，并停止学习。保留收藏不会自动重建画像。清空失败不会显示成功。")
        }
    }

    private func makeExplanationModel() -> RecommendationExplanationModel {
        RecommendationExplanationModel.make(
            input: RecommendationExplanationInput(
                isReady: controller.isReady,
                isResetting: controller.isResetting,
                storageError: controller.storageError,
                privateReading: controller.privateReading,
                state: controller.state,
                snapshot: controller.recommendations,
                sessionFeedback: controller.sessionFeedback,
                now: Date(),
                language: settings.appLanguage
            ),
            guide: RecommendationExplanationIntegration.guideSections(language: settings.appLanguage),
            traceFor: RecommendationExplanationIntegration.trace(for:)
        )
    }

    @MainActor
    private func runClear(keepBookmarks: Bool) async {
        guard !isClearing else { return }
        isClearing = true
        clearMessage = nil
        let succeeded = await controller.clear(keepBookmarks: keepBookmarks)
        isClearing = false
        guard !succeeded else { return }
        // Never claim success; show the controller's diagnostic when present.
        // A nil error (e.g. a concurrent second clear) still must not say the
        // data was not deleted: only that the state is unconfirmed.
        clearMessage = controller.storageError
            ?? (english ? "Clear failed; local data state is unconfirmed." : "清空失败，本地数据状态未确认。")
    }

    private func followTopic() {
        guard controller.canLearn else { return }
        if controller.follow(topic) {
            topic = ""
            topicMessage = english ? "Topic followed. Only local ranking changes; no AI request is triggered." : "已关注。仅更新本地排序，不触发 AI 请求。"
        } else {
            topicMessage = english ? "Enter a new topic. Duplicate topics are already followed (maximum 100)." : "请输入新主题；重复主题已关注，最多可保存 100 个主题。"
        }
    }

    private func decayHint(_ kind: InterestFeedbackKind) -> String? {
        switch kind {
        case .lessLikeContent: return english ? "Fades by half in about 14 days" : "约 14 天减弱一半"
        case .reduceTopic, .lessLikeSource: return english ? "Fades by half in about 30 days" : "约 30 天减弱一半"
        default: return nil
        }
    }

    private func feedbackLabel(_ kind: InterestFeedbackKind) -> String {
        switch kind {
        case .bookmark: return english ? "Bookmarked" : "已收藏"
        case .muteSource: return english ? "Muted source" : "已屏蔽来源"
        case .hideEvent: return english ? "Hidden event" : "已隐藏事件"
        case .reduceTopic: return english ? "Reduced topic" : "已减少主题"
        case .lessLikeContent: return english ? "Less like this event" : "少推荐这条"
        case .lessLikeSource: return english ? "Less like this source" : "少推荐这个来源"
        case .unknown: return english ? "Other preference" : "其他偏好"
        default: return english ? "Not interested" : "不感兴趣"
        }
    }
}
