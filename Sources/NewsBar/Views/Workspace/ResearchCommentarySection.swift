import SwiftUI

/// Positions on the event, one per quadrant, in the order the validator fixed.
///
/// This is a reading block, not a grid: four cells drawn as four boxes would
/// turn an argument into a dashboard. The hierarchy comes from the speaker's
/// name in medium weight and the origin/era label in small caps above it, with
/// the words themselves as the only large element on the row.
///
/// The block renders nothing when there is nothing to show. An empty quadrant
/// is the normal case, not a defect to be padded.
struct ResearchCommentarySection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.researchReportPresentation) private var presentation

    let commentary: [CommentaryItem]
    let onOpenURL: (String, String) -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResearchCommentaryHeading()

            VStack(alignment: .leading, spacing: 16) {
                ForEach(commentary) { item in
                    row(item)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ item: CommentaryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ResearchCommentarySection.quadrantLabel(item, language: settings.appLanguage))
                .font(.system(size: 9.5, weight: .black, design: isRetro ? .serif : .default))
                .tracking(isRetro ? 0.7 : 0.25)
                .foregroundStyle(.secondary)

            Text(attributed(item))
                .font(presentation.bodyFont(13, isRetro: isRetro))
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Button {
                    onOpenURL(item.url, item.domain)
                } label: {
                    Text(item.domain)
                        .font(presentation.bodyFont(10.5, weight: .medium, isRetro: isRetro))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(item.domain)

                if let publishedAt = item.publishedAt {
                    Text("·")
                        .font(presentation.bodyFont(10.5, isRetro: isRetro))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(ResearchCommentarySection.dayLabel(publishedAt, language: settings.appLanguage))
                        .font(presentation.bodyFont(10.5, isRetro: isRetro))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(item))
    }

    /// A quote is the speaker's words: it gets quotation marks, and Chinese uses
    /// corner brackets so the marks match the rest of the interface. A
    /// paraphrase is the model's summary of a position, so it carries no quote
    /// marks and says so — presenting an approximation in quotation marks is the
    /// one failure this feature exists to prevent.
    private func attributed(_ item: CommentaryItem) -> AttributedString {
        var text = AttributedString()
        let role = item.role.map { "（\($0)）" } ?? ""
        let name = AttributedString("\(item.speaker)\(role)")
        var namePart = name
        namePart.font = .system(
            size: presentation.fontSize(13),
            weight: .semibold,
            design: isRetro ? .serif : .default
        )
        text.append(namePart)
        text.append(AttributedString("："))

        var words = AttributedString(
            item.isParaphrase
                ? item.quote
                : (settings.appLanguage == .zh ? "「\(item.quote)」" : "\u{201C}\(item.quote)\u{201D}")
        )
        if item.isParaphrase {
            words.foregroundColor = .secondary
        }
        text.append(words)
        return text
    }

    private func accessibilityLabel(_ item: CommentaryItem) -> String {
        let quadrant = ResearchCommentarySection.quadrantLabel(item, language: settings.appLanguage)
        let kind = item.isParaphrase
            ? L10n.string("research.report.commentary.paraphrase", language: settings.appLanguage)
            : L10n.string("research.report.commentary.quoted", language: settings.appLanguage)
        let role = item.role.map { "，\($0)" } ?? ""
        return "\(quadrant)，\(item.speaker)\(role)，\(kind)：\(item.quote)"
    }
}

/// The section header. Separate so the insertable block and the heading carry
/// the same chrome as every other detail chapter without becoming one.
struct ResearchCommentaryHeading: View {
    @Environment(AppSettings.self) private var settings

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        WorkspaceSectionHeader(
            symbol: "quote.bubble",
            title: L10n.string("research.report.commentary.title", language: settings.appLanguage)
        )
    }
}

extension ResearchCommentarySection {
    /// Named cells, not "past/foreign". A reader should not have to decode the
    /// quadrant arithmetic to know whose view they are reading.
    static func quadrantLabel(_ item: CommentaryItem, language: AppLanguage) -> String {
        let key: String
        switch (item.era, item.origin) {
        case (.past, .domestic): key = "research.report.commentary.quadrant.pastDomestic"
        case (.past, .foreign): key = "research.report.commentary.quadrant.pastForeign"
        case (.present, .domestic): key = "research.report.commentary.quadrant.presentDomestic"
        case (.present, .foreign): key = "research.report.commentary.quadrant.presentForeign"
        }
        return L10n.string(key, language: language)
    }

    static func dayLabel(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.bcp47)
        formatter.dateFormat = language == .zh ? "yyyy年M月d日" : "d MMM yyyy"
        return formatter.string(from: date)
    }
}
