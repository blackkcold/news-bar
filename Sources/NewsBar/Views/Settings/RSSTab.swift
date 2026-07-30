import AppKit
import SwiftUI

struct RSSTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var newURL = ""
    @State private var newName = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var addWarning: String?
    @State private var isTesting = false
    @State private var showRecommendations = false
    @State private var recommendationValidationTask: Task<Void, Never>?
    @State private var recommendationValidationCandidates: [RSSRecommendation] = []
    @State private var recommendationValidationActiveURL: String?
    @State private var recommendationValidationResults: [String: RSSValidationOutcome] = [:]
    @State private var recommendationValidationCompletedCount = 0
    @State private var recommendationValidationSuccessCount = 0
    @State private var recommendationValidationFailureCount = 0
    @State private var recommendationValidationCancelledCount = 0
    @State private var recommendationValidationSummary = ""
    @State private var recommendationValidationSessionID: UUID?
    @State private var draggedSubscribedRSSSourceID: String?
    @State private var dropTargetRSSSourceID: String?
    @State private var pendingRSSDeletion: RSSSourceConfig?

    private let reorderAnimation = Animation.spring(response: 0.26, dampingFraction: 0.88, blendDuration: 0.08)
    private let textCountCandidates = [5, 10]
    private let imageCountCandidates = [4, 6, 8]

    private struct RecommendationValidationBadge {
        let symbol: String
        let title: String
        let tint: Color
        let hint: String
    }

    private var subscribedRSSSources: [RSSSourceConfig] {
        settings.rssSources.filter { settings.selectedRSSSourceIDs.contains($0.id) }
    }

    private var unsubscribedRSSSources: [RSSSourceConfig] {
        settings.rssSources.filter { !settings.selectedRSSSourceIDs.contains($0.id) }
    }

    private var unaddedRecommendations: [RSSRecommendation] {
        RSSRecommendations.all.filter { recommendation in
            !settings.rssSources.contains { $0.url == recommendation.url }
        }
    }

    private var hasRecommendationValidationHistory: Bool {
        !recommendationValidationResults.isEmpty
    }

    private var recommendationValidationPendingCandidates: [RSSRecommendation] {
        unaddedRecommendations.filter { recommendation in
            guard let outcome = recommendationValidationResults[recommendation.url] else {
                return true
            }
            if case .success = outcome { return false }
            return true
        }
    }

    private var recommendationValidationRetryableOutcomeCount: Int {
        unaddedRecommendations.reduce(into: 0) { partialResult, recommendation in
            guard let outcome = recommendationValidationResults[recommendation.url] else { return }
            if case .success = outcome { return }
            partialResult += 1
        }
    }

    private var recommendationValidationActionTitle: String {
        if hasRecommendationValidationHistory, recommendationValidationRetryableOutcomeCount > 0 {
            return "重试失败/已取消"
        }
        if hasRecommendationValidationHistory {
            return "继续测试未完成"
        }
        return "测试全部未添加"
    }

    private var recommendationValidationActionHint: String {
        if hasRecommendationValidationHistory, recommendationValidationRetryableOutcomeCount > 0 {
            return "仅重新验证失败、已取消或尚未完成的推荐，成功项保持不变。"
        }
        if hasRecommendationValidationHistory {
            return "继续验证上次未完成的推荐，已通过项不会重复测试。"
        }
        return "按顺序验证所有未添加推荐，测试过程不会更改订阅列表。"
    }

    private var recommendationValidationIsRunning: Bool {
        recommendationValidationTask != nil
    }

    private var recommendationValidationTotalCount: Int {
        recommendationValidationCandidates.count
    }

    private var recommendationValidationCurrentActiveName: String? {
        recommendationName(for: recommendationValidationActiveURL)
    }

    private var previewSubscribedRSSSources: [RSSSourceConfig] {
        guard
            let draggedID = draggedSubscribedRSSSourceID,
            let targetID = dropTargetRSSSourceID,
            draggedID != targetID,
            let sourceIndex = subscribedRSSSources.firstIndex(where: { $0.id == draggedID }),
            let targetIndex = subscribedRSSSources.firstIndex(where: { $0.id == targetID })
        else {
            return subscribedRSSSources
        }

        var reordered = subscribedRSSSources
        let source = reordered.remove(at: sourceIndex)
        let insertionIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        reordered.insert(source, at: insertionIndex)
        return reordered
    }

    var body: some View {
        List {
            Section {
                Toggle("统一展示数量", isOn: Binding(
                    get: { settings.rssUnifiedDisplayCount },
                    set: { settings.rssUnifiedDisplayCount = $0 }
                ))

                if settings.rssUnifiedDisplayCount {
                    rssDisplayCountRow(
                        title: "文本流",
                        selection: Binding(
                            get: { settings.rssDefaultTextCount },
                            set: { settings.rssDefaultTextCount = $0 }
                        ),
                        candidates: textCountCandidates
                    )

                    rssDisplayCountRow(
                        title: "图片流",
                        selection: Binding(
                            get: { settings.rssDefaultImageCount },
                            set: { settings.rssDefaultImageCount = $0 }
                        ),
                        candidates: imageCountCandidates
                    )
                }
            } header: {
                Text("展示数量")
            } footer: {
                Text(settings.rssUnifiedDisplayCount ? "开启后，所有 RSS 源共用同一组文本/图片展示数量。" : "关闭后，可在每个 RSS 源行中按当前展示模式单独设置数量；右键可重置为全局默认值。")
            }

            Section {
                if settings.rssSources.isEmpty {
                    emptySourcesView
                } else if subscribedRSSSources.isEmpty {
                    emptySubscribedView
                } else {
                    ForEach(Array(previewSubscribedRSSSources.enumerated()), id: \.element.id) { idx, rss in
                        subscribedRSSSourceRow(rss, index: idx)
                    }
                    .animation(reorderAnimation, value: previewSubscribedRSSSources.map(\.id))
                }
            } header: {
                HStack {
                    Text("已订阅 RSS 源 (\(subscribedRSSSources.count))")
                    Spacer()
                    Button {
                        withAnimation { showRecommendations.toggle() }
                    } label: {
                        Text(showRecommendations ? "隐藏推荐" : "推荐列表")
                            .font(.caption)
                    }
                }
            } footer: {
                if !subscribedRSSSources.isEmpty {
                    Text("拖拽已订阅源可调整展示顺序；文本流/图片流设置会保留。")
                }
            }

            if !unsubscribedRSSSources.isEmpty {
                Section {
                    ForEach(unsubscribedRSSSources) { rss in
                        unsubscribedRSSSourceRow(rss)
                    }
                } header: {
                    Text("未订阅 RSS 源 (\(unsubscribedRSSSources.count))")
                }
            }

            if showRecommendations {
                Section {
                    recommendationTestingPanel
                } header: {
                    Text("推荐验证")
                } footer: {
                    Text("只测试未添加推荐源；测试不会修改订阅、排序或通知。")
                }

                ForEach(RSSRecommendation.Category.allCases, id: \.self) { category in
                    Section {
                        ForEach(RSSRecommendations.all.filter { $0.category == category }) { rec in
                            recommendationRow(rec)
                        }
                    } header: {
                        Text(category.rawValue)
                    }
                }
            }

            Section {
                addRSSForm
            } header: {
                Text("添加 RSS 源")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onDisappear {
            cancelRecommendationValidation(clearHandleOnly: true)
        }
        .confirmationDialog(
            "删除 RSS 源？",
            isPresented: Binding(
                get: { pendingRSSDeletion != nil },
                set: { isPresented in
                    if !isPresented { pendingRSSDeletion = nil }
                }
            ),
            presenting: pendingRSSDeletion
        ) { rss in
            Button("删除 \(rss.name)", role: .destructive) {
                deleteRSSSource(rss)
            }
            Button("取消", role: .cancel) { }
        } message: { rss in
            Text("将从订阅和未订阅列表中移除“\(rss.name)”。此操作不会删除本地缓存文件，但需要重新添加才能恢复。")
        }
    }

    private var emptySourcesView: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                EditorialSourceBadge(mark: .rss, fallbackTint: .secondary, size: 28)
                Text("暂无 RSS 源，点击下方推荐列表或手动添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            Spacer()
        }
    }

    private var emptySubscribedView: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "checklist.unchecked")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("暂无已订阅 RSS 源，可在未订阅列表中勾选")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            Spacer()
        }
    }

    private func subscribedRSSSourceRow(_ rss: RSSSourceConfig, index idx: Int) -> some View {
        let isDropTarget = dropTargetRSSSourceID == rss.id && draggedSubscribedRSSSourceID != rss.id
        let setTargeted: (Bool) -> Void = { targeted in
            updateSubscribedReorderTarget(isTargeted: targeted, targetID: rss.id)
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                selectionButton(for: rss, isSelected: true)
                rssSourceSummary(rss)

                Spacer()

                dragHandle(for: rss)

                HStack(spacing: 2) {
                    Button {
                        if let idx = settings.rssSources.firstIndex(where: { $0.id == rss.id }) {
                            settings.rssSources[idx].displayMode = .text
                        }
                    } label: {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 24)
                            .background(rss.displayMode == .text ? Color.accentColor.opacity(0.15) : Color.clear)
                            .editorialClipShape(cornerRadius: 5)
                            .foregroundStyle(rss.displayMode == .text ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(rss.name) 切换为文本流")
                    .help("文本流")

                    Button {
                        if let idx = settings.rssSources.firstIndex(where: { $0.id == rss.id }) {
                            settings.rssSources[idx].displayMode = .image
                        }
                    } label: {
                        Image(systemName: "photo")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 24)
                            .background(rss.displayMode == .image ? Color.accentColor.opacity(0.15) : Color.clear)
                            .editorialClipShape(cornerRadius: 5)
                            .foregroundStyle(rss.displayMode == .image ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!rss.supportsImage)
                    .accessibilityLabel(rss.supportsImage ? "\(rss.name) 切换为图片流" : "\(rss.name) 图片流不可用")
                    .help(rss.supportsImage ? "图片流" : "此源暂无图片")
                }

                Button {
                    guard idx > 0 else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        moveSubscribedSource(from: idx, to: idx - 1)
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle().size(width: 44, height: 44))
                }
                .buttonStyle(.plain)
                .disabled(idx == 0)
                .accessibilityLabel("将 \(rss.name) 上移")
                .help("上移")

                Button {
                    guard idx < subscribedRSSSources.count - 1 else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        moveSubscribedSource(from: idx, to: idx + 1)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle().size(width: 44, height: 44))
                }
                .buttonStyle(.plain)
                .disabled(idx == subscribedRSSSources.count - 1)
                .accessibilityLabel("将 \(rss.name) 下移")
                .help("下移")

                deleteButton(for: rss)
            }

            if !settings.rssUnifiedDisplayCount {
                rssCountRow(for: rss)
                    .padding(.leading, 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(isDropTarget ? Color.accentColor.opacity(0.12) : Color.clear)
        .editorialClipShape(cornerRadius: 8)
        .contentShape(Rectangle())
        .dropDestination(for: String.self, action: { items, _ in
            handleSubscribedRSSDrop(items, targetID: rss.id)
        }, isTargeted: setTargeted)
    }

    private func unsubscribedRSSSourceRow(_ rss: RSSSourceConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                selectionButton(for: rss, isSelected: false)
                rssSourceSummary(rss)

                Spacer()

                deleteButton(for: rss)
            }

            if !settings.rssUnifiedDisplayCount {
                rssCountRow(for: rss)
                    .padding(.leading, 36)
            }
        }
        .padding(.vertical, 2)
    }

    private func selectionButton(for rss: RSSSourceConfig, isSelected: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                toggleSelection(rss.id)
            }
        } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                .font(.system(size: 16))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "取消订阅 \(rss.name)" : "订阅 \(rss.name)")
        .help(isSelected ? "取消订阅" : "订阅")
    }

    private func rssSourceSummary(_ rss: RSSSourceConfig) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rss.name)
                .font(.system(size: 13, weight: .medium))
            Text(rss.url)
                .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }

    private func rssDisplayCountRow(
        title: String,
        selection: Binding<Int>,
        candidates: [Int]
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: selection) {
                ForEach(candidates, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: rssCountPickerWidth(for: candidates))
        }
    }

    @ViewBuilder
    private func rssCountRow(for rss: RSSSourceConfig) -> some View {
        let mode = rss.displayMode
        let candidates = rssCountCandidates(for: mode)

        HStack(spacing: 8) {
            Text(rssCountTitle(for: mode))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            Picker("", selection: rssCountBinding(for: rss, mode: mode)) {
                ForEach(candidates, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: rssCountPickerWidth(for: candidates))
            .contextMenu {
                Button("重置为全局默认") {
                    resetRSSCountOverride(for: rss.id, mode: mode)
                }
            }
            .accessibilityLabel("\(rss.name) \(rssCountTitle(for: mode))展示数量")
            .accessibilityHint("按住或右键可重置为全局默认展示数量。")
            .accessibilityAction(named: Text("重置\(rssCountTitle(for: mode))展示数量")) {
                resetRSSCountOverride(for: rss.id, mode: mode)
            }

            Spacer(minLength: 0)
        }
    }

    private func rssCountCandidates(for mode: RSSSourceConfig.DisplayMode) -> [Int] {
        switch mode {
        case .text: return textCountCandidates
        case .image: return imageCountCandidates
        }
    }

    private func rssCountTitle(for mode: RSSSourceConfig.DisplayMode) -> String {
        switch mode {
        case .text: return "文本流"
        case .image: return "图片流"
        }
    }

    private func rssCountBinding(for rss: RSSSourceConfig, mode: RSSSourceConfig.DisplayMode) -> Binding<Int> {
        Binding(
            get: {
                switch mode {
                case .text:
                    return rss.textCountOverride ?? settings.rssDefaultTextCount
                case .image:
                    return rss.imageCountOverride ?? settings.rssDefaultImageCount
                }
            },
            set: { newValue in
                setRSSCountOverride(for: rss.id, mode: mode, value: newValue)
            }
        )
    }

    private func rssCountPickerWidth(for candidates: [Int]) -> CGFloat {
        CGFloat(candidates.count * 44 + 6)
    }

    private func setRSSCountOverride(for sourceID: String, mode: RSSSourceConfig.DisplayMode, value: Int) {
        guard let index = settings.rssSources.firstIndex(where: { $0.id == sourceID }) else { return }
        switch mode {
        case .text:
            settings.rssSources[index].textCountOverride = value
        case .image:
            settings.rssSources[index].imageCountOverride = value
        }
    }

    private func resetRSSCountOverride(for sourceID: String, mode: RSSSourceConfig.DisplayMode) {
        guard let index = settings.rssSources.firstIndex(where: { $0.id == sourceID }) else { return }
        switch mode {
        case .text:
            settings.rssSources[index].textCountOverride = nil
        case .image:
            settings.rssSources[index].imageCountOverride = nil
        }
    }

    private func deleteButton(for rss: RSSSourceConfig) -> some View {
        Button {
            pendingRSSDeletion = rss
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.7))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("删除 \(rss.name)")
        .accessibilityHint("需要确认后才会移除此 RSS 源。")
        .help("删除")
    }

    private func deleteRSSSource(_ rss: RSSSourceConfig) {
        settings.rssSources.removeAll { $0.id == rss.id }
        settings.selectedRSSSourceIDs.remove(rss.id)
        pendingRSSDeletion = nil
    }

    private func dragHandle(for rss: RSSSourceConfig) -> some View {
        Image(systemName: "line.horizontal.3")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 28)
            .contentShape(Rectangle())
            .draggable(rss.id)
            .accessibilityLabel("拖拽排序 \(rss.name)")
            .accessibilityHint("按住并拖动以调整已订阅 RSS 源顺序")
            .help("拖拽排序")
    }

    private func toggleSelection(_ id: String) {
        if settings.selectedRSSSourceIDs.contains(id) {
            settings.selectedRSSSourceIDs.remove(id)
        } else {
            settings.selectedRSSSourceIDs.insert(id)
        }
        regroupRSSSources()
    }

    private func moveSubscribedSource(from sourceIndex: Int, to destinationIndex: Int) {
        let currentOrder = previewSubscribedRSSSources
        guard currentOrder.indices.contains(sourceIndex), currentOrder.indices.contains(destinationIndex) else { return }

        var reordered = currentOrder
        let source = reordered.remove(at: sourceIndex)
        reordered.insert(source, at: destinationIndex)
        applySubscribedOrder(reordered)
    }

    private func updateSubscribedReorderTarget(isTargeted: Bool, targetID: String) {
        if isTargeted {
            guard
                let currentDraggedID = currentDraggedSubscribedRSSSourceID(),
                subscribedRSSSources.contains(where: { $0.id == currentDraggedID })
            else { return }

            draggedSubscribedRSSSourceID = currentDraggedID

            withAnimation(reorderAnimation) {
                dropTargetRSSSourceID = targetID
            }
        } else if dropTargetRSSSourceID == targetID {
            withAnimation(reorderAnimation) {
                dropTargetRSSSourceID = nil
            }

            if dropTargetRSSSourceID == nil {
                draggedSubscribedRSSSourceID = nil
            }
        }
    }

    private func currentDraggedSubscribedRSSSourceID() -> String? {
        NSPasteboard(name: .drag).string(forType: .string)
    }

    private func resetSubscribedReorderState() {
        draggedSubscribedRSSSourceID = nil
        dropTargetRSSSourceID = nil
    }

    private func handleSubscribedRSSDrop(_ payload: [String], targetID: String) -> Bool {
        defer { resetSubscribedReorderState() }

        guard let draggedID = payload.first, !draggedID.isEmpty else { return false }

        guard draggedID != targetID else { return false }

        guard let sourceIndex = subscribedRSSSources.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = subscribedRSSSources.firstIndex(where: { $0.id == targetID })
        else { return false }

        guard settings.selectedRSSSourceIDs.contains(draggedID) else { return false }

        var reordered = subscribedRSSSources
        let source = reordered.remove(at: sourceIndex)
        let insertionIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        reordered.insert(source, at: insertionIndex)
        withAnimation(reorderAnimation) {
            applySubscribedOrder(reordered)
        }
        return true
    }

    private func regroupRSSSources() {
        applySubscribedOrder(subscribedRSSSources)
    }

    private func applySubscribedOrder(_ subscribed: [RSSSourceConfig]) {
        let subscribedIDs = Set(subscribed.map(\.id))
        let remaining = settings.rssSources.filter { !subscribedIDs.contains($0.id) }
        settings.rssSources = subscribed + remaining
    }

    @ViewBuilder
    private func recommendationRow(_ rec: RSSRecommendation) -> some View {
        let isAdded = settings.rssSources.contains { $0.url == rec.url }

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.name)
                    .font(.system(size: 13, weight: .medium))
                Text(rec.url)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()

            recommendationValidationBadge(for: rec, isAdded: isAdded)

            if !isAdded {
                Button("添加") {
                    addRecommended(rec)
                }
                .font(.caption)
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .controlSize(.small)
                .accessibilityLabel("添加 \(rec.name)")
                .accessibilityHint("添加前会先通过安全策略验证。")
            }
        }
    }

    private func addRecommended(_ rec: RSSRecommendation) {
        let sanitizedName = SecurityPolicies.sanitizeUserInput(rec.name)
        let sanitizedURL = SecurityPolicies.sanitizeUserInput(rec.url)

        guard !settings.rssSources.contains(where: { $0.url == sanitizedURL }) else {
            addWarning = "该推荐已存在，无需重复添加"
            addError = nil
            return
        }

        switch SecurityPolicies.validateRSSURL(sanitizedURL) {
        case .blocked(let reason):
            addError = "推荐源已拦截：\(localizedSecurityReason(reason))"
            addWarning = nil
            return
        case .warning(let reason):
            addWarning = "推荐源存在安全警告：\(localizedSecurityReason(reason))"
            addError = nil
        case .valid:
            addError = nil
            addWarning = nil
        }

        let source = RSSSourceConfig(name: sanitizedName, url: sanitizedURL, displayMode: .text)
        settings.rssSources.append(source)
        settings.selectedRSSSourceIDs.insert(source.id)
        NotificationCenter.default.post(
            name: .rssSourceAdded,
            object: nil,
            userInfo: ["url": sanitizedURL, "name": sanitizedName]
        )
    }

    private var recommendationTestingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    startRecommendationValidation()
                } label: {
                    HStack(spacing: 4) {
                        if recommendationValidationIsRunning {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text(recommendationValidationActionTitle)
                    }
                }
                .disabled(recommendationValidationIsRunning || recommendationValidationPendingCandidates.isEmpty)
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .controlSize(.small)
                .accessibilityLabel(recommendationValidationActionTitle)
                .accessibilityHint(recommendationValidationActionHint)

                if recommendationValidationIsRunning {
                    Button("取消") {
                        cancelRecommendationValidation()
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                    .accessibilityLabel("取消推荐验证")
                    .accessibilityHint("停止后续尚未开始的推荐；当前正在处理的源会在可取消点结束。")
                }

                Spacer()

                Text(recommendationValidationCurrentSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if recommendationValidationIsRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(
                        value: Double(recommendationValidationCompletedCount),
                        total: Double(max(1, recommendationValidationTotalCount))
                    )
                    .accessibilityLabel("推荐验证进度")
                    .accessibilityValue("\(recommendationValidationCompletedCount) / \(recommendationValidationTotalCount)")
                    .accessibilityHint("串行验证当前推荐；取消后会停止后续源。")

                    HStack {
                        Text("进度 \(recommendationValidationCompletedCount)/\(recommendationValidationTotalCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("当前：\(recommendationValidationCurrentActiveName ?? "等待下一项")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var recommendationValidationCurrentSummaryText: String {
        if recommendationValidationIsRunning {
            if recommendationValidationSummary.isEmpty {
                return "测试中"
            }
            return recommendationValidationSummary
        }
        if !recommendationValidationSummary.isEmpty {
            return recommendationValidationSummary
        }
        if unaddedRecommendations.isEmpty {
            return "暂无可测试的推荐"
        }
        return "仅测试未添加推荐"
    }

    private func recommendationValidationBadge(for rec: RSSRecommendation, isAdded: Bool) -> some View {
        let badge = recommendationValidationBadgePresentation(for: rec, isAdded: isAdded)

        return Label(badge.title, systemImage: badge.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(badge.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badge.tint.opacity(0.12))
            .editorialClipShape(cornerRadius: 20)
            .accessibilityLabel("\(rec.name) \(badge.title)")
            .accessibilityHint(badge.hint)
    }

    private func recommendationValidationBadgePresentation(
        for rec: RSSRecommendation,
        isAdded: Bool
    ) -> RecommendationValidationBadge {
        if isAdded {
            return RecommendationValidationBadge(
                symbol: "checkmark.circle.fill",
                title: "已添加",
                tint: .secondary,
                hint: "推荐源已加入订阅列表。"
            )
        }

        let isCurrentCandidate = recommendationValidationCandidates.contains { $0.url == rec.url }

        if recommendationValidationActiveURL == rec.url, isCurrentCandidate {
            return RecommendationValidationBadge(
                symbol: "clock.arrow.circlepath",
                title: "测试中",
                tint: .accentColor,
                hint: "正在串行验证此推荐。"
            )
        }

        guard let outcome = recommendationValidationResults[rec.url] else {
            return RecommendationValidationBadge(
                symbol: "circle",
                title: "待测",
                tint: .secondary,
                hint: "尚未开始验证。"
            )
        }

        switch outcome {
        case .blocked(let reason):
            return RecommendationValidationBadge(
                symbol: "shield.slash.fill",
                title: "已拦截",
                tint: .red,
                hint: "安全策略拦截：\(localizedSecurityReason(reason))"
            )
        case .invalidURL:
            return RecommendationValidationBadge(
                symbol: "exclamationmark.triangle.fill",
                title: "URL 无效",
                tint: .orange,
                hint: "地址格式无效。"
            )
        case .cancelled:
            return RecommendationValidationBadge(
                symbol: "pause.circle.fill",
                title: "已取消",
                tint: .secondary,
                hint: "验证已停止，后续推荐未继续。"
            )
        case .networkError(let summary):
            return RecommendationValidationBadge(
                symbol: "wifi.exclamationmark",
                title: "网络失败",
                tint: .orange,
                hint: localizedNetworkSummary(summary)
            )
        case .notRSSFeed:
            return RecommendationValidationBadge(
                symbol: "doc.text.magnifyingglass",
                title: "非 RSS",
                tint: .orange,
                hint: "返回内容不是 RSS 或 Atom。"
            )
        case .success(let itemCount):
            return RecommendationValidationBadge(
                symbol: "checkmark.circle.fill",
                title: "通过",
                tint: .green,
                hint: "验证通过，约 \(itemCount) 项内容。"
            )
        }
    }

    private func startRecommendationValidation() {
        guard recommendationValidationTask == nil else { return }

        let candidates = recommendationValidationPendingCandidates
        guard !candidates.isEmpty else {
            recommendationValidationSummary = hasRecommendationValidationHistory ? "暂无可重试的推荐" : "暂无可测试的推荐"
            return
        }

        let isRetryRun = recommendationValidationRetryableOutcomeCount > 0 && hasRecommendationValidationHistory
        let sessionID = UUID()

        recommendationValidationSessionID = sessionID
        recommendationValidationCandidates = candidates
        recommendationValidationCompletedCount = 0
        recommendationValidationSuccessCount = 0
        recommendationValidationFailureCount = 0
        recommendationValidationCancelledCount = 0
        recommendationValidationActiveURL = candidates.first?.url
        recommendationValidationSummary = isRetryRun ? "重试中 \(candidates.count) 项" : "测试中 \(candidates.count) 项"

        let candidateSnapshot = candidates

        recommendationValidationTask = Task {
            let summary = await RSSValidationService.validateRecommendationsSerially(candidateSnapshot) { _, url, outcome in
                Task { @MainActor in
                    self.recordRecommendationValidationOutcome(sessionID: sessionID, url: url, outcome: outcome)
                }
            }

            await MainActor.run {
                self.finishRecommendationValidation(sessionID: sessionID, summary: summary, retryRun: isRetryRun)
            }
        }
    }

    private func cancelRecommendationValidation(clearHandleOnly: Bool = false) {
        recommendationValidationTask?.cancel()
        recommendationValidationSessionID = nil
        recommendationValidationTask = nil
        recommendationValidationActiveURL = nil
        if clearHandleOnly {
            return
        }
        recommendationValidationSummary = "已取消，后续推荐已停止"
    }

    @MainActor
    private func recordRecommendationValidationOutcome(sessionID: UUID, url: String, outcome: RSSValidationOutcome) {
        guard recommendationValidationSessionID == sessionID else { return }
        recommendationValidationResults[url] = outcome
        recommendationValidationCompletedCount = min(recommendationValidationCompletedCount + 1, recommendationValidationTotalCount)

        switch outcome {
        case .success:
            recommendationValidationSuccessCount += 1
        case .cancelled:
            recommendationValidationCancelledCount += 1
        default:
            recommendationValidationFailureCount += 1
        }

        let nextIndex = recommendationValidationCompletedCount
        recommendationValidationActiveURL = recommendationValidationCandidates.indices.contains(nextIndex) ? recommendationValidationCandidates[nextIndex].url : nil

        if recommendationValidationTask?.isCancelled == true {
            recommendationValidationSummary = "已取消，后续推荐已停止"
        } else {
            recommendationValidationSummary = "测试中 \(recommendationValidationCompletedCount)/\(recommendationValidationTotalCount)"
        }
    }

    @MainActor
    private func finishRecommendationValidation(sessionID: UUID, summary: RSSValidationSummary, retryRun: Bool) {
        guard recommendationValidationSessionID == sessionID else { return }
        recommendationValidationSessionID = nil
        recommendationValidationTask = nil
        recommendationValidationCandidates = []
        recommendationValidationActiveURL = nil

        let cancelledCount = summary.outcomes.filter { $0.outcome == .cancelled }.count
        let successCount = summary.successCount
        let failedCount = summary.outcomes.filter { entry in
            switch entry.outcome {
            case .success, .cancelled:
                return false
            default:
                return true
            }
        }.count

        recommendationValidationCompletedCount = summary.outcomes.count
        recommendationValidationSuccessCount = successCount
        recommendationValidationFailureCount = failedCount
        recommendationValidationCancelledCount = cancelledCount
        recommendationValidationSummary = recommendationValidationFinishText(
            retryRun: retryRun,
            successCount: successCount,
            failedCount: failedCount,
            cancelledCount: cancelledCount,
            wasCancelled: summary.wasCancelled
        )
    }

    private func recommendationValidationFinishText(
        retryRun: Bool,
        successCount: Int,
        failedCount: Int,
        cancelledCount: Int,
        wasCancelled: Bool
    ) -> String {
        var parts: [String] = []
        if successCount > 0 { parts.append("\(successCount) 通过") }
        if failedCount > 0 { parts.append("\(failedCount) 失败") }

        let prefix = retryRun ? "重试完成" : "测试完成"
        let body = parts.isEmpty ? "无结果" : parts.joined(separator: "，")

        if wasCancelled {
            if parts.isEmpty {
                return "已取消：\(cancelledCount) 项停止"
            }
            let stopText = cancelledCount > 0 ? "；\(cancelledCount) 项停止" : ""
            return "已取消：\(body)\(stopText)"
        }

        return "\(prefix)：\(body)"
    }

    private func recommendationName(for url: String?) -> String? {
        guard let url else { return nil }
        return RSSRecommendations.all.first(where: { $0.url == url })?.name
    }

    private func localizedSecurityReason(_ reason: String) -> String {
        switch reason {
        case "Invalid URL or scheme":
            return "URL 或协议无效"
        default:
            if reason.hasPrefix("Blocked host: ") {
                return "已拦截主机：" + reason.replacingOccurrences(of: "Blocked host: ", with: "")
            }
            if reason.hasPrefix("Private IP range: ") {
                return "私有网段：" + reason.replacingOccurrences(of: "Private IP range: ", with: "")
            }
            return reason
        }
    }

    private func localizedNetworkSummary(_ summary: String) -> String {
        switch summary {
        case "Request timed out":
            return "请求超时"
        case "Cannot connect to server":
            return "无法连接服务器"
        case "No internet connection":
            return "没有网络连接"
        case "Server not found":
            return "未找到服务器"
        case "Invalid server response":
            return "服务器响应无效"
        case "Server returned an error":
            return "服务器返回错误"
        case "Feed parse failed":
            return "订阅内容解析失败"
        case "Unexpected error":
            return "发生未知错误"
        case "Network error":
            return "网络错误"
        default:
            return summary
        }
    }

    private var addRSSForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("源名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("RSS URL", text: $newURL)
                    .textFieldStyle(.roundedBorder)
            }

            if let error = addError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let warning = addWarning {
                Text("⚠️ \(warning)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(action: addRSSSource) {
                    HStack(spacing: 4) {
                        if isTesting {
                            ProgressView().scaleEffect(0.6)
                        }
                        Text("添加并验证")
                    }
                }
                .disabled(newName.isEmpty || newURL.isEmpty || isTesting)
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
            }
        }
    }

    private func addRSSSource() {
        let sanitizedURL = SecurityPolicies.sanitizeUserInput(newURL)
        let sanitizedName = SecurityPolicies.sanitizeUserInput(newName)

        guard !sanitizedURL.isEmpty else {
            addError = "请输入 RSS URL"
            return
        }

        var normalizedURL = sanitizedURL
        if URL(string: normalizedURL)?.scheme == nil {
            normalizedURL = "https://" + normalizedURL
        }

        switch SecurityPolicies.validateRSSURL(normalizedURL) {
        case .valid:
            break
        case .blocked(let reason):
            addError = reason
            return
        case .warning(let reason):
            addWarning = reason
            addError = nil
            // warning is non-blocking, user can still add
        }

        isTesting = true

        Task {
            do {
                let isValid = try await RSSService.validate(normalizedURL)
                if isValid {
                    let source = RSSSourceConfig(
                        name: sanitizedName, url: normalizedURL, displayMode: .text
                    )
                    settings.rssSources.append(source)
                    settings.selectedRSSSourceIDs.insert(source.id)
                    newURL = ""
                    newName = ""
                    addError = nil
                    addWarning = nil
                    NotificationCenter.default.post(
                        name: .rssSourceAdded,
                        object: nil,
                        userInfo: ["url": normalizedURL, "name": sanitizedName]
                    )
                } else {
                    addError = "该地址不是有效的 RSS/Atom Feed"
                }
            } catch {
                addError = "无法连接到该地址"
            }
            isTesting = false
        }
    }
}
