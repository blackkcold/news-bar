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
            return "rss.retryFailed".localized
        }
        if hasRecommendationValidationHistory {
            return "rss.continueTesting".localized
        }
        return "rss.testAll".localized
    }

    private var recommendationValidationActionHint: String {
        if hasRecommendationValidationHistory, recommendationValidationRetryableOutcomeCount > 0 {
            return "rss.testHint.retry".localized
        }
        if hasRecommendationValidationHistory {
            return "rss.testHint.continue".localized
        }
        return "rss.testHint.all".localized
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
                Toggle("rss.unifiedCount".localized, isOn: Binding(
                    get: { settings.rssUnifiedDisplayCount },
                    set: { settings.rssUnifiedDisplayCount = $0 }
                ))

                if settings.rssUnifiedDisplayCount {
                    rssDisplayCountRow(
                        title: "rss.textFlow".localized,
                        selection: Binding(
                            get: { settings.rssDefaultTextCount },
                            set: { settings.rssDefaultTextCount = $0 }
                        ),
                        candidates: textCountCandidates
                    )

                    rssDisplayCountRow(
                        title: "rss.imageFlow".localized,
                        selection: Binding(
                            get: { settings.rssDefaultImageCount },
                            set: { settings.rssDefaultImageCount = $0 }
                        ),
                        candidates: imageCountCandidates
                    )
                }
            } header: {
                Text("rss.displayCount".localized)
            } footer: {
                Text(settings.rssUnifiedDisplayCount ? "rss.displayCount.footer.unified".localized : "rss.displayCount.footer.perSource".localized)
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
                    Text(L10n.string("rss.subscribed", subscribedRSSSources.count))
                    Spacer()
                    Button {
                        withAnimation { showRecommendations.toggle() }
                    } label: {
                        Text(showRecommendations ? "rss.hideRecommendations".localized : "rss.showRecommendations".localized)
                            .font(.caption)
                    }
                }
            } footer: {
                if !subscribedRSSSources.isEmpty {
                    Text("rss.subscribed.footer".localized)
                }
            }

            if !unsubscribedRSSSources.isEmpty {
                Section {
                    ForEach(unsubscribedRSSSources) { rss in
                        unsubscribedRSSSourceRow(rss)
                    }
                } header: {
                    Text(L10n.string("rss.unsubscribed", unsubscribedRSSSources.count))
                }
            }

            if showRecommendations {
                Section {
                    recommendationTestingPanel
                } header: {
                    Text("rss.recommendationValidation".localized)
                } footer: {
                    Text("rss.recommendationValidation.footer".localized)
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
                Text("rss.addSource".localized)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onDisappear {
            cancelRecommendationValidation(clearHandleOnly: true)
        }
        .confirmationDialog(
            "rss.delete.title".localized,
            isPresented: Binding(
                get: { pendingRSSDeletion != nil },
                set: { isPresented in
                    if !isPresented { pendingRSSDeletion = nil }
                }
            ),
            presenting: pendingRSSDeletion
        ) { rss in
            Button(L10n.string("rss.delete.confirm", rss.name), role: .destructive) {
                deleteRSSSource(rss)
            }
            Button("rss.delete.cancel".localized, role: .cancel) { }
        } message: { rss in
            Text(L10n.string("rss.delete.message", rss.name))
        }
    }

    private var emptySourcesView: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                EditorialSourceBadge(mark: .rss, fallbackTint: .secondary, size: 28)
                Text("rss.empty".localized)
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
                Text("rss.emptySubscribed".localized)
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
                    .accessibilityLabel(L10n.string("rss.switchToText", rss.name))
                    .help("rss.textMode".localized)

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
                    .accessibilityLabel(rss.supportsImage ? L10n.string("rss.switchToImage", rss.name) : L10n.string("rss.imageUnavailable", rss.name))
                    .help(rss.supportsImage ? "rss.imageMode".localized : "rss.noImages".localized)
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
                .accessibilityLabel(L10n.string("rss.moveUp", rss.name))
                .help("rss.up".localized)

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
                .accessibilityLabel(L10n.string("rss.moveDown", rss.name))
                .help("rss.down".localized)

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
        .accessibilityLabel(isSelected ? L10n.string("rss.unsubscribe", rss.name) : L10n.string("rss.subscribe", rss.name))
        .help(isSelected ? "rss.unsubscribe.short".localized : "rss.subscribe.short".localized)
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
                Button("rss.resetToGlobal".localized) {
                    resetRSSCountOverride(for: rss.id, mode: mode)
                }
            }
            .accessibilityLabel(L10n.string("rss.countAccessibility", rss.name, rssCountTitle(for: mode)))
            .accessibilityHint("rss.countHint".localized)
            .accessibilityAction(named: Text(L10n.string("rss.resetCount", rssCountTitle(for: mode)))) {
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
        case .text: return "rss.textFlow".localized
        case .image: return "rss.imageFlow".localized
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
        .accessibilityLabel(L10n.string("rss.delete", rss.name))
        .accessibilityHint("rss.deleteHint".localized)
        .help("rss.delete.short".localized)
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
            .accessibilityLabel(L10n.string("rss.dragReorder", rss.name))
            .accessibilityHint("rss.dragHint".localized)
            .help("rss.dragReorderShort".localized)
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
                Button("rss.add".localized) {
                    addRecommended(rec)
                }
                .font(.caption)
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .controlSize(.small)
                .accessibilityLabel(L10n.string("rss.addNamed", rec.name))
                .accessibilityHint("rss.addHint".localized)
            }
        }
    }

    private func addRecommended(_ rec: RSSRecommendation) {
        let sanitizedName = SecurityPolicies.sanitizeUserInput(rec.name)
        let sanitizedURL = SecurityPolicies.sanitizeUserInput(rec.url)

        guard !settings.rssSources.contains(where: { $0.url == sanitizedURL }) else {
            addWarning = "rss.alreadyExists".localized
            addError = nil
            return
        }

        switch SecurityPolicies.validateRSSURL(sanitizedURL) {
        case .blocked(let reason):
            addError = L10n.string("rss.blocked", localizedSecurityReason(reason))
            addWarning = nil
            return
        case .warning(let reason):
            addWarning = L10n.string("rss.warning", localizedSecurityReason(reason))
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
                    Button("rss.cancel".localized) {
                        cancelRecommendationValidation()
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)
                    .accessibilityLabel("rss.cancelValidation".localized)
                    .accessibilityHint("rss.cancelValidationHint".localized)
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
                    .accessibilityLabel("rss.validationProgress".localized)
                    .accessibilityValue("\(recommendationValidationCompletedCount) / \(recommendationValidationTotalCount)")
                    .accessibilityHint("rss.cancelValidationHint".localized)

                    HStack {
                        Text(L10n.string("rss.progress", recommendationValidationCompletedCount, recommendationValidationTotalCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(L10n.string("rss.current", recommendationValidationCurrentActiveName ?? "rss.waitingNext".localized))
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
                return "rss.testing".localized
            }
            return recommendationValidationSummary
        }
        if !recommendationValidationSummary.isEmpty {
            return recommendationValidationSummary
        }
        if unaddedRecommendations.isEmpty {
            return "rss.noTestable".localized
        }
        return "rss.testOnlyUnadded".localized
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
                title: "rss.added".localized,
                tint: .secondary,
                hint: "rss.addedHint".localized
            )
        }

        let isCurrentCandidate = recommendationValidationCandidates.contains { $0.url == rec.url }

        if recommendationValidationActiveURL == rec.url, isCurrentCandidate {
            return RecommendationValidationBadge(
                symbol: "clock.arrow.circlepath",
                title: "rss.testingBadge".localized,
                tint: .accentColor,
                hint: "rss.testingBadgeHint".localized
            )
        }

        guard let outcome = recommendationValidationResults[rec.url] else {
            return RecommendationValidationBadge(
                symbol: "circle",
                title: "rss.pending".localized,
                tint: .secondary,
                hint: "rss.pendingHint".localized
            )
        }

        switch outcome {
        case .blocked(let reason):
            return RecommendationValidationBadge(
                symbol: "shield.slash.fill",
                title: "rss.blockedBadge".localized,
                tint: .red,
                hint: L10n.string("rss.blockedBadgeHint", localizedSecurityReason(reason))
            )
        case .invalidURL:
            return RecommendationValidationBadge(
                symbol: "exclamationmark.triangle.fill",
                title: "rss.invalidURL".localized,
                tint: .orange,
                hint: "rss.invalidURLHint".localized
            )
        case .cancelled:
            return RecommendationValidationBadge(
                symbol: "pause.circle.fill",
                title: "rss.cancelled".localized,
                tint: .secondary,
                hint: "rss.cancelledHint".localized
            )
        case .networkError(let summary):
            return RecommendationValidationBadge(
                symbol: "wifi.exclamationmark",
                title: "rss.networkFailed".localized,
                tint: .orange,
                hint: L10n.string("rss.networkFailedHint", localizedNetworkSummary(summary))
            )
        case .notRSSFeed:
            return RecommendationValidationBadge(
                symbol: "doc.text.magnifyingglass",
                title: "rss.notRSS".localized,
                tint: .orange,
                hint: "rss.notRSSHint".localized
            )
        case .success(let itemCount):
            return RecommendationValidationBadge(
                symbol: "checkmark.circle.fill",
                title: "rss.passed".localized,
                tint: .green,
                hint: L10n.string("rss.passedHint", itemCount)
            )
        }
    }

    private func startRecommendationValidation() {
        guard recommendationValidationTask == nil else { return }

        let candidates = recommendationValidationPendingCandidates
        guard !candidates.isEmpty else {
            recommendationValidationSummary = hasRecommendationValidationHistory ? "rss.noRetryable".localized : "rss.noTestable".localized
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
        recommendationValidationSummary = isRetryRun ? L10n.string("rss.retrying", candidates.count) : L10n.string("rss.testingCount", candidates.count)

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
        recommendationValidationSummary = "rss.cancelledStop".localized
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
            recommendationValidationSummary = "rss.cancelledStop".localized
        } else {
            recommendationValidationSummary = L10n.string("rss.testingProgress", recommendationValidationCompletedCount, recommendationValidationTotalCount)
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
        if successCount > 0 { parts.append(L10n.string("rss.passedCount", successCount)) }
        if failedCount > 0 { parts.append(L10n.string("rss.failedCount", failedCount)) }

        let body = parts.isEmpty ? "rss.noResult".localized : parts.joined(separator: "，")

        if wasCancelled {
            if parts.isEmpty {
                return L10n.string("rss.cancelledResult", cancelledCount)
            }
            return L10n.string("rss.cancelledWithBody", body, cancelledCount)
        }

        let prefix = retryRun ? "rss.retryDone".localized : "rss.testDone".localized
        return "\(prefix)：\(body)"
    }

    private func recommendationName(for url: String?) -> String? {
        guard let url else { return nil }
        return RSSRecommendations.all.first(where: { $0.url == url })?.name
    }

    private func localizedSecurityReason(_ reason: String) -> String {
        switch reason {
        case "Invalid URL or scheme":
            return "rss.security.invalidURL".localized
        default:
            if reason.hasPrefix("Blocked host: ") {
                return L10n.string("rss.security.blockedHost", reason.replacingOccurrences(of: "Blocked host: ", with: ""))
            }
            if reason.hasPrefix("Private IP range: ") {
                return L10n.string("rss.security.privateIP", reason.replacingOccurrences(of: "Private IP range: ", with: ""))
            }
            return reason
        }
    }

    private func localizedNetworkSummary(_ summary: String) -> String {
        switch summary {
        case "Request timed out":
            return "rss.network.timedOut".localized
        case "Cannot connect to server":
            return "rss.network.cannotConnect".localized
        case "No internet connection":
            return "rss.network.noInternet".localized
        case "Server not found":
            return "rss.network.serverNotFound".localized
        case "Invalid server response":
            return "rss.network.invalidResponse".localized
        case "Server returned an error":
            return "rss.network.serverError".localized
        case "Feed parse failed":
            return "rss.network.parseFailed".localized
        case "Unexpected error":
            return "rss.network.unexpected".localized
        case "Network error":
            return "rss.network.generic".localized
        default:
            return summary
        }
    }

    private var addRSSForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("rss.sourceName".localized, text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("rss.url".localized, text: $newURL)
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
                        Text("rss.addAndValidate".localized)
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
            addError = "rss.needURL".localized
            return
        }

        var normalizedURL = sanitizedURL
        if URL(string: normalizedURL)?.scheme == nil {
            normalizedURL = "https://" + normalizedURL
        }
        normalizedURL = SecurityPolicies.canonicalRSSURL(normalizedURL)

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
                    addError = "rss.notValidFeed".localized
                }
            } catch {
                addError = "rss.cannotConnect".localized
            }
            isTesting = false
        }
    }
}
