import SwiftUI

/// The wide layout's source index: a fixed 220pt column beside the report. It
/// is a browsing index, not a second reading surface — rows are compact, and a
/// click opens the source the same way chapter 04 does. Cross-column
/// highlighting is deliberately absent: the reader's `E1` chip still owns the
/// quote popover.
///
/// The rail keeps its own index scroll, which is the only reason the reader can
/// give up chapter 04 without losing access to the sources.
struct ResearchSourceRail: View {
    @Environment(AppSettings.self) private var settings

    /// Fixed column width. The pane only shows the rail when the detail pane is
    /// wide enough to keep the report readable next to it.
    static let width: CGFloat = 220

    /// The rail's single gate. 820pt of detail width keeps the report readable
    /// at the default 1180 window, which gives a ~630pt detail pane and no rail.
    static func isVisible(detailWidth: CGFloat) -> Bool {
        detailWidth >= 820
    }

    let groups: [ResearchSourceGroup]
    let metrics: ResearchReportMetrics
    let onOpenURL: (String, String) -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        HStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            groupBlock(group)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background)
        .accessibilityElement(children: .contain)
    }

    /// Same count line as the conclusion's meta strip, so the rail and the
    /// report cannot disagree about how many sources exist.
    private var header: some View {
        let text = L10n.string(
            "research.report.meta.sources",
            language: settings.appLanguage,
            metrics.evidenceCount,
            metrics.domainCount
        )
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: isRetro ? .serif : .default))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func groupBlock(_ group: ResearchSourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(group.domain)
                    .font(.system(size: 10, weight: .semibold, design: isRetro ? .serif : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(group.items.count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            // Each domain is a group header for the rows beneath it, not only
            // the count line at the top of the rail.
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(group.items) { item in
                    row(item)
                }
            }
        }
    }

    /// One compact source: `E1`, a single-line title, and whether its quote was
    /// verified. The whole row is the button.
    private func row(_ item: EvidenceItem) -> some View {
        let title = ResearchSourceRow.displayTitle(for: item)
        let state = ResearchSourceRow.verificationStateText(
            for: item,
            language: settings.appLanguage
        )
        return Button {
            onOpenURL(item.url, title)
        } label: {
            HStack(spacing: 6) {
                Text(item.id)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(title)
                    .font(.system(size: 10.5, weight: .medium, design: isRetro ? .serif : .default))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                verifiedDot(item.quoteVerified)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(ResearchSourceRow.backgroundOpacity))
            .editorialClipShape(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The dot is colour-only, so the state it stands for has to be in the
        // tooltip and the label too.
        .help("\(title) · \(state)")
        .accessibilityLabel(ResearchSourceRow.accessibilityDescription(
            for: item,
            language: settings.appLanguage
        ))
        .accessibilityHint(L10n.string(
            "research.report.source.open",
            language: settings.appLanguage
        ))
    }

    /// A filled green dot means the quote was found in the page; a hollow orange
    /// one means it was not. The pair matches the green/orange badge in chapter
    /// 04, so the two indexes read the same state the same way.
    @ViewBuilder
    private func verifiedDot(_ verified: Bool) -> some View {
        if verified {
            Circle()
                .fill(Color.green)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        } else {
            Circle()
                .strokeBorder(Color.orange.opacity(0.85), lineWidth: 1)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }
}
