import SwiftUI

struct DashboardAIBriefingPanel: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator

    var onConfigureAI: () -> Void

    @State private var selectedCategory: DashboardBriefingCategory = .trendOverview
    @State private var regenerationCooldownRemaining: TimeInterval = 0

    private var summaryState: AISummaryState {
        orchestrator.aiSummaryState
    }

    private var sharedSummaryItems: [NewsItem] {
        orchestrator.aiSummaryItems
    }

    private var resolvedSummaryText: String? {
        switch summaryState {
        case .done(let text), .truncated(let text):
            return text
        default:
            return nil
        }
    }

    private var parsedSummary: ParsedSummary? {
        guard hasCitationSnapshot else { return nil }

        if let parsed = orchestrator.aiParsedSummary {
            return parsed
        }

        guard let text = resolvedSummaryText else { return nil }
        return AISummaryParser.parseDualSummary(
            text,
            itemCount: sharedSummaryItems.count,
            weiboBilibiliRange: 0..<(orchestrator.weiboItems.count + orchestrator.bilibiliItems.count)
        )
    }

    private var trendSections: [(title: String, body: String, primaryIndex: Int?)] {
        parsedSummary?.trendOverview ?? []
    }

    private var dailySections: [(title: String, body: String, primaryIndex: Int?)] {
        parsedSummary?.dailyEssentials ?? []
    }

    private var selectedSections: [(title: String, body: String, primaryIndex: Int?)] {
        switch selectedCategory {
        case .trendOverview:
            return trendSections
        case .dailyEssentials:
            return dailySections
        }
    }

    private var preferredCategory: DashboardBriefingCategory {
        if !trendSections.isEmpty { return .trendOverview }
        if !dailySections.isEmpty { return .dailyEssentials }
        return .trendOverview
    }

    private var summarySignature: String {
        "\(trendSections.count)-\(dailySections.count)-\(parsedSummary?.isLegacyFallback == true)"
    }

    private var summaryItems: [NewsItem] {
        sharedSummaryItems
    }

    private var hasCitationSnapshot: Bool {
        !summaryItems.isEmpty
    }

    private var cardStateText: String {
        switch summaryState {
        case .idle: return "dash.state.idle".localized
        case .noKey: return "dash.state.noKey".localized
        case .fetching: return "dash.state.fetching".localized
        case .summarizing: return "dash.state.summarizing".localized
        case .done: return "dash.state.done".localized
        case .truncated: return "dash.state.truncated".localized
        case .error: return "dash.state.error".localized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch summaryState {
            case .idle:
                emptyState(message: cardStateText, systemImage: "sparkles")
            case .noKey:
                emptyState(message: cardStateText, systemImage: "key.fill", actionTitle: "dash.configureKey".localized) {
                    onConfigureAI()
                }
            case .fetching:
                loadingState(message: cardStateText)
            case .summarizing:
                loadingState(message: cardStateText)
            case .error(let message):
                errorState(message: message)
            case .done, .truncated:
                if hasCitationSnapshot, let parsedSummary {
                    briefingContent(parsedSummary: parsedSummary)
                } else if let text = resolvedSummaryText {
                    fallbackSummary(
                        text,
                        note: hasCitationSnapshot
                            ? nil
                            : "dash.fallbackNote".localized
                    )
                } else {
                    emptyState(message: "dash.noBriefing".localized, systemImage: "sparkles")
                }
            }
        }
        .padding(16)
        .newsCardSurface(rotation: 0.14)
        .accessibilityElement(children: .contain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if selectedSections.isEmpty {
                selectedCategory = preferredCategory
            }
            requestSharedSummaryIfNeeded()
        }
        .onChange(of: summarySignature) { _, _ in
            if selectedSections.isEmpty {
                selectedCategory = preferredCategory
            }
        }
        .task(id: isSummaryRefreshing) {
            // Keep the manual-regeneration cooldown ticking so the refresh
            // button un-disables promptly instead of getting stuck.
            while regenerationCooldownRemaining > 0 || AISummaryService.regenerationCooldownRemaining() > 0 {
                regenerationCooldownRemaining = AISummaryService.regenerationCooldownRemaining()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            regenerationCooldownRemaining = 0
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            EditorialSymbolBadge(
                symbol: "text.bubble.fill",
                fallbackTint: .purple,
                size: 30,
                rotation: 1.5
            )

            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        briefingTitle
                        EditorialTag(text: cardStateText, fallbackTint: stateTint)
                        if parsedSummary?.isLegacyFallback == true {
                            EditorialTag(text: "dash.compatFormat".localized, fallbackTint: .secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        briefingTitle
                        HStack(spacing: 5) {
                            EditorialTag(text: cardStateText, fallbackTint: stateTint)
                            if parsedSummary?.isLegacyFallback == true {
                                EditorialTag(text: "dash.compatFormat".localized, fallbackTint: .secondary)
                            }
                        }
                    }
                }

                Text("dash.briefing.subtitle".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Button {
                Task {
                    await orchestrator.regenerateAISummary(settings: settings)
                }
            } label: {
                if isSummaryRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .controlSize(.small)
            .disabled(isSummaryRefreshing || regenerationCooldownRemaining > 0)
            .help("dash.refresh".localized)
            .accessibilityLabel("dash.refresh".localized)
        }
    }

    private var briefingTitle: some View {
        Text("dash.briefing".localized)
            .editorialHeading(size: 14)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func briefingContent(parsedSummary: ParsedSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("AI Briefing 主题", selection: $selectedCategory) {
                Text(L10n.string("dash.trendOverview", trendSections.count))
                    .tag(DashboardBriefingCategory.trendOverview)
                Text(L10n.string("dash.dailyEssentials", dailySections.count))
                    .tag(DashboardBriefingCategory.dailyEssentials)
            }
            .pickerStyle(.segmented)

            if selectedSections.isEmpty {
                emptyCategoryState
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(selectedSections.enumerated()), id: \.offset) { index, section in
                        SectionRow(
                            title: section.title,
                            content: section.body,
                            matchedItem: section.primaryIndex.flatMap {
                                summaryItems.indices.contains($0) ? summaryItems[$0] : nil
                            }
                        )

                        if index < selectedSections.count - 1 {
                            Divider().opacity(0.3).padding(.horizontal, 4)
                        }
                    }
                }
            }

            if parsedSummary.isLegacyFallback {
                Text("dash.legacyNote".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fallbackSummary(_ text: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("dash.fallbackTitle".localized)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text((try? AttributedString(markdown: AISummaryParser.stripCitations(text)))
                ?? AttributedString(AISummaryParser.stripCitations(text)))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineSpacing(4)

            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadingState(message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func errorState(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button("dash.openSettings".localized) {
                onConfigureAI()
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .controlSize(.small)
        }
    }

    private func emptyState(message: String, systemImage: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                    .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                    .controlSize(.small)
            }
        }
    }

    private var emptyCategoryState: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("dash.emptyCategory".localized)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var stateTint: Color {
        switch summaryState {
        case .idle: return .secondary
        case .noKey: return .orange
        case .fetching: return .blue
        case .summarizing: return .purple
        case .done: return .green
        case .truncated: return .orange
        case .error: return .red
        }
    }

    private var sharedSummaryNeedsGeneration: Bool {
        switch summaryState {
        case .idle, .error, .truncated:
            return true
        default:
            return false
        }
    }

    private var isSummaryRefreshing: Bool {
        summaryState == .fetching || summaryState == .summarizing
    }

    private func requestSharedSummaryIfNeeded() {
        guard sharedSummaryNeedsGeneration else { return }
        Task {
            await orchestrator.generateSharedSummaryIfNeeded(settings: settings)
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var cardBackground: some View {
        cardShape.fill(.ultraThinMaterial)
    }

    private var cardStroke: some View {
        cardShape.strokeBorder(.separator.opacity(0.32), lineWidth: 1)
    }
}

private enum DashboardBriefingCategory: String, CaseIterable, Hashable {
    case trendOverview
    case dailyEssentials
}
