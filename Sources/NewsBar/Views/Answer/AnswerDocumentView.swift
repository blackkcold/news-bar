import SwiftUI

/// The shared answer canvas: one lede, a provenance line, the sections, then
/// the pages this run actually read.
///
/// The provenance line sits directly under the lede on purpose. A confident
/// summary followed by sources three screens down is the one arrangement this
/// card must never use.
struct AnswerDocumentView: View {
    let document: AnswerDocument
    let language: AppLanguage
    let maxHeight: CGFloat
    let onOpenSource: (AISearchSource) -> Void
    var onLookUp: (() -> Void)? = nil
    /// One line under the badge row explaining how this answer was produced
    /// when the badge alone would be ambiguous — an automatic look-up that was
    /// judged unnecessary, or one that failed and fell back.
    var notice: String? = nil
    /// True while the answer is still being revealed. The canvas holds its cap
    /// for the whole run and only hugs its content once the text stops.
    var isStreaming: Bool = false

    @State private var highlightedSource: Int?
    @State private var contentHeight: CGFloat = 0

    private var citedIndices: Set<Int> { Set(document.verifiedCitationIndices) }

    private static let sourcesAnchor = "answer-sources"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(proxy: proxy)
                    ForEach(document.blocks) { block in
                        AnswerBlockView(
                            block: block,
                            sourceCount: document.sources.count,
                            allowedCitations: document.allowedCitations,
                            selectable: !isStreaming
                        ) { index in
                            reveal(index, proxy: proxy)
                        }
                    }
                    if !document.sources.isEmpty {
                        Divider()
                        sourceSection.id(Self.sourcesAnchor)
                    }
                }
                .padding(.vertical, 2)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .frame(maxHeight: canvasHeight)
            // A cut-off card must look cut off. macOS 26 provides the system
            // scroll edge effect, which adapts to the theme and material. The
            // fallback for older systems uses a plain background-coloured
            // gradient instead of a second material layer.
            .modifier(AnswerScrollEdgeModifier(isOverflowing: isOverflowing))
        }
    }

    private var isOverflowing: Bool {
        contentHeight > canvasHeight + 1
    }

    private var canvasHeight: CGFloat {
        Self.canvasHeight(contentHeight: contentHeight, maxHeight: maxHeight, isStreaming: isStreaming)
    }

    /// A streaming answer keeps the cap for the whole run; a finished one hugs
    /// its content. Growing the canvas on every revealed character resized the
    /// scroll view up to fifteen times a second, and a scroll view that resizes
    /// under repainting text is where the previous frame's glyphs stay on
    /// screen. Kept pure so the rule is testable without a window.
    static func canvasHeight(contentHeight: CGFloat, maxHeight: CGFloat, isStreaming: Bool) -> CGFloat {
        isStreaming ? maxHeight : clampedHeight(contentHeight: contentHeight, maxHeight: maxHeight)
    }

    private var clampedHeight: CGFloat {
        Self.clampedHeight(contentHeight: contentHeight, maxHeight: maxHeight)
    }

    /// A short answer gets a short card; a long one stops at the cap and
    /// scrolls. Kept pure so the geometry rule is testable without a window.
    static func clampedHeight(contentHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard contentHeight > 0 else { return maxHeight }
        return min(maxHeight, max(96, contentHeight))
    }

    private func header(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !document.oneLine.isEmpty {
                Text(document.oneLine)
                    .font(.system(.body, weight: .semibold))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
            }
            if let retrieval = document.retrieval {
                basisBadge(retrieval.basis)
            }
            provenance {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(Self.sourcesAnchor, anchor: .top)
                }
            }
            retrievalNotes
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if document.truncated {
                Label(L10n.string("answer.truncated", language: language), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Evidence basis

    @ViewBuilder
    private func basisBadge(_ basis: AnswerBasis) -> some View {
        switch basis {
        case .externalSupported:
            badge(
                icon: "checkmark.seal.fill",
                text: L10n.string(
                    "answer.basis.supported",
                    language: language,
                    document.verifiedCitationIndices.count
                ),
                tone: .green
            )
        case .externalLimited:
            HStack(spacing: 6) {
                badge(
                    icon: "circle.lefthalf.filled",
                    text: L10n.string("answer.basis.limited", language: language),
                    tone: .orange
                )
                Text(limitedDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .currentPageOnly:
            badge(
                icon: "doc.text",
                text: L10n.string("answer.basis.currentPage", language: language),
                tone: .secondary
            )
        case .noVerifiedCitations:
            Label(
                L10n.string("answer.basis.noCitations", language: language),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        case .insufficientMaterial:
            badge(
                icon: "tray",
                text: L10n.string("answer.basis.insufficient", language: language),
                tone: .secondary
            )
        }
    }

    private func badge(icon: String, text: String, tone: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tone.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var limitedDetail: String {
        let notes = document.retrieval?.notes ?? []
        if notes.contains(.assessmentSkipped) || notes.contains(.assessmentFailed) {
            return L10n.string("answer.basis.limited.unassessed", language: language)
        }
        if assessmentWasOff {
            return L10n.string("answer.basis.limited.heuristic", language: language)
        }
        let adopted = document.retrieval?.adoptedCount ?? 0
        return adopted <= 1
            ? L10n.string("answer.basis.limited.single", language: language)
            : L10n.string("answer.basis.limited.secondary", language: language)
    }

    /// With assessment off, every readable non-duplicate source is marked
    /// `heuristic`. Saying "mostly secondary" in that state would be a claim
    /// the app never checked.
    private var assessmentWasOff: Bool {
        let webSources = document.sources.filter {
            $0.origin == .web && $0.duplicateOf == nil
        }
        guard !webSources.isEmpty else { return false }
        return webSources.allSatisfy { $0.assessment?.reason == .heuristic }
    }

    @ViewBuilder
    private var retrievalNotes: some View {
        let notes = visibleNotes
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notes.indices, id: \.self) { index in
                    Label(notes[index].message(language), systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var visibleNotes: [RetrievalNote] {
        guard let retrieval = document.retrieval else { return [] }
        let notes = retrieval.notes.filter { note in
            if retrieval.basis == .externalLimited,
               note == .assessmentSkipped || note == .assessmentFailed {
                // The badge already explains why evidence is limited.
                return false
            }
            return true
        }
        guard document.blocks.isEmpty else { return notes }
        // The headline already states these; repeating them under it would be
        // noise. The remaining notes explain a partial run.
        return notes.filter {
            $0 == .partialProviders
                || $0 == .assessmentSkipped
                || $0 == .assessmentFailed
                || $0 == .conflictingSources
                || $0 == .partialCitations
        }
    }

    private func provenance(onShowSources: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: provenanceIcon)
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            if !document.blocks.isEmpty {
                Text(document.kind.label(language))
            }
            if !document.blocks.isEmpty, modeLabel != nil || document.evidence.sourceCount > 0 {
                Text("·").accessibilityHidden(true)
            }
            if let modeLabel {
                Text(modeLabel)
            }
            if document.mode == .offline, let onLookUp {
                Button(action: onLookUp) {
                    Label(L10n.string("answer.lookUp", language: language), systemImage: "globe")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(L10n.string("answer.lookUp", language: language))
            }
            if let retrieval = document.retrieval, document.mode == .web {
                if modeLabel != nil {
                    Text("·").accessibilityHidden(true)
                }
                Button(action: onShowSources) {
                    HStack(spacing: 2) {
                        Text(L10n.string(
                            "answer.evidence.found",
                            language: language,
                            retrieval.foundCount
                        ))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("answer.sources", language: language))
                Text("·").accessibilityHidden(true)
                Text(L10n.string(
                    "answer.evidence.read",
                    language: language,
                    retrieval.readCount
                ))
                Text("·").accessibilityHidden(true)
                Text(L10n.string(
                    "answer.evidence.adopted",
                    language: language,
                    retrieval.adoptedCount
                ))
                Text("·").accessibilityHidden(true)
                Text(L10n.string(
                    "answer.evidence.cited",
                    language: language,
                    document.verifiedCitationIndices.count
                ))
            } else if document.evidence.sourceCount > 0 {
                if modeLabel != nil {
                    Text("·").accessibilityHidden(true)
                }
                Button(action: onShowSources) {
                    HStack(spacing: 2) {
                        Text(L10n.string(
                            "answer.evidence.read",
                            language: language,
                            document.evidence.sourceCount
                        ))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("answer.sources", language: language))
                Text("·").accessibilityHidden(true)
                Text(L10n.string(
                    "answer.evidence.cited",
                    language: language,
                    document.verifiedCitationIndices.count
                ))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var modeLabel: String? {
        switch document.mode {
        case .offline: return L10n.string("answer.offline", language: language)
        case .currentPage: return L10n.string("answer.currentPage", language: language)
        case .web: return nil
        }
    }

    private var provenanceIcon: String {
        switch document.mode {
        case .offline: return "sparkles"
        case .currentPage: return "doc.text"
        case .web: return "globe"
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("answer.sources", language: language))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(document.sources) { source in
                AnswerSourceRow(
                    source: source,
                    cited: citedIndices.contains(source.index),
                    highlighted: highlightedSource == source.index,
                    language: language,
                    onOpen: { onOpenSource(source) }
                )
                .id(source.index)
            }
        }
    }

    private func reveal(_ index: Int, proxy: ScrollViewProxy) {
        highlightedSource = index
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}

/// One read page. The number is accent-coloured only when the answer actually
/// points at it, so a source list can never imply usage it does not have.
private struct AnswerSourceRow: View {
    let source: AISearchSource
    let cited: Bool
    let highlighted: Bool
    let language: AppLanguage
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("[\(source.index)]")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(cited ? Color.accentColor : Color.secondary)
                    .frame(width: 26, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let metadataLine {
                        Text(metadataLine)
                            .font(.caption2)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .opacity(isRejected ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .background(
            highlighted
                ? Color.accentColor.opacity(0.12)
                : (hovering ? Color.primary.opacity(0.05) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(
            L10n.string("answer.cite", language: language, source.index) + ", " + source.title
        )
        .accessibilityHint(metadataLine ?? source.host)
    }

    private var isRejected: Bool {
        source.assessment?.adoption == .rejected
    }

    private var metadataLine: String? {
        var parts: [String] = []
        if source.origin == .currentPage {
            parts.append(L10n.string("answer.currentPage", language: language))
        } else if !source.host.isEmpty {
            parts.append(source.host)
        }
        if let date = source.publishedAt {
            parts.append(date.formatted(.dateTime.year().month().day()))
        }
        if let type = source.assessment?.type, type != .unknown {
            parts.append(L10n.string("answer.source.type.\(type.rawValue)", language: language))
        }
        if let assessment = source.assessment {
            parts.append(L10n.string(
                "answer.source.adoption.\(assessment.adoption.rawValue)",
                language: language
            ))
        }
        if cited {
            parts.append(L10n.string("answer.citedSource", language: language))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var reasonText: String? {
        guard let assessment = source.assessment else { return nil }
        let key = "answer.source.reason.\(assessment.reason.rawValue)"
        let localized = L10n.string(key, language: language)
        if localized != key { return localized }
        let detail = assessment.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? nil : detail
    }

    private var helpText: String {
        [source.url, reasonText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Keeps the answer canvas' bottom edge legible without stacking another
/// material sheet on top of the card. macOS 26 and later use the system scroll
/// edge effect; older systems get a neutral gradient that matches the window
/// background.
private struct AnswerScrollEdgeModifier: ViewModifier {
    let isOverflowing: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            // Standard-material scroll fade for macOS 15–25. It matches the
            // floating panel behind the answer canvas better than an opaque
            // window colour, especially in dark mode. This is not Liquid Glass;
            // it is the same content-layer material the answer used before.
            content.overlay(alignment: .bottom) {
                if isOverflowing {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(height: 28)
                        .mask(
                            LinearGradient(
                                colors: [.clear, .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
