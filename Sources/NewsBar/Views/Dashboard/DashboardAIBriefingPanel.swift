import SwiftUI

enum AISummaryPresentationPolicy {
    static func needsAutomaticGeneration(state: AISummaryState, enabled: Bool) -> Bool {
        guard enabled else { return false }
        switch state {
        case .idle, .error:
            return true
        case .noKey, .fetching, .summarizing, .done, .truncated:
            return false
        }
    }

    static func canRegenerate(enabled: Bool, isRefreshing: Bool, isCoolingDown: Bool) -> Bool {
        enabled && !isRefreshing && !isCoolingDown
    }
}

struct DashboardAIBriefingPanel: View {
    @Environment(AppSettings.self) private var settings
    let orchestrator: NewsOrchestrator

    var onConfigureAI: () -> Void

    @State private var selectedCategory: DashboardBriefingCategory = .trendOverview
    @State private var regenerationCooldownRemaining: TimeInterval = 0
    @State private var cachedParsedSummary: ParsedSummary?
    @State private var cachedParseKey = ""

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

        guard cachedParseKey == parseKey else { return nil }
        return cachedParsedSummary
    }

    /// Cheap identity for the parsed cache. The actual parse runs in a `.task`,
    /// not on every body evaluation.
    private var parseKey: String {
        let textLength: Int
        switch summaryState {
        case .done(let text), .truncated(let text):
            textLength = text.count
        default:
            textLength = 0
        }
        return "\(orchestrator.aiSummaryManifest?.id.uuidString ?? "-")-\(sharedSummaryItems.count)-\(textLength)"
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
        guard settings.aiSummaryEnabled else { return "dash.state.disabled".localized }
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
        VStack(alignment: .leading, spacing: 12) {
            header
            metaRow

            if !settings.aiSummaryEnabled {
                emptyState(message: cardStateText, systemImage: "sparkles", actionTitle: "dash.openSettings".localized) {
                    onConfigureAI()
                }
            } else {
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
                    if case .truncated = summaryState {
                        HStack(spacing: 8) {
                            Label("aiCard.maybeIncomplete".localized, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer(minLength: 0)
                            retryButton
                        }
                    }
                    if let updateError = orchestrator.aiSummaryUpdateError,
                       summaryState.completedText != nil {
                        Label(updateError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
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
        }
        .onChange(of: summarySignature) { _, _ in
            if selectedSections.isEmpty {
                selectedCategory = preferredCategory
            }
        }
        .task(id: parseKey) {
            guard hasCitationSnapshot else {
                cachedParsedSummary = nil
                cachedParseKey = parseKey
                return
            }
            if let parsed = orchestrator.aiParsedSummary {
                cachedParsedSummary = parsed
                cachedParseKey = parseKey
                return
            }
            guard let text = resolvedSummaryText else {
                cachedParsedSummary = nil
                cachedParseKey = parseKey
                return
            }
            let key = parseKey
            let trendIndices = orchestrator.aiSummaryManifest?.trendIndices
                ?? Set(sharedSummaryItems.enumerated().filter { $0.element.source.isBuiltIn }.map(\.offset))
            let parsed = AISummaryParser.parseDualSummary(
                text,
                itemCount: sharedSummaryItems.count,
                trendIndices: trendIndices
            )
            guard !Task.isCancelled else { return }
            cachedParsedSummary = parsed
            cachedParseKey = key
        }
        .task(id: sharedSummaryNeedsGeneration) {
            // Cache first: folding the disk cache in can turn this task off
            // before it ever asks for a paid generation.
            await orchestrator.loadCached(settings: settings)
            guard !Task.isCancelled, sharedSummaryNeedsGeneration else { return }
            // Keep the first frame free of keychain reads, hashing and network.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, sharedSummaryNeedsGeneration else { return }
            await orchestrator.generateSharedSummaryIfNeeded(settings: settings)
        }
        .task(id: AISummaryService.manualRegenerationCooldown.lastRegeneration) {
            await AISummaryCooldownTicker.run(
                remaining: { AISummaryService.regenerationCooldownRemaining() },
                update: { regenerationCooldownRemaining = $0 }
            )
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
                        if parsedSummary?.isLegacyFallback == true {
                            EditorialTag(text: "dash.compatFormat".localized, fallbackTint: .secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        briefingTitle
                        if parsedSummary?.isLegacyFallback == true {
                            EditorialTag(text: "dash.compatFormat".localized, fallbackTint: .secondary)
                        }
                    }
                }
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
            .disabled(!canRegenerate)
            .help("dash.refresh".localized)
            .accessibilityLabel("dash.refresh".localized)
        }
    }

    /// The single status line that replaced three separate rows: when this
    /// result was generated and how much local history it covers. The full
    /// qualification lives in the help text and the accessibility hint.
    @ViewBuilder
    private var metaRow: some View {
        if settings.aiSummaryEnabled, resolvedSummaryText != nil, let text = summaryMetaText {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .medium))
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .help(metaHelpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cardStateText)
            .accessibilityValue(text)
            .accessibilityHint(metaHelpText)
        }
    }

    private var summaryMetaText: String? {
        guard let generatedAt = orchestrator.aiSummaryGeneratedAt ?? orchestrator.aiSummaryManifest?.asOf else {
            return nil
        }
        let language = settings.appLanguage
        var parts = [
            L10n.string(
                "dash.meta.generated",
                language: language,
                Self.metaTimeText(generatedAt, language: language)
            )
        ]
        if let manifest = orchestrator.aiSummaryManifest {
            let span = manifest.asOf.timeIntervalSince(manifest.coverageStart)
            // A fresh archive has almost no history: "covering 0 minutes" is
            // noise, and calling it incremental would overstate the collection.
            if span >= 5 * 60 {
                if span < 3600 {
                    parts.append(L10n.string(
                        "dash.meta.coverageMinutes",
                        language: language,
                        max(1, Int((span / 60).rounded()))
                    ))
                } else {
                    parts.append(L10n.string(
                        "dash.meta.coverageHours",
                        language: language,
                        max(1, Int((span / 3600).rounded()))
                    ))
                }
            }
        }
        // The truncation warning lives at the bottom of the card; repeat it
        // here so the state is visible without scrolling.
        if case .truncated = summaryState {
            parts.append(L10n.string("dash.meta.partial", language: language))
        }
        return parts.joined(separator: " · ")
    }

    private var metaHelpText: String {
        let language = settings.appLanguage
        let base = L10n.string("dash.meta.help", language: language)
        guard orchestrator.aiSummaryRestoredAt != nil else { return base }
        return L10n.string("dash.meta.restored", language: language) + " " + base
    }

    private static func metaTimeText(_ date: Date, language: AppLanguage) -> String {
        let locale = Locale(identifier: language.bcp47)
        let time = date.formatted(.dateTime.hour().minute().locale(locale))
        if Calendar.current.isDateInToday(date) { return time }
        if Calendar.current.isDateInYesterday(date) {
            return L10n.string("dash.meta.yesterday", language: language, time)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
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
            Picker(L10n.string("dash.briefing", language: settings.appLanguage), selection: $selectedCategory) {
                Text(L10n.string("dash.trendOverview", trendSections.count))
                    .tag(DashboardBriefingCategory.trendOverview)
                Text(L10n.string("dash.dailyEssentials", dailySections.count))
                    .tag(DashboardBriefingCategory.dailyEssentials)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
                            },
                            contextID: orchestrator.aiSummaryManifest?.id.uuidString
                        )

                        if index < selectedSections.count - 1 {
                            Divider().opacity(0.3)
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

            HStack(spacing: 8) {
                retryButton
                Button("dash.openSettings".localized) {
                    onConfigureAI()
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
            }
        }
    }

    private var retryButton: some View {
        Button("aiCard.regenerate".localized) {
            Task { await orchestrator.regenerateAISummary(settings: settings) }
        }
        .buttonStyle(EditorialActionButtonStyle(compact: true))
        .controlSize(.small)
        .disabled(!canRegenerate)
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

    private var sharedSummaryNeedsGeneration: Bool {
        !orchestrator.isSummaryQuotaBlockedForToday
            && AISummaryPresentationPolicy.needsAutomaticGeneration(
                state: summaryState,
                enabled: settings.aiSummaryEnabled
            )
    }

    private var canRegenerate: Bool {
        AISummaryPresentationPolicy.canRegenerate(
            enabled: settings.aiSummaryEnabled,
            isRefreshing: isSummaryRefreshing,
            isCoolingDown: regenerationCooldownRemaining > 0
        )
    }

    private var isSummaryRefreshing: Bool {
        summaryState == .fetching || summaryState == .summarizing || orchestrator.aiSummaryUpdating
    }
}

private enum DashboardBriefingCategory: String, CaseIterable, Hashable {
    case trendOverview
    case dailyEssentials
}
