import SwiftUI

struct ExplanationPrivacySectionView: View {
    let model: RecommendationExplanationModel
    let palette: ExplanationPalette

    private var english: Bool { model.language == .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCard
            factsCard
            scopeCard(
                title: english ? "Clearing personal data" : "清空个人数据",
                symbol: "trash",
                body: model.clearNote
            )
            scopeCard(
                title: english ? "Browser data is separate" : "浏览器数据范围",
                symbol: "globe",
                body: model.browserScopeNote
            )
            scopeCard(
                title: english ? "What leaves this Mac" : "会发送什么",
                symbol: "paperplane",
                body: model.outboundNote
            )
            guideCard
            ExplanationNote(text: model.readOnlyNote, palette: palette, systemImage: "eye")
        }
    }

    private var statusCard: some View {
        ExplanationCard(palette: palette) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield")
                        .font(palette.font(12, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text(model.statusHeadline)
                        .font(palette.font(12, weight: .bold))
                        .foregroundStyle(palette.ink)
                    Spacer(minLength: 0)
                }
                Text(model.storageErrorNote ?? model.statusDetail)
                    .font(palette.font(10))
                    .foregroundStyle(model.storageErrorNote == nil ? palette.ink : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var factsCard: some View {
        ExplanationCard(
            palette: palette,
            title: english ? "Local scope" : "本机范围",
            subtitle: english ? "What is stored and for how long" : "存什么、存多久"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.privacyFacts) { fact in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fact.title)
                            .font(palette.font(10, weight: .semibold))
                            .foregroundStyle(palette.ink)
                        Text(fact.body)
                            .font(palette.font(9))
                            .foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func scopeCard(title: String, symbol: String, body: String) -> some View {
        ExplanationCard(palette: palette) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(palette.font(10, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text(title)
                        .font(palette.font(11, weight: .bold))
                        .foregroundStyle(palette.ink)
                    Spacer(minLength: 0)
                }
                Text(body)
                    .font(palette.font(9))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var guideCard: some View {
        ExplanationCard(
            palette: palette,
            title: english ? "Offline guide" : "离线说明",
            subtitle: english ? "Bundled source, no network" : "内置正文，不联网"
        ) {
            if model.guideUnavailable {
                ExplanationNote(text: model.guideUnavailableNote, palette: palette, systemImage: "exclamationmark.triangle")
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.guide.enumerated()), id: \.element.id) { index, section in
                        ExplanationGuideDisclosure(section: section, palette: palette, initiallyExpanded: index == 0)
                    }
                }
            }
        }
    }
}

struct ExplanationGuideDisclosure: View {
    let section: ExplanationGuideSection
    let palette: ExplanationPalette

    @State private var expanded: Bool

    init(section: ExplanationGuideSection, palette: ExplanationPalette, initiallyExpanded: Bool = false) {
        self.section = section
        self.palette = palette
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(section.body)
                .font(palette.font(9))
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        } label: {
            Text(section.title)
                .font(palette.font(10, weight: .semibold))
                .foregroundStyle(palette.ink)
        }
        .accessibilityLabel(section.title)
    }
}
