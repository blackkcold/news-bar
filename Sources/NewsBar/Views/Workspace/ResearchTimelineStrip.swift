import SwiftUI

/// Frames of the strip's capsules inside the strip's own coordinate space.
/// The overflow badge needs to know which capsule is the last one fully on
/// screen, and that is a geometry question the layout already answers.
private struct ResearchTimelineStripFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ResearchTimelineStripFrameReader: View {
    let id: String
    let space: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ResearchTimelineStripFrameKey.self,
                value: [id: proxy.frame(in: .named(space))]
            )
        }
    }
}

/// The popup's timeline preview: nodes in time order, the ones that fit shown
/// in place, the rest one sideways scroll away with a badge saying how many.
///
/// This is a preview, not an index: the full timeline lives in the detail
/// chapter below. Captions therefore truncate, and the strip never reorders —
/// it only chooses where to start scrolling.
struct ResearchTimelineStrip: View {
    @Environment(AppSettings.self) private var settings

    static let space = "researchTimelineStrip"

    /// Width reserved for the badge slot. Outside the scroll view, so it can
    /// never cover a caption — an overlay would sit on top of whichever
    /// capsule happens to reach the right edge.
    private static let badgeSlotWidth: CGFloat = 40

    /// Room for the caption's own title. Real report titles run 11–15 Chinese
    /// characters; at 11pt this fits roughly 13, so the longest ones ellipsize
    /// instead of being clipped. Three captions plus the badge and the gaps
    /// stay inside the 584pt a 620pt window offers.
    static let captionTextWidth: CGFloat = 118

    let preview: ResearchTimelinePreview
    /// Called with the node id when a caption is clicked. Opening the detail
    /// (when needed) is the host's job, so this view stays layout only.
    let onSelect: (String) -> Void

    @State private var viewportWidth: CGFloat = 0
    @State private var frames: [String: CGRect] = [:]

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }

    /// Indices of the capsules fully inside the viewport, in strip order.
    ///
    /// These frames are reported in the named space of the `ScrollView`, which
    /// is the *viewport*: a capsule scrolled past the left edge has a negative
    /// `minX`. Comparing them against `contentOffset.x` would mix two
    /// coordinate systems and produce a wrong count as soon as the strip
    /// scrolled — which it always does, because it opens on the importance
    /// window rather than at the start.
    private var fullyVisibleIndices: [Int] {
        guard viewportWidth > 0, !frames.isEmpty else { return [] }
        return preview.nodes.indices.filter { index in
            guard let frame = frames[preview.nodes[index].id] else { return false }
            return frame.minX >= -1 && frame.maxX <= viewportWidth + 1
        }
    }

    /// How many nodes sit beyond the right edge. Zero hides the number, which is
    /// what "the strip is finished" looks like — the badge describes what is
    /// left, not how many exist.
    private var overflowCount: Int {
        guard let last = fullyVisibleIndices.last else { return 0 }
        return max(0, preview.nodes.count - last - 1)
    }

    /// Whether the badge slot is kept open. This is deliberately static per
    /// report rather than derived from the live overflow count: a slot that
    /// opens and closes while scrolling would resize the scroll view under the
    /// reader's finger. More captions than fit is the only condition that can
    /// ever overflow, so it is also the honest one to reserve on.
    private var reservesBadgeSlot: Bool {
        preview.nodes.count > ResearchTimelinePreview.visibleCount
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(preview.nodes.enumerated()), id: \.element.id) { _, node in
                            caption(node)
                                .id(ResearchReportNodeAnchor.capsule(node.id))
                                .background {
                                    ResearchTimelineStripFrameReader(id: node.id, space: Self.space)
                                }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(ResearchTimelineStripFrameKey.self) { frames = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
                .onAppear { scrollToImportanceWindow(proxy) }
                // A capsule that does not fit is cut by the viewport edge, and a
                // glyph sliced down the middle reads as a broken layout. The
                // fade says "the row continues" instead, and it disappears once
                // the strip reaches its end where nothing is being cut.
                .mask(alignment: .leading) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: overflowCount > 0 ? 0.9 : 1),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilitySummary)

                if reservesBadgeSlot {
                    badgeSlot(proxy: proxy)
                        .frame(width: Self.badgeSlotWidth, alignment: .trailing)
                }
            }
            // A capsule is a control, not reading copy: selection here would
            // fight the horizontal drag. The rest of the report stays
            // selectable, which is what the popup actually needs.
            .textSelection(.disabled)
        }
    }

    /// "N nodes, showing X to Y" rather than "showing the first N": the strip
    /// opens on the importance window, which is often in the middle.
    private var accessibilitySummary: String {
        let total = preview.nodes.count
        guard let first = fullyVisibleIndices.first, let last = fullyVisibleIndices.last else {
            return L10n.string("research.report.timeline.preview.a11y", language: settings.appLanguage, total)
        }
        return L10n.string(
            "research.report.timeline.preview.range.a11y",
            language: settings.appLanguage,
            total,
            first + 1,
            last + 1
        )
    }

    private func scrollToImportanceWindow(_ proxy: ScrollViewProxy) {
        guard let node = preview.initialWindow.first else { return }
        proxy.scrollTo(ResearchReportNodeAnchor.capsule(node.id), anchor: .leading)
    }

    private func caption(_ node: ReportPresentation.Node) -> some View {
        Button {
            onSelect(node.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    stateDot(node.state)
                    // The width limit belongs on the text, not on the HStack:
                    // a `frame` on the container clips the already-laid-out
                    // string, which produces a chopped glyph with no ellipsis
                    // and reads as a rendering fault. Constraining the `Text`
                    // itself is what makes `truncationMode(.tail)` apply.
                    Text(node.node.title)
                        .font(.system(size: 11, weight: .semibold, design: isRetro ? .serif : .default))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: Self.captionTextWidth, alignment: .leading)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.45), in: Capsule())

                if !node.node.date.isEmpty {
                    Text(node.node.date)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(node.node.title), \(node.node.date)")
    }

    /// Solid, dashed ring, faint fill: the three states must be tellable apart
    /// without colour, so each one differs in shape too.
    @ViewBuilder
    private func stateDot(_ state: ReportPresentation.NodeState) -> some View {
        switch state {
        case .verified:
            Circle().fill(accent).frame(width: 6, height: 6)
        case .citedUnverified:
            Circle()
                .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1.1, dash: [2, 2]))
                .frame(width: 6, height: 6)
        case .unsourced:
            Circle().fill(Color.secondary.opacity(0.45)).frame(width: 6, height: 6)
        }
    }

    /// The badge, in its own slot beside the scroll view. It shows the number
    /// that is still off screen, and disappears (leaving the slot empty) once
    /// the strip has reached its end.
    @ViewBuilder
    private func badgeSlot(proxy: ScrollViewProxy) -> some View {
        if overflowCount > 0 {
            Button {
                advanceOneWindow(proxy: proxy)
            } label: {
                Text(L10n.string("research.report.timeline.more", language: settings.appLanguage, overflowCount))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string(
                "research.report.timeline.more.a11y",
                language: settings.appLanguage,
                overflowCount
            ))
        }
    }

    /// Advances exactly one window: the first caption that is currently off
    /// screen becomes the leading one. Scrolling by a fixed multiple of three
    /// would jump two windows whenever more than three captions fit, and the
    /// `.leading` anchor clamps itself at the end of the strip — so the number
    /// counts down to zero instead of wrapping back to the start.
    private func advanceOneWindow(proxy: ScrollViewProxy) {
        guard let last = fullyVisibleIndices.last,
              preview.nodes.indices.contains(last + 1) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(
                ResearchReportNodeAnchor.capsule(preview.nodes[last + 1].id),
                anchor: .leading
            )
        }
    }
}

/// The one control that reveals the detail chapters. It stays in place while
/// the chapters are appended below it, so expanding never moves what the
/// reader was looking at.
///
/// The trailing preview answers "is it worth opening?" before the click. It
/// deliberately does not repeat the source count: the conclusion's count line
/// already carries it, and the same number twice on one screen is noise.
enum ResearchDetailFoldPreview {
    static func make(report: BurstResearch, language: AppLanguage) -> String? {
        let metrics = ResearchReportMetrics(report: report)
        var parts: [String] = []
        if metrics.timelineNodeCount > 0 {
            parts.append(L10n.string(
                countKey(
                    base: "research.report.fold.preview.timeline",
                    count: metrics.timelineNodeCount
                ),
                language: language,
                metrics.timelineNodeCount
            ))
        }
        if metrics.claimCount > 0 {
            parts.append(L10n.string(
                countKey(
                    base: "research.report.fold.preview.checks",
                    count: metrics.claimCount
                ),
                language: language,
                metrics.claimCount
            ))
        }
        if metrics.missingCount > 0 {
            parts.append(L10n.string(
                countKey(
                    base: "research.report.fold.preview.missing",
                    count: metrics.missingCount
                ),
                language: language,
                metrics.missingCount
            ))
        }
        // Nil, not "": the strip only exists when at least one detail chapter
        // does, and an empty string would still take a separator's width.
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// English inflects for one; Chinese does not. A key ending in `.one`
    /// exists only for the languages that need it, so the lookup falls back to
    /// the plural key when a table has no singular form.
    private static func countKey(base: String, count: Int) -> String {
        count == 1 ? "\(base).one" : base
    }
}

struct ResearchDetailFoldStrip: View {
    @Environment(AppSettings.self) private var settings

    let isExpanded: Bool
    /// The report the strip stands in front of. Passed as data, not as a
    /// pre-rendered string, so the preview and the button label resolve their
    /// language from the same place and can never disagree.
    let report: BurstResearch
    let onToggle: () -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var preview: String? {
        ResearchDetailFoldPreview.make(report: report, language: settings.appLanguage)
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 1)
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Text(isExpanded
                         ? L10n.string("research.report.fold.collapse", language: settings.appLanguage)
                         : L10n.string("research.report.fold.expand", language: settings.appLanguage))
                        .font(.system(size: 11.5, weight: .semibold, design: isRetro ? .serif : .default))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let preview, !isExpanded {
                        Text(preview)
                            .font(.system(size: 10.5, weight: .regular, design: isRetro ? .serif : .default))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The label names the action; the value reports the state, so a
            // VoiceOver reader knows both what will happen and where they are.
            // The preview joins the value so it is spoken without becoming a
            // second label for the same button.
            .accessibilityValue(accessibilityValue)
        }
    }

    private var accessibilityValue: String {
        let state = isExpanded
            ? L10n.string("research.report.fold.value.expanded", language: settings.appLanguage)
            : L10n.string("research.report.fold.value.collapsed", language: settings.appLanguage)
        guard !isExpanded, let preview else { return state }
        return "\(state) · \(preview)"
    }
}
