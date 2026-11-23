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

/// True while the end of the content is inside the viewport. A short last
/// section can never cross the top threshold, so the navigator needs this to
/// still select it once the reader is scrolled all the way down.
private struct ResearchReportContentEndKey: PreferenceKey {
    static let defaultValue: Bool = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct ResearchReportContentEndReader: View {
    let viewportHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ResearchReportContentEndKey.self,
                value: proxy.frame(in: .named(ResearchReportReader.scrollSpace)).maxY
                    <= viewportHeight + 1
            )
        }
    }
}

/// The shared report reader. The popup and the workspace both host it, so it
/// owns its navigation and the only `ScrollView`; sections must not scroll.
struct ResearchReportReader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let scrollSpace = "researchReportScroll"

    let report: BurstResearch
    let contextID: String?
    var isHistorical: Bool = false
    var isLegacy: Bool = false
    var showsSourceSection: Bool = true
    let onOpenURL: (String, String) -> Void
    var onOpenEventTimeline: (() -> Void)? = nil
    var topContent: AnyView? = nil

    @State private var activeSection: ResearchReportSection = .conclusion
    @State private var isAtContentEnd = false

    /// Internal so later tasks can extend the reading order without touching
    /// the navigator. Task 3 appends verification and sources.
    var sections: [ResearchReportSection] {
        [.conclusion, .timeline]
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ResearchReportNavigator(
                    sections: sections,
                    active: activeSection,
                    onSelect: { section in
                        activeSection = section
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            proxy.scrollTo(section.id, anchor: .top)
                        }
                    }
                )
                Divider()
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let topContent {
                                topContent
                            }
                            ForEach(sections) { section in
                                sectionContent(section)
                                    .id(section.id)
                                    .background(alignment: .top) {
                                        ResearchReportSectionOffsetReader(section: section)
                                    }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            ResearchReportContentEndReader(viewportHeight: viewport.size.height)
                        }
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    .onPreferenceChange(ResearchReportSectionOffsetKey.self) { offsets in
                        updateActiveSection(offsets)
                    }
                    .onPreferenceChange(ResearchReportContentEndKey.self) { atEnd in
                        guard isAtContentEnd != atEnd else { return }
                        isAtContentEnd = atEnd
                    }
                }
            }
        }
    }

    /// Keeps the highlighted chapter on the last section whose top has passed
    /// the navigation bar. Before any section reaches it the first stays active.
    /// The end of the content only picks the last section once the reader has
    /// actually scrolled; a report that fits the viewport opens on the first.
    private func updateActiveSection(_ offsets: [ResearchReportSection: CGFloat]) {
        guard !offsets.isEmpty else { return }
        let passed = sections.filter { (offsets[$0] ?? .greatestFiniteMagnitude) <= 12 }
        let hasScrolled = sections.contains { (offsets[$0] ?? 0) < -1 }
        let next: ResearchReportSection
        if isAtContentEnd, hasScrolled, let last = sections.last {
            next = last
        } else if let last = passed.last {
            next = last
        } else {
            next = sections.first ?? .conclusion
        }
        guard next != activeSection else { return }
        activeSection = next
    }

    @ViewBuilder
    private func sectionContent(_ section: ResearchReportSection) -> some View {
        switch section {
        case .conclusion:
            ResearchReportConclusionSection(
                report: report,
                contextID: contextID,
                isLegacy: isLegacy
            )
        case .timeline:
            ResearchReportTimelineSection(
                report: report,
                contextID: contextID,
                isLegacy: isLegacy,
                onOpenEventTimeline: onOpenEventTimeline
            )
        case .verification, .sources:
            // Filled in by Task 3.
            EmptyView()
        }
    }
}

/// Fixed chapter navigation above the scrolling body.
struct ResearchReportNavigator: View {
    let sections: [ResearchReportSection]
    let active: ResearchReportSection
    let onSelect: (ResearchReportSection) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Picker(
                selection: Binding(get: { active }, set: { onSelect($0) }),
                content: {
                    ForEach(sections) { section in
                        Text("\(section.index) \(section.title)").tag(section)
                    }
                },
                label: { EmptyView() }
            )
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }
}
