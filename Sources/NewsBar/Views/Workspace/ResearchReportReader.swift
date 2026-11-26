import SwiftUI

/// One chapter of the report. Order is reading order, and `rawValue` doubles as
/// the scroll anchor so the navigator and the sections cannot drift apart.
enum ResearchReportSection: String, CaseIterable, Identifiable, Sendable {
    case conclusion
    case timeline
    case verification
    case sources

    var id: String { rawValue }

    /// Fixed two-digit index shown in the navigator and the section header.
    var index: String {
        switch self {
        case .conclusion: return "01"
        case .timeline: return "02"
        case .verification: return "03"
        case .sources: return "04"
        }
    }

    /// Literal keys keep the localization lint able to see every string.
    var title: String {
        switch self {
        case .conclusion: return "research.report.nav.conclusion".localized
        case .timeline: return "research.report.nav.timeline".localized
        case .verification: return "research.report.nav.verification".localized
        case .sources: return "research.report.nav.sources".localized
        }
    }
}

/// Scroll offsets of each section, keyed by section so a section that is not
/// on screen yet simply has no entry.
struct ResearchReportSectionOffsetKey: PreferenceKey {
    static let defaultValue: [ResearchReportSection: CGFloat] = [:]

    static func reduce(
        value: inout [ResearchReportSection: CGFloat],
        nextValue: () -> [ResearchReportSection: CGFloat]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Reports a section's top edge in the scroll view's coordinate space so the
/// navigator can follow the reader instead of only driving it.
private struct ResearchReportSectionOffsetReader: View {
    let section: ResearchReportSection

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ResearchReportSectionOffsetKey.self,
                value: [section: proxy.frame(in: .named(ResearchReportReader.scrollSpace)).minY]
            )
        }
    }
}

/// Scroll metrics that drive the navigator. `onScrollGeometryChange` only fires
/// when one of these values changes, so the handler is not run on every tick.
private struct ScrollMetrics: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
}

/// The shared report reader. The popup and the workspace both host it, so it
/// owns its navigation and its own `ScrollView`; sections must not scroll. The
/// workspace's wide source rail is a separate column with its own index scroll,
/// which is why chapter 04 can be handed over to the rail.
struct ResearchReportReader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let scrollSpace = "researchReportScroll"

    let report: BurstResearch
    let contextID: String?
    var isHistorical: Bool = false
    var isLegacy: Bool = false
    var showsSourceSection: Bool = true
    let onOpenURL: (String, String) -> Void
    var onOpenEventTimeline: (() -> Void)? = nil
    var topContent: AnyView? = nil
    var presentation: ResearchReportPresentation = .workspace

    /// The popup pins its own body size, which would otherwise stop following
    /// the system text size. Chapters read the resolved value from the
    /// environment so no section needs to know about Dynamic Type.
    private var resolvedPresentation: ResearchReportPresentation {
        presentation.scalingBodyFont(by: dynamicTypeSize.readerTextScale)
    }

    @State private var activeSection: ResearchReportSection = .conclusion
    @State private var hasScrolled = false
    @State private var isAtContentEnd = false
    @State private var lastOffsets: [ResearchReportSection: CGFloat] = [:]
    @State private var disclosure = ResearchDetailDisclosureState()
    @AccessibilityFocusState(for: .voiceOver) private var focusedSection: ResearchReportSection?

    var supplementaryLinks: [SupplementaryReportLink] {
        resolvedPresentation.supplementaryLinks(in: report, isLegacy: isLegacy)
    }

    var sections: [ResearchReportSection] {
        sections(timeline: resolvedPresentation.timelineReport(report), links: supplementaryLinks)
    }

    private func sections(timeline: BurstResearch, links: [SupplementaryReportLink]) -> [ResearchReportSection] {
        var result: [ResearchReportSection] = [.conclusion]
        if !resolvedPresentation.usesReadableChapters || !timeline.timeline.isEmpty {
            result.append(.timeline)
        }
        if report.verification != nil || !report.evidence.isEmpty
            || resolvedPresentation.visibleLimitations(in: report) != nil {
            result.append(.verification)
        }
        if showsSourceSection && (!report.evidence.isEmpty || !links.isEmpty) {
            result.append(.sources)
        }
        return result
    }

    var body: some View {
        let presentation = resolvedPresentation
        let timeline = presentation.timelineReport(report)
        let links = supplementaryLinks
        let chapters = sections(timeline: timeline, links: links)
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if presentation.showsChapterNavigator {
                    ResearchReportNavigator(
                        sections: chapters,
                        active: activeSection,
                        onSelect: { section in
                            jump(to: section, using: proxy)
                        },
                        isHistorical: isHistorical
                    )
                    Divider()
                }
                ScrollView {
                    bodyContent(
                        chapters: chapters,
                        timeline: timeline,
                        links: links,
                        using: proxy
                    )
                    .frame(maxWidth: presentation.maximumBodyWidth, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: presentation.maximumBodyWidth == nil ? .leading : .center)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(ResearchReportSectionOffsetKey.self) { offsets in
                    lastOffsets = offsets
                    updateActiveSection(lastOffsets, chapters: chapters)
                }
                .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                    ScrollMetrics(
                        offsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.containerSize.height
                    )
                } action: { _, metrics in
                    hasScrolled = metrics.offsetY > 1
                    isAtContentEnd = metrics.contentHeight > metrics.viewportHeight + 1
                        && metrics.offsetY + metrics.viewportHeight >= metrics.contentHeight - 2
                    updateActiveSection(lastOffsets, chapters: chapters)
                }
                .onChange(of: WorkspaceReportDigest.make(report)) {
                    activeSection = .conclusion
                    hasScrolled = false
                    isAtContentEnd = false
                    lastOffsets = [:]
                    // Resetting the highlight is not enough: a reader that was
                    // mid-report would keep the old scroll position and land on
                    // a chapter that no longer means the same thing.
                    proxy.scrollTo(ResearchReportSection.conclusion.id, anchor: .top)
                }
                .onChange(of: chapters) { _, updated in
                    if !updated.contains(activeSection) {
                        activeSection = updated.last ?? .conclusion
                    }
                }
                // A queued reveal only exists because the reader clicked a
                // capsule before the detail chapters were in the view tree.
                // Running it after the layout pass is what makes that click
                // land instead of silently doing nothing.
                .onChange(of: disclosure.isExpanded) { _, expanded in
                    guard expanded, let target = disclosure.consumePendingReveal() else { return }
                    scrollToDetailNode(target, using: proxy)
                }
            }
        }
        .environment(\.researchReportPresentation, presentation)
    }

    /// Scrolls to a node's row inside the timeline chapter. The row carries its
    /// own id namespace because the strip's capsule holds the bare node id:
    /// without the prefix this would land on the capsule instead of the row.
    private func scrollToDetailNode(_ nodeID: String, using proxy: ScrollViewProxy) {
        let anchor = ResearchReportNodeAnchor.detail(nodeID)
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                proxy.scrollTo(anchor, anchor: .center)
            }
        }
    }

    /// One scroll view for both layouts. The workbench reads every chapter in
    /// order; the popup reads the conclusion, then a strip, then — only when
    /// the reader asked for it — the three detail chapters below that strip.
    ///
    /// The strip never moves: detail is appended *after* it, so expanding
    /// changes nothing above the reader's current position.
    @ViewBuilder
    private func bodyContent(
        chapters: [ResearchReportSection],
        timeline: BurstResearch,
        links: [SupplementaryReportLink],
        using proxy: ScrollViewProxy
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let topContent {
                topContent
            }
            if presentation.foldsDetailChapters {
                sectionContent(.conclusion, timeline: timeline, links: links, using: proxy)
                    .id(ResearchReportSection.conclusion.id)
                if detailChapters(chapters).isEmpty == false {
                    detailStrip(chapters: chapters, timeline: timeline, using: proxy)
                }
                if disclosure.isExpanded {
                    // Background reads as the first thing in the detail area:
                    // it is context for the timeline, not a second disclosure
                    // competing with the fold strip on the first screen.
                    if let overview = publishedOverview(timeline) {
                        ResearchReportOverviewBlock(text: overview)
                    }
                    // 24pt between detail chapters: they are three answers to
                    // three different questions, and 20pt read as one block.
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(detailChapters(chapters)) { section in
                            sectionContent(section, timeline: timeline, links: links, using: proxy)
                                .id(section.id)
                        }
                    }
                }
            } else {
                ForEach(chapters) { section in
                    sectionContent(section, timeline: timeline, links: links, using: proxy)
                        .id(section.id)
                        .background(alignment: .top) {
                            ResearchReportSectionOffsetReader(section: section)
                        }
                }
            }
        }
        // Attached to the whole column so headings, dates, node titles, the
        // count line and source rows are all quotable — not just the summary,
        // which is the only run that opts in per view today.
        .modifier(ResearchReaderTextSelection(enabled: presentation.enablesTextSelection))
    }

    private func detailChapters(_ chapters: [ResearchReportSection]) -> [ResearchReportSection] {
        chapters.filter { $0 != .conclusion }
    }

    /// Background copy for the detail area, or nil when there is none or when
    /// the conclusion already draws it. Only the popup moves it here; the
    /// workbench keeps its inline disclosure untouched.
    private func publishedOverview(_ timeline: BurstResearch) -> String? {
        guard !presentation.showsOverviewInConclusion else { return nil }
        let text = report.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The preview strip and the fold control, in that order. Both are pinned
    /// inside the same scroll content, so neither can cover the report.
    @ViewBuilder
    private func detailStrip(
        chapters: [ResearchReportSection],
        timeline: BurstResearch,
        using proxy: ScrollViewProxy
    ) -> some View {
        let nodes = ReportPresentation(report: timeline, isLegacy: isLegacy).nodes
        VStack(alignment: .leading, spacing: 14) {
            if !nodes.isEmpty {
                ResearchTimelineStrip(
                    preview: ResearchTimelinePreview(nodes: nodes),
                    onSelect: { nodeID in
                        // Two distinct paths, because the detail chapters only
                        // exist while expanded. An open detail has the row in
                        // the tree already, so scroll now; a folded one has to
                        // expand first and scroll after the layout pass, which
                        // the `onChange` below does. Relying on `onChange`
                        // alone would drop every click made while expanded.
                        let wasExpanded = disclosure.isExpanded
                        if wasExpanded {
                            scrollToDetailNode(nodeID, using: proxy)
                            disclosure.reveal(nodeID)
                            _ = disclosure.consumePendingReveal()
                        } else {
                            disclosure.reveal(nodeID)
                        }
                    }
                )
            }
            ResearchDetailFoldStrip(
                isExpanded: disclosure.isExpanded,
                onToggle: {
                    ResearchDetailDisclosureState.persist(!disclosure.isExpanded)
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        disclosure.toggle()
                    }
                }
            )
        }
    }

    private func jump(to section: ResearchReportSection, using proxy: ScrollViewProxy) {
        activeSection = section
        if presentation.usesReadableChapters { focusedSection = section }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            proxy.scrollTo(section.id, anchor: .top)
        }
    }

    /// Keeps the highlighted chapter on the last section whose top has passed
    /// the navigation bar. An unscrolled reader always shows the first section,
    /// so a report that fits the viewport opens on the conclusion.
    private func updateActiveSection(_ offsets: [ResearchReportSection: CGFloat], chapters: [ResearchReportSection]) {
        guard !offsets.isEmpty else { return }
        let next: ResearchReportSection
        if !hasScrolled {
            next = chapters.first ?? .conclusion
        } else if isAtContentEnd, let last = chapters.last {
            next = last
        } else if let last = chapters.last(where: {
            (offsets[$0] ?? .greatestFiniteMagnitude) <= 12
        }) {
            next = last
        } else {
            next = chapters.first ?? .conclusion
        }
        guard next != activeSection else { return }
        activeSection = next
    }

    @ViewBuilder
    private func sectionContent(
        _ section: ResearchReportSection, timeline: BurstResearch, links: [SupplementaryReportLink],
        using proxy: ScrollViewProxy
    ) -> some View {
        let headingFocus = presentation.usesReadableChapters ? $focusedSection : nil
        switch section {
        case .conclusion:
            ResearchReportConclusionSection(
                report: report,
                isLegacy: isLegacy,
                supplementaryLinks: links,
                headingFocus: headingFocus,
                onJump: { jump(to: $0, using: proxy) }
            )
        case .timeline:
            ResearchReportTimelineSection(
                report: timeline,
                contextID: contextID,
                isLegacy: isLegacy,
                onOpenEventTimeline: onOpenEventTimeline,
                headingFocus: headingFocus
            )
        case .verification:
            ResearchReportVerificationSection(
                report: report,
                isLegacy: isLegacy,
                contextID: contextID,
                headingFocus: headingFocus
            )
        case .sources:
            ResearchReportSourceSection(
                report: report,
                onOpenURL: onOpenURL,
                supplementaryLinks: links,
                headingFocus: headingFocus
            )
        }
    }
}

/// Fixed chapter navigation above the scrolling body. A historical report is
/// marked here rather than in each host's chrome, so the popup and the
/// workspace cannot disagree about which report is on screen.
///
/// Four equal-width tabs instead of a native segmented `Picker`: the picker
/// refuses to fill the bar and leaves a dead half-row at 760pt, while this bar
/// keeps the same contract — the accessible label is the chapter title (no
/// ordinal) and the active chapter is marked selected.
struct ResearchReportNavigator: View {
    @Environment(\.researchReportPresentation) private var presentation
    let sections: [ResearchReportSection]
    let active: ResearchReportSection
    let onSelect: (ResearchReportSection) -> Void
    var isHistorical: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(sections) { section in
                    tab(section)
                }
            }
            .frame(maxWidth: .infinity)
            if isHistorical {
                EditorialTag(
                    text: "research.report.historical".localized,
                    fallbackTint: .orange,
                    filled: true
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private func tab(_ section: ResearchReportSection) -> some View {
        let isActive = section == active
        return Button {
            onSelect(section)
        } label: {
            Text(presentation.title(section))
                .fontWeight(!presentation.showsChapterNumbers && isActive ? .bold : nil)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(EditorialActionButtonStyle(
            tone: isActive ? .selected : .secondary,
            compact: true
        ))
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
