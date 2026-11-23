import SwiftUI

/// The wide layout's source index: a fixed 220pt column beside the report. It
/// is a browsing index, not a second reading surface — rows are compact, and a
/// click opens the source the same way chapter 04 does. Cross-column
/// highlighting is deliberately absent: the reader's `E1` chip still owns the
/// quote popover.
struct ResearchSourceRail: View {
    @Environment(AppSettings.self) private var settings

    /// Fixed column width. The pane only shows the rail when the detail pane is
    /// wide enough to keep the report readable next to it.
    static let width: CGFloat = 220

    let groups: [ResearchSourceGroup]
    let metrics: ResearchReportMetrics
    let onOpenURL: (String, String) -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }

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
        let title = displayTitle(for: item)
        return Button {
            onOpenURL(item.url, title)
        } label: {
            HStack(spacing: 6) {
                Text(item.id)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
            .background(.quaternary.opacity(0.14))
            .editorialClipShape(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(L10n.string(
            "workspace.evidence.openLabel",
            language: settings.appLanguage,
            title
        ))
        .accessibilityValue(item.quoteVerified
            ? "workspace.evidence.verified".localized
            : "workspace.evidence.unverified".localized)
    }

    /// A filled dot means the quote was found in the page; a hollow one means
    /// it was not. It is never coloured to imply more than that.
    @ViewBuilder
    private func verifiedDot(_ verified: Bool) -> some View {
        if verified {
            Circle()
                .fill(accent)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }

    private func displayTitle(for item: EvidenceItem) -> String {
        item.title.isEmpty ? item.domain : item.title
    }
}
