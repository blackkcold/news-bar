import SwiftUI

struct ExplanationRankingSection: View {
    let model: RecommendationExplanationModel
    let palette: ExplanationPalette
    @Binding var selection: String?
    var wide = false

    private var english: Bool { model.language == .en }
    private var selectedID: String? { selection ?? model.items.first?.id }

    var body: some View {
        Group {
            if wide {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        overviewColumn
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        detailColumn
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    overviewColumn
                    detailColumn
                }
            }
        }
    }

    @ViewBuilder
    private var overviewColumn: some View {
        metaCard
        if let lastKnownNote = model.lastKnownNote {
            ExplanationNote(text: lastKnownNote, palette: palette, systemImage: "clock.arrow.circlepath")
        }
        if model.items.isEmpty {
            ExplanationCard(palette: palette) {
                ExplanationNote(
                    text: english
                        ? "No explainable item is in the current snapshot. Open the dashboard to build one; this page never ranks on its own."
                        : "当前快照没有可解释的条目。请先在 Dashboard 生成快照；本页不会自行排序。",
                    palette: palette,
                    systemImage: "rectangle.dashed"
                )
            }
        } else {
            itemsCard
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selectedID, let item = model.item(id: id) {
            detailCard(item)
        }
        ExplanationNote(text: model.semanticNote, palette: palette, systemImage: "brain")
    }

    private var metaCard: some View {
        ExplanationCard(
            palette: palette,
            title: english ? "Snapshot" : "当前快照",
            subtitle: english ? "Frozen when captured" : "生成时冻结"
        ) {
            VStack(alignment: .leading, spacing: 4) {
                metaRow(english ? "As of" : "生成时间", snapshotTime)
                metaRow(english ? "Snapshot state version" : "快照状态版本",
                        model.snapshotProfileVersion.map { "v\($0)" } ?? "—")
                metaRow(english ? "Snapshot blend weight" : "快照混合权重",
                        model.snapshotConfidencePercent.map { "\($0)%" } ?? "—")
                metaRow(english ? "Policy version" : "策略版本", model.policyVersion.map { "v\($0)" } ?? "—")
                metaRow(english ? "Candidates" : "候选条目", "\(model.candidateCount)")
                Text(model.selectionNote)
                    .font(palette.font(9))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private var snapshotTime: String {
        guard let date = model.snapshotAsOf else { return "—" }
        let locale = Locale(identifier: english ? "en_US" : "zh_CN")
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(palette.font(10)).foregroundStyle(palette.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(palette.mono(10, weight: .semibold))
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var itemsCard: some View {
        ExplanationCard(
            palette: palette,
            title: english ? "Current order" : "当前排序",
            subtitle: model.itemsNote
        ) {
            VStack(spacing: 3) {
                Text(model.scoreColumnNote)
                    .font(palette.font(8))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                ForEach(model.items) { item in
                    itemRow(item)
                }
            }
        }
    }

    private func itemRow(_ item: RecommendationExplanationRankedItem) -> some View {
        let isSelected = item.id == selectedID
        return Button {
            selection = item.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(item.rank)")
                    .font(palette.mono(11, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 20, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(palette.font(10, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(item.reason)
                            .font(palette.font(8, weight: .bold))
                            .foregroundStyle(palette.accent)
                        Text(item.sourceName)
                            .font(palette.font(8))
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                        if item.trace == nil {
                            Text(english ? "no trace" : "无轨迹")
                                .font(palette.font(8))
                                .foregroundStyle(palette.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.3f", item.score))
                        .font(palette.mono(9, weight: .semibold))
                        .foregroundStyle(palette.ink)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(palette.font(9))
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .padding(6)
            .background {
                if isSelected { palette.shape.fill(palette.accent.opacity(0.10)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(english
            ? "Rank \(item.rank), \(item.title), \(item.reason), blended score before penalties \(String(format: "%.3f", item.score)), not the selection key"
            : "第 \(item.rank) 名，\(item.title)，\(item.reason)，混合分（惩罚前）\(String(format: "%.3f", item.score))，不是实际选择键")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func detailCard(_ item: RecommendationExplanationRankedItem) -> some View {
        ExplanationCard(
            palette: palette,
            title: english ? "Item \(item.rank) detail" : "第 \(item.rank) 名详情",
            subtitle: item.title
        ) {
            VStack(alignment: .leading, spacing: 8) {
                componentsTable(item)
                Divider().overlay(palette.border)
                if let trace = item.trace {
                    traceTable(trace)
                    if let slotKeyNote = item.slotKeyNote {
                        Text(slotKeyNote)
                            .font(palette.font(9, weight: .semibold))
                            .foregroundStyle(palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(trace.rankContractNote(model.language))
                        .font(palette.font(8))
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = trace.consistencyNote(model.language) {
                        Text(note)
                            .font(palette.font(9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ExplanationNote(text: item.traceAvailableNote, palette: palette, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                } else {
                    ExplanationNote(text: item.traceUnavailableNote, palette: palette, systemImage: "questionmark.square.dashed")
                }
            }
        }
    }

    private func componentsTable(_ item: RecommendationExplanationRankedItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(english ? "Raw components → recorded personal term" : "原始组件 → 实际个人项")
                .font(palette.font(9, weight: .bold))
                .foregroundStyle(palette.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    Text(english ? "Component" : "组件")
                    Text(english ? "Raw" : "原始")
                    Text(english ? "Personal" : "个人项")
                }
                .font(palette.font(8, weight: .bold))
                .foregroundStyle(palette.secondary)
                ForEach(item.components) { component in
                    GridRow {
                        Text(component.label).font(palette.font(9))
                        Text(String(format: "%.3f", component.rawValue)).font(palette.mono(9))
                        Text(component.contribution.map { String(format: "%.3f", $0) } ?? "—")
                            .font(palette.mono(9))
                            .foregroundStyle(component.contribution == nil ? palette.secondary : palette.ink)
                    }
                    .foregroundStyle(palette.ink)
                    .accessibilityElement(children: .combine)
                }
            }
            if item.components.isEmpty {
                Text(english ? "No components recorded." : "没有记录组件。")
                    .font(palette.font(9))
                    .foregroundStyle(palette.secondary)
            }
        }
    }

    private func traceTable(_ trace: RecommendationExplanationTrace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(english ? "Recorded trace" : "实际排序轨迹")
                .font(palette.font(9, weight: .bold))
                .foregroundStyle(palette.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(trace.rows(model.language)) { row in
                    GridRow {
                        Text(row.label)
                            .font(palette.font(9, weight: row.emphasis ? .semibold : .regular))
                            .foregroundStyle(row.emphasis ? palette.ink : palette.secondary)
                            .lineLimit(2)
                        Text(row.value)
                            .font(palette.mono(9, weight: row.emphasis ? .semibold : .regular))
                            .foregroundStyle(palette.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
