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
                ResearchReportNavigator(
                    sections: chapters,
                    active: activeSection,
                    onSelect: { section in
                        jump(to: section, using: proxy)
                    },
                    isHistorical: isHistorical
                )
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let topContent {
                            topContent
                        }
                        ForEach(chapters) { section in
                            sectionContent(section, timeline: timeline, links: links, using: proxy)
                                .id(section.id)
                                .background(alignment: .top) {
                                    ResearchReportSectionOffsetReader(section: section)
                                }
                        }
                    }
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
            }
        }
        .environment(\.researchReportPresentation, presentation)
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
