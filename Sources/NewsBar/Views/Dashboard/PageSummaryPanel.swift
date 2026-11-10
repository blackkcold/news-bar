import SwiftUI

/// Where the overview came from: the page open in the reader. Kept separate
/// from `PageSummaryInput` so the rail can show the page identity while the
/// body is still being extracted.
struct PageSummaryPanelContext: Equatable {
    let title: String
    let url: String?
    let isPrivate: Bool
    let language: AppLanguage
}

enum PageSummaryPanelPhase: Equatable {
    case preparing
    case disclosure
    case readyToGenerate
    case generating
    case ready
    case failed(String)
    case unavailable(String)
}

/// Page overview content. The rail owns the width, material, padding and the
/// close control; this view only lays out the overview and its fixed footer.
/// Every state is passed in, so rendering tests can cover all of them without
/// a network request or an API key.
struct PageSummaryPanel: View {
    let context: PageSummaryPanelContext
    let phase: PageSummaryPanelPhase
    let input: PageSummaryInput?
    let summary: PageSummary?
    let errorMessage: String?
    let providerName: String
    var showsCloseButton = false
    var onGenerate: (Bool) -> Void = { _ in }
    var onGeneratePageOnly: () -> Void = {}
    var onCancelDisclosure: () -> Void = {}
    var onRetry: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onClose: () -> Void = {}
    var onOpenCitation: (PageSummaryCitation) -> Void = { _ in }
    var onOpenSource: (PageSummarySource) -> Void = { _ in }
    var onSwitchToReaderMode: (() -> Void)? = nil
    var thinking: AIThinkingLevel = .providerDefault
    var thinkingOptions: [AIThinkingLevel] = []
    var thinkingHint: String? = nil
    var onThinkingChange: (AIThinkingLevel) -> Void = { _ in }
    var webSupplement: Bool = true
    var onWebSupplementChange: (Bool) -> Void = { _ in }
    var stage: PageSummaryModel.Stage = .idle
    var assessmentEnabled: Bool = false

    private var isPrivate: Bool {
        context.isPrivate || input?.isPrivate == true
    }

    private var effectiveWebSupplement: Bool {
        webSupplement && !isPrivate
    }

    private var showsThinkingControl: Bool {
        switch phase {
        case .preparing, .unavailable: return false
        default: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let input {
                        basisLine(input)
                    }
                    content
                }
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("reader.overview.title", language: context.language))
                    .font(.headline)
                if !context.title.isEmpty {
                    Text(context.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let host = context.url.flatMap(URL.init(string:))?.host {
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if context.isPrivate {
                Label(
                    L10n.string("reader.overview.private", language: context.language),
                    systemImage: "hand.raised.fill"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize()
            }

            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.string("reader.overview.close", language: context.language))
                .help(L10n.string("reader.overview.close", language: context.language))
            }
        }
    }

    // MARK: - Basis

    private func basisLine(_ input: PageSummaryInput) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: basisIcon(input))
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                Text(basisText(input))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)

            let notes = (summary?.retrieval?.notes ?? []).filter { note in
                if summary?.basis == .searchUnavailable, note == .searchUnavailable {
                    // The basis line already says the web check failed.
                    return false
                }
                return true
            }
            if !notes.isEmpty {
                ForEach(notes.indices, id: \.self) { index in
                    Label(notes[index].message(context.language), systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func basisIcon(_ input: PageSummaryInput) -> String {
        guard let basis = summary?.basis else {
            return input.scope == .article ? "doc.text" : "list.bullet"
        }
        switch basis {
        case .externalSupported, .externalLimited, .searchUnavailable:
            return "globe"
        case .pageOnly:
            return "doc.text"
        case .insufficientMaterial:
            return "tray"
        }
    }

    private func basisText(_ input: PageSummaryInput) -> String {
        if let basis = summary?.basis {
            let externalCount = adoptedExternalCount
            switch basis {
            case .externalSupported:
                return L10n.string(
                    "reader.overview.basis.external",
                    language: context.language,
                    externalCount
                )
            case .externalLimited:
                return L10n.string(
                    "reader.overview.basis.externalLimited",
                    language: context.language,
                    externalCount
                )
            case .pageOnly:
                return L10n.string("reader.overview.basis.pageOnly", language: context.language)
            case .searchUnavailable:
                return L10n.string(
                    "reader.overview.basis.searchUnavailable",
                    language: context.language
                )
            case .insufficientMaterial:
                return L10n.string(
                    "reader.overview.basis.insufficient",
                    language: context.language
                )
            }
        }

        if input.scope == .article {
            let characters = input.articleText?.count ?? 0
            let cap = PageSummaryService.maxArticleCharacters
            if characters > cap {
                return L10n.string(
                    "reader.overview.basis.truncated",
                    language: context.language,
                    cap,
                    characters
                )
            }
            return L10n.string(
                "reader.overview.basis.article",
                language: context.language,
                cap
            )
        }
        return L10n.string(
            "reader.overview.basis.list",
            language: context.language,
            input.listRows.count
        )
    }

    private var adoptedExternalCount: Int {
        if let sources = summary?.sources {
            return sources.filter { $0.kind == .external && $0.adopted }.count
        }
        return summary?.retrieval?.adoptedCount ?? 0
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            preparing
        case .unavailable(let message):
            unavailable(message)
        case .disclosure:
            disclosure
        case .readyToGenerate:
            readyToGenerate
        case .generating:
            VStack(alignment: .leading, spacing: 12) {
                if effectiveWebSupplement, stage != .idle {
                    stageRow
                }
                if let summary {
                    busyBanner
                    summaryContent(summary)
                } else {
                    loading
                }
            }
        case .ready:
            if let summary {
                summaryContent(summary)
            } else {
                loading
            }
        case .failed(let message):
            if let summary {
                VStack(alignment: .leading, spacing: 12) {
                    errorBanner(message)
                    summaryContent(summary)
                }
            } else {
                failureCard(message)
            }
        }
    }

    private var preparing: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(L10n.string("reader.overview.preparing", language: context.language))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
    }

    private func unavailable(_ message: String) -> some View {
        stateCard(
            symbol: "doc.text.magnifyingglass",
            message: message,
            detail: L10n.string("reader.overview.unavailable.detail", language: context.language)
        ) {
            HStack(spacing: 10) {
                Button(
                    L10n.string("reader.overview.retry", language: context.language),
                    action: onRetry
                )
                .buttonStyle(.borderedProminent)
                if let onSwitchToReaderMode {
                    Button(
                        L10n.string("reader.overview.readerMode", language: context.language),
                        action: onSwitchToReaderMode
                    )
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                L10n.string("reader.overview.disclosure.title", language: context.language),
                systemImage: "lock.shield"
            )
            .font(.callout.weight(.semibold))

            Text(L10n.string(
                "reader.overview.disclosure.body",
                language: context.language,
                PageSummaryService.maxArticleCharacters,
                providerName
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(L10n.string("reader.overview.disclosure.cache", language: context.language))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isPrivate {
                Text(L10n.string("reader.overview.disclosure.private", language: context.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                webSupplementToggle
                Text(L10n.string(
                    "reader.overview.disclosure.external",
                    language: context.language,
                    providerName
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(
                    L10n.string("reader.overview.generate", language: context.language)
                ) {
                    onGenerate(false)
                }
                .buttonStyle(.borderedProminent)

                if !isPrivate {
                    Button(
                        L10n.string("reader.overview.generatePageOnly", language: context.language),
                        action: onGeneratePageOnly
                    )
                    .buttonStyle(.borderless)
                }

                Button(
                    L10n.string("reader.overview.cancel", language: context.language),
                    action: onCancelDisclosure
                )
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.8)
        }
    }

    private var readyToGenerate: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.string(
                    "reader.overview.ready.body",
                    language: context.language,
                    providerName,
                    PageSummaryService.maxArticleCharacters
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            webSupplementToggle

            HStack(spacing: 10) {
                Button(
                    L10n.string("reader.overview.generate", language: context.language)
                ) {
                    onGenerate(false)
                }
                .buttonStyle(.borderedProminent)

                if !isPrivate {
                    Button(
                        L10n.string("reader.overview.generatePageOnly", language: context.language),
                        action: onGeneratePageOnly
                    )
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var webSupplementToggle: some View {
        if isPrivate {
            Label(
                L10n.string("reader.overview.external.private", language: context.language),
                systemImage: "hand.raised"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Toggle(
                L10n.string("reader.overview.external.toggle", language: context.language),
                isOn: Binding(
                    get: { webSupplement },
                    set: { onWebSupplementChange($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(L10n.string("reader.overview.loading", language: context.language))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private var busyBanner: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(L10n.string("reader.overview.busy", language: context.language))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Stage row

    private struct StageStep: Identifiable {
        let id: Int
        let title: String
    }

    private var stageSteps: [StageStep] {
        var steps: [StageStep] = []
        steps.append(StageStep(
            id: steps.count,
            title: L10n.string("reader.overview.stage.search", language: context.language)
        ))
        steps.append(StageStep(id: steps.count, title: stageReadTitle))
        if assessmentEnabled {
            steps.append(StageStep(
                id: steps.count,
                title: L10n.string("reader.overview.stage.assess", language: context.language)
            ))
        }
        steps.append(StageStep(
            id: steps.count,
            title: L10n.string("reader.overview.stage.summarize", language: context.language)
        ))
        return steps
    }

    private var stageReadTitle: String {
        if case .reading(let index, let total) = stage {
            return L10n.string(
                "reader.overview.stage.read",
                language: context.language,
                index,
                total
            )
        }
        return L10n.string("reader.overview.stage.readShort", language: context.language)
    }

    private var stageCurrentIndex: Int {
        switch stage {
        case .idle:
            return -1
        case .searchingExternal:
            return 0
        case .reading:
            return 1
        case .assessingExternal:
            return assessmentEnabled ? 2 : 1
        case .summarizing:
            return max(0, stageSteps.count - 1)
        }
    }

    private var stageRow: some View {
        HStack(spacing: 6) {
            ForEach(stageSteps) { step in
                HStack(spacing: 4) {
                    Circle()
                        .fill(stageColor(for: step.id))
                        .frame(width: 5, height: 5)
                    Text(step.title)
                        .font(.caption2)
                        .foregroundStyle(step.id == stageCurrentIndex ? Color.primary : Color.secondary)
                }
                if step.id != stageSteps.last?.id {
                    Text("›")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func stageColor(for index: Int) -> Color {
        if index == stageCurrentIndex { return .accentColor }
        if index < stageCurrentIndex { return .secondary }
        return Color.secondary.opacity(0.3)
    }

    // MARK: - Errors

    private func errorBanner(_ message: String) -> some View {
        Label(
            L10n.string(
                "reader.overview.error.previous",
                language: context.language,
                message
            ),
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func failureCard(_ message: String) -> some View {
        stateCard(
            symbol: "exclamationmark.triangle.fill",
            message: message,
            detail: L10n.string("reader.overview.failure.detail", language: context.language)
        ) {
            HStack(spacing: 10) {
                Button(
                    L10n.string("reader.overview.retry", language: context.language),
                    action: onRetry
                )
                .buttonStyle(.borderedProminent)
                Button(
                    L10n.string("reader.overview.aiSettings", language: context.language),
                    action: onOpenSettings
                )
                .buttonStyle(.borderless)
            }
        }
    }

    private func stateCard<Actions: View>(
        symbol: String,
        message: String,
        detail: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Summary

    private func summaryContent(_ summary: PageSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let errorMessage, phase != .generating {
                errorBanner(errorMessage)
            }

            Text(summary.oneLine)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(summary.points.enumerated()), id: \.element.id) { index, point in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 12, alignment: .trailing)
                            .padding(.top, 2)
                        Text(point.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let citation = point.citationIndex,
                           let source = summary.citations.first(where: { $0.index == citation }) {
                            Button("#\(citation)") { onOpenCitation(source) }
                                .font(.caption2.weight(.semibold))
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.accentColor)
                                .help(source.item.displayTitle)
                        }
                        ForEach(point.resolvedCitationIndices, id: \.self) { number in
                            if let source = summary.sources?.first(where: { $0.index == number }) {
                                citationChip(source)
                            }
                        }
                    }
                }
            }

            if let sources = summary.sources, !sources.isEmpty {
                sourceSection(sources)
            } else if !summary.citations.isEmpty {
                citationSection(summary.citations)
            }
        }
    }

    @ViewBuilder
    private func citationChip(_ source: PageSummarySource) -> some View {
        if source.kind == .currentPage {
            Text("[\(source.index)]")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .help(L10n.string("reader.overview.sources.currentPage", language: context.language))
        } else {
            Button("[\(source.index)]") {
                onOpenSource(source)
            }
            .font(.caption2.monospacedDigit().weight(.semibold))
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .help(source.title)
        }
    }

    private func sourceSection(_ sources: [PageSummarySource]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(L10n.string("reader.overview.sources.all", language: context.language))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(sources) { source in
                sourceRow(source)
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: PageSummarySource) -> some View {
        let clickable = source.kind == .external && !source.url.isEmpty
        if clickable {
            Button {
                onOpenSource(source)
            } label: {
                sourceRowContent(source, clickable: true)
            }
            .buttonStyle(.plain)
            .help(sourceHelp(source))
        } else {
            sourceRowContent(source, clickable: false)
                .help(sourceHelp(source))
        }
    }

    private func sourceRowContent(
        _ source: PageSummarySource,
        clickable: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text("[\(source.index)]")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(source.adopted ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title.isEmpty ? source.host : source.title)
                    .font(.caption)
                    .lineLimit(1)
                if let metadata = sourceMetadata(source) {
                    Text(metadata)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if clickable {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .opacity(source.adopted ? 1 : 0.55)
    }

    private func sourceMetadata(_ source: PageSummarySource) -> String? {
        var parts: [String] = []
        if source.kind == .currentPage {
            parts.append(
                L10n.string("reader.overview.sources.currentPage", language: context.language)
            )
        } else {
            if !source.host.isEmpty { parts.append(source.host) }
            if let date = source.publishedAt {
                parts.append(date.formatted(.dateTime.year().month().day()))
            }
            if let type = source.type, type != .unknown {
                parts.append(L10n.string(
                    "answer.source.type.\(type.rawValue)",
                    language: context.language
                ))
            }
            if let adoption = source.adoption {
                parts.append(L10n.string(
                    "answer.source.adoption.\(adoption.rawValue)",
                    language: context.language
                ))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sourceHelp(_ source: PageSummarySource) -> String {
        var parts: [String] = []
        if !source.url.isEmpty { parts.append(source.url) }
        if let reason = source.reason {
            parts.append(L10n.string(
                "answer.source.reason.\(reason.rawValue)",
                language: context.language
            ))
        }
        return parts.joined(separator: "\n")
    }

    private func citationSection(_ citations: [PageSummaryCitation]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(L10n.string("reader.overview.sources", language: context.language))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(citations) { citation in
                Button {
                    onOpenCitation(citation)
                } label: {
                    HStack(spacing: 6) {
                        Text("#\(citation.index)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(citation.item.displayTitle)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Footer

    private func retrievalLine(_ summary: PageSummary) -> String {
        if summary.basis == .searchUnavailable {
            return L10n.string("reader.overview.searchFailed", language: context.language)
        }
        if summary.sources?.contains(where: { $0.kind == .external }) == true {
            return L10n.string(
                "reader.overview.retrievedAt",
                language: context.language,
                summary.generatedAt.formatted(.dateTime.hour().minute())
            )
        }
        return L10n.string("reader.overview.notSearched", language: context.language)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                if let summary {
                    Text(L10n.string(
                        "reader.overview.footer.meta",
                        language: context.language,
                        summary.providerName,
                        summary.model,
                        summary.inputCharacters
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    if summary.wasTruncated {
                        Text(L10n.string("reader.overview.footer.truncated", language: context.language))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(L10n.string("reader.overview.footer.nothingSent", language: context.language))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                if let summary,
                   phase != .generating,
                   summary.sources?.contains(where: { $0.kind == .external }) == true {
                    Button(action: onGeneratePageOnly) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string(
                        "reader.overview.generatePageOnly",
                        language: context.language
                    ))
                    .accessibilityLabel(L10n.string(
                        "reader.overview.generatePageOnly",
                        language: context.language
                    ))
                }

                if summary != nil {
                    Button {
                        onGenerate(true)
                    } label: {
                        Label(
                            phase == .generating
                                ? L10n.string("reader.overview.generating", language: context.language)
                                : L10n.string("reader.overview.regenerate", language: context.language),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(phase == .generating)
                }
            }

            if let summary, phase != .generating {
                Text(retrievalLine(summary))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !thinkingOptions.isEmpty, showsThinkingControl {
                HStack(spacing: 8) {
                    Text(L10n.string("reader.overview.thinking", language: context.language))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    AIThinkingPicker(
                        surface: .overview,
                        language: context.language,
                        level: thinking,
                        options: thinkingOptions,
                        isEnabled: phase != .generating,
                        onChange: onThinkingChange
                    )
                    Spacer(minLength: 0)
                }
                if let thinkingHint, !thinkingHint.isEmpty {
                    Text(thinkingHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 8)
    }
}
