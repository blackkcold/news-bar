import SwiftUI

struct AISummaryCard: View {
    let state: AISummaryState
    @Binding var isExpanded: Bool
    var allItems: [NewsItem] = []
    var parsedSummary: ParsedSummary?
    var maxSectionsPerCategory: Int?
    var isRegenerating = false
    var onRegenerate: (() -> Void)?
    var onConfigureKey: (() -> Void)?
    var contextID: String? = nil

    @State private var renderModel: SummaryRenderModel?
    @State private var revealedSectionCount = 0
    @State private var revealTask: Task<Void, Never>?
    @State private var regenerationCooldownRemaining: TimeInterval = 0
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var groupRuleColor: Color {
        settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : .purple
    }

    private enum Metrics {
        static let cardPadding: CGFloat = 10
        static let headerSpacing: CGFloat = 8
        static let headerIconSize: CGFloat = 24
        static let headerIconCornerRadius: CGFloat = 9
        static let headerTitleSize: CGFloat = 13
        static let helperTextSize: CGFloat = 10
        static let contentHorizontalPadding: CGFloat = 10
        static let contentVerticalPadding: CGFloat = 3
        static let rowVerticalPadding: CGFloat = 7
        static let badgeFontSize: CGFloat = 9
        static let chevronSize: CGFloat = 8
        static let sectionRevealInterval: Duration = .milliseconds(60)
        static let sectionRevealAnimation: TimeInterval = 0.2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerButton

            if isExpanded {
                Divider()
                    .padding(.leading, 32)
                    .padding(.trailing, Metrics.cardPadding)

                contentArea
            }
        }
        .padding(Metrics.cardPadding)
        .newsCardSurface(rotation: 0.12)
        .onAppear {
            syncRenderModel(animated: false)
        }
        .onChange(of: state) { _, _ in
            syncRenderModel(animated: true)
        }
        .onDisappear {
            revealTask?.cancel()
            revealTask = nil
        }
        .task(id: isRegenerating) {
            // Keep the manual-regeneration cooldown ticking every second so the
            // button un-disables promptly instead of getting stuck.
            while regenerationCooldownRemaining > 0 || AISummaryService.regenerationCooldownRemaining() > 0 {
                regenerationCooldownRemaining = AISummaryService.regenerationCooldownRemaining()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            regenerationCooldownRemaining = 0
        }
    }

    // MARK: - Header

    private var headerButton: some View {
        Button {
            toggleExpansion()
        } label: {
            HStack(alignment: .center, spacing: Metrics.headerSpacing) {
                EditorialSymbolBadge(
                    symbol: "text.bubble.fill",
                    fallbackTint: .purple,
                    size: Metrics.headerIconSize,
                    rotation: 1.5
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("aiCard.title".localized)
                            .editorialHeading(size: Metrics.headerTitleSize)
                            .foregroundStyle(.primary)

                        stateHeaderBadge
                    }

                    Text("aiCard.subtitle".localized)
                        .font(.system(size: Metrics.helperTextSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: Metrics.chevronSize, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "aiCard.collapseHint".localized : "aiCard.expandHint".localized)
    }

    @ViewBuilder
    private var stateHeaderBadge: some View {
        switch state {
        case .noKey:
            EditorialTag(text: "aiCard.noKey".localized, fallbackTint: .orange)
        case .fetching:
            EditorialTag(text: "aiCard.fetching".localized, fallbackTint: .blue)
        case .summarizing:
            EditorialTag(text: "aiCard.summarizing".localized, fallbackTint: .purple)
        case .error:
            EditorialTag(text: "aiCard.failed".localized, fallbackTint: .red)
        case .done:
            EditorialTag(text: "aiCard.done".localized, fallbackTint: .green)
        case .truncated:
            EditorialTag(text: "aiCard.truncated".localized, fallbackTint: .orange)
        case .idle:
            EditorialTag(text: "aiCard.idle".localized, fallbackTint: .secondary)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .noKey:
                noKeyContent
            case .fetching:
                statusContent(message: "aiCard.fetchingData".localized)
            case .summarizing:
                statusContent(message: "aiCard.thinking".localized)
            case .done, .truncated:
                summaryContent
            case .error(let msg):
                errorContent(msg)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, Metrics.contentHorizontalPadding)
        .padding(.vertical, Metrics.contentVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noKeyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("aiCard.noKeyTitle".localized)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            Text("aiCard.noKeyBody".localized)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if let onConfigureKey {
                Button {
                    onConfigureKey()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 9))
                        Text("aiCard.configureKey".localized)
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .controlSize(.small)
                .tint(.orange)
            }
        }
    }

    private func statusContent(message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.64)
                .frame(width: 14, height: 14)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let model = renderModel {
                if model.groups.isEmpty {
                    Text(model.fallbackAttributed)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                } else {
                    sectionList(model)
                }
            }

            if case .truncated = state {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("aiCard.maybeIncomplete".localized)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Spacer()
                    if let onRegenerate {
                        regenerateButton(action: onRegenerate)
                    }
                }
            }

            if case .done = state, let onRegenerate {
                Divider().padding(.top, 4)
                HStack {
                    Spacer()
                    regenerateButton(action: onRegenerate)
                }
            }
        }
    }

    // MARK: - Section Rendering

    @ViewBuilder
    private func sectionList(_ model: SummaryRenderModel) -> some View {
        ForEach(Array(model.groups.enumerated()), id: \.offset) { groupIndex, group in
            if !group.sections.isEmpty {
                if !group.title.isEmpty,
                   let firstSection = group.sections.first,
                   firstSection.order < revealedSectionCount {
                    VStack(alignment: .leading, spacing: 4) {
                        if groupIndex > 0 {
                            Rectangle()
                                .fill(groupRuleColor.opacity(0.3))
                                .frame(height: 1)
                        }
                        Text(group.title)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.35)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, groupIndex == 0 ? 2 : 6)
                    .padding(.bottom, 2)
                }

                ForEach(group.sections) { section in
                    if section.order < revealedSectionCount {
                        SectionRow(
                            title: section.title,
                            content: section.body,
                            attributedContent: section.attributedBody,
                            accessibilityText: section.accessibilityText,
                            matchedItem: section.primaryIndex.flatMap {
                                allItems.indices.contains($0) ? allItems[$0] : nil
                            },
                            contextID: contextID
                        )
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    }

                    // Reveal the rule with its section. Drawing it up front
                    // left bare dividers floating before any text arrived.
                    if section.order < revealedSectionCount,
                       section.order < (group.sections.last?.order ?? 0) {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    // MARK: - Render model

    private struct SummaryRenderModel {
        struct Section: Identifiable {
            let id: Int
            let order: Int
            let title: String
            let body: String
            let attributedBody: AttributedString
            let accessibilityText: String
            let primaryIndex: Int?
        }

        struct Group: Identifiable {
            let id: Int
            let title: String
            let sections: [Section]
        }

        let groups: [Group]
        let fallbackAttributed: AttributedString

        var sectionCount: Int {
            groups.reduce(0) { $0 + $1.sections.count }
        }
    }

    @MainActor
    private func syncRenderModel(animated: Bool) {
        switch state {
        case .done(let text), .truncated(let text):
            let model = makeRenderModel(for: text)
            renderModel = model
            revealTask?.cancel()
            revealTask = nil

            guard animated, !reduceMotion, model.sectionCount > 0 else {
                revealedSectionCount = model.sectionCount
                return
            }

            revealedSectionCount = 0
            let total = model.sectionCount
            revealTask = Task { @MainActor in
                for index in 1...total {
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: Metrics.sectionRevealAnimation)) {
                        revealedSectionCount = index
                    }
                    try? await Task.sleep(for: Metrics.sectionRevealInterval)
                }
            }
        default:
            revealTask?.cancel()
            revealTask = nil
            renderModel = nil
            revealedSectionCount = 0
        }
    }

    private func makeRenderModel(for fullText: String) -> SummaryRenderModel {
        let resolved = resolvedSectionGroups(for: fullText)
        var order = 0
        var groups: [SummaryRenderModel.Group] = []

        for (groupIndex, group) in resolved.enumerated() {
            var sections: [SummaryRenderModel.Section] = []
            for section in group.sections {
                let plainBody = AISummaryParser.stripMarkdown(section.body)
                let attributed = Self.attributed(section.body)
                let stripped = AISummaryParser.stripCitations(plainBody)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedTitle = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let accessibilityText: String
                if normalizedTitle.isEmpty {
                    accessibilityText = stripped
                } else if stripped.isEmpty {
                    accessibilityText = normalizedTitle
                } else {
                    accessibilityText = "\(normalizedTitle)。\(stripped)"
                }

                sections.append(SummaryRenderModel.Section(
                    id: order,
                    order: order,
                    title: section.title,
                    body: section.body,
                    attributedBody: attributed,
                    accessibilityText: accessibilityText,
                    primaryIndex: section.primaryIndex
                ))
                order += 1
            }
            if !sections.isEmpty {
                groups.append(SummaryRenderModel.Group(
                    id: groupIndex,
                    title: group.title,
                    sections: sections
                ))
            }
        }

        let fallback = Self.attributed(AISummaryParser.stripCitations(fullText))
        return SummaryRenderModel(groups: groups, fallbackAttributed: fallback)
    }

    private func resolvedSectionGroups(for fullText: String) -> [(title: String, sections: [(title: String, body: String, primaryIndex: Int?)])] {
        if let parsedSummary {
            let visibleSummary = AISummaryParser.limited(
                parsedSummary,
                maxSectionsPerCategory: maxSectionsPerCategory
            )
            return [
                (title: "aiCard.trendOverview".localized, sections: visibleSummary.trendOverview),
                (title: "aiCard.dailyEssentials".localized, sections: visibleSummary.dailyEssentials)
            ].filter { !$0.sections.isEmpty }
        }

        return [(title: "", sections: AISummaryParser.parseSections(fullText, itemCount: allItems.count))]
    }

    private static func attributed(_ text: String) -> AttributedString {
        if let parsed = try? AttributedString(markdown: text) {
            return parsed
        }
        return AttributedString(text)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let onRegenerate {
                regenerateButton(action: onRegenerate)
            }
        }
    }

    private func regenerateButton(action: @escaping () -> Void) -> some View {
        let cooldownSeconds = Int(ceil(regenerationCooldownRemaining))
        let isCoolingDown = cooldownSeconds > 0

        return Button {
            guard !isRegenerating, !isCoolingDown else { return }
            action()
        } label: {
            HStack(spacing: 4) {
                if isRegenerating {
                    ProgressView()
                        .scaleEffect(0.56)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                }
                Text(regenerateButtonTitle(cooldownSeconds: cooldownSeconds))
                    .font(.system(size: 9.5))
            }
        }
        .buttonStyle(EditorialActionButtonStyle(compact: true))
        .controlSize(.small)
        .disabled(isRegenerating || isCoolingDown)
        .accessibilityLabel(regenerateButtonTitle(cooldownSeconds: cooldownSeconds))
        .accessibilityHint(isCoolingDown ? "aiCard.cooldownHint".localized : "aiCard.regenerateHint".localized)
    }

    private func regenerateButtonTitle(cooldownSeconds: Int) -> String {
        if isRegenerating { return "aiCard.regenerating".localized }
        if cooldownSeconds > 0 { return L10n.string("aiCard.cooldown", cooldownSeconds) }
        return "aiCard.regenerate".localized
    }

    private func toggleExpansion() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
}

// MARK: - Section Row

struct SectionRow: View {
    let title: String
    let content: String
    var attributedContent: AttributedString? = nil
    var accessibilityText: String? = nil
    var useMarkdown: Bool = true
    let matchedItem: NewsItem?
    var contextID: String? = nil

    @State private var isHovered = false
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    private var accessibilityLabelText: String {
        if let accessibilityText { return accessibilityText }
        let stripped = AISummaryParser.stripCitations(content)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTitle.isEmpty { return stripped }
        if stripped.isEmpty { return normalizedTitle }
        return "\(normalizedTitle)。\(stripped)"
    }

    private var accessibilityHintText: String {
        if matchedItem != nil {
            return "aiCard.sourceHint".localized
        }
        return "aiCard.readonly".localized
    }

    /// Parse markdown only once per row; the summary card supplies a
    /// pre-attributed body when it has one.
    private var bodyText: AttributedString {
        if let attributedContent { return attributedContent }
        if useMarkdown, let attributed = try? AttributedString(markdown: content) {
            return attributed
        }
        return AttributedString(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .accessibilityHidden(true)

                    Spacer(minLength: 6)

                    if let item = matchedItem {
                        SourceBadge(sourceName: item.source.displayName, url: item.url, item: item, contextID: contextID)
                    }
                }
            } else if let item = matchedItem {
                HStack {
                    Spacer(minLength: 0)
                    SourceBadge(sourceName: item.source.displayName, url: item.url, item: item, contextID: contextID)
                }
            }

            Text(bodyText)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .accessibilityLabel(accessibilityLabelText)
                .accessibilityValue(matchedItem?.source.displayName ?? "aiCard.noSource".localized)
                .accessibilityHint(accessibilityHintText)
        }
        .padding(.vertical, Metrics.rowVerticalPadding)
        .background(rowBackground)
        .overlay(rowStroke)
        .clipShape(rowShape)
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isHovered = hovering
                }
            }
        }
    }

    private enum Metrics {
        static let rowVerticalPadding: CGFloat = 9
    }

    private var rowShape: AnyShape {
        isRetro
            ? AnyShape(Rectangle())
            : AnyShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var rowBackground: some View {
        rowShape.fill(isHovered ? Color.purple.opacity(0.05) : Color.clear)
    }

    private var rowStroke: some View {
        rowShape.stroke(rowStrokeStyle, lineWidth: 1)
    }

    private var rowStrokeStyle: AnyShapeStyle {
        isHovered ? AnyShapeStyle(Color.purple.opacity(0.16)) : AnyShapeStyle(.separator.opacity(0.08))
    }
}

// MARK: - Source Badge

private struct SourceBadge: View {
    let sourceName: String
    let url: String
    let item: NewsItem
    let contextID: String?

    @State private var isBadgeHovered = false
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        Button {
            NewsNavigationRouter.shared.open(item, surface: "summaryCitation", contextID: contextID)
        } label: {
            HStack(spacing: 3) {
                EditorialSourceBadge(
                    mark: sourceMark,
                    fallbackTint: sourceTint,
                    size: 16
                )
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 7, weight: .bold))
                Text(sourceName)
                    .font(.system(size: 8.5, weight: isRetro ? .black : .medium, design: isRetro ? .serif : .default))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial)
            .editorialClipShape(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("aiCard.openSource", sourceName))
        .accessibilityHint("aiCard.openInBrowser".localized)
        .scaleEffect(reduceMotion ? 1.0 : (isBadgeHovered ? 1.08 : 1.0))
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: isBadgeHovered)
        .onHover { isBadgeHovered = $0 }
    }

    private var sourceMark: EditorialSourceMark {
        if sourceName.contains("微博") { return .weibo }
        if sourceName.contains("B站") || sourceName.lowercased().contains("bilibili") { return .bilibili }
        return .rss
    }

    private var sourceTint: Color {
        switch sourceMark {
        case .weibo: return .orange
        case .bilibili: return .pink
        case .rss: return .blue
        }
    }
}
