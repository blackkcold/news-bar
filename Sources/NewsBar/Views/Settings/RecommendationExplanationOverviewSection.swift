import SwiftUI

struct ExplanationOverviewSection: View {
    let model: RecommendationExplanationModel
    let palette: ExplanationPalette
    let openInterests: () -> Void

    private var english: Bool { model.language == .en }
    private var hasSnapshot: Bool { model.snapshotProfileVersion != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCard
            if let retainedProfileNote = model.retainedProfileNote {
                ExplanationNote(text: retainedProfileNote, palette: palette, systemImage: "lock.rotation")
            }
            if let lastKnownNote = model.lastKnownNote {
                ExplanationNote(text: lastKnownNote, palette: palette, systemImage: "clock.arrow.circlepath")
            }
            statRow
            combinationCard
            if let currentProfileNote = model.currentProfileNote {
                ExplanationNote(text: currentProfileNote, palette: palette, systemImage: "waveform.path.ecg")
            }
            if let emptyReason = model.emptyReason {
                ExplanationCard(palette: palette) {
                    ExplanationNote(text: emptyReason, palette: palette, systemImage: "circle.dashed")
                }
            }
            ExplanationNote(text: model.semanticNote, palette: palette, systemImage: "brain")
            Button(action: openInterests) {
                HStack(spacing: 4) {
                    Text(english ? "See interest links" : "查看兴趣关联")
                    Image(systemName: "arrow.right")
                }
                .font(palette.font(10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.accent)
            .accessibilityHint(english ? "Switches to the interests section." : "切换到兴趣关联分段。")
        }
    }

    private var statusCard: some View {
        ExplanationCard(palette: palette) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: statusSymbol)
                        .font(palette.font(12, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text(model.statusHeadline)
                        .font(palette.font(13, weight: .bold))
                        .foregroundStyle(palette.ink)
                    Spacer(minLength: 0)
                    Text(english ? "state v\(model.currentStateVersion)" : "当前状态 v\(model.currentStateVersion)")
                        .font(palette.mono(9))
                        .foregroundStyle(palette.secondary)
                }
                Text(model.storageErrorNote ?? model.statusDetail)
                    .font(palette.font(10))
                    .foregroundStyle(model.storageErrorNote == nil ? palette.ink : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var statRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { tiles }
            VStack(spacing: 8) { tiles }
        }
    }

    @ViewBuilder
    private var tiles: some View {
        tile(
            value: model.snapshotConfidencePercent.map { "\($0)%" } ?? "—",
            label: english ? "Snapshot blend weight" : "快照混合权重",
            note: hasSnapshot
                ? (english ? "Mixture weight, not accuracy" : "混合权重，不是准确率")
                : (english ? "No snapshot yet" : "尚无快照")
        )
        tile(
            value: "\(model.dimensions.count)",
            label: english ? "Interest tags" : "兴趣标签",
            note: model.retainedProfileShown
                ? (english ? "Retained profile · not ranked" : "保留画像·未参与排序")
                : (english ? "Topics, entities and follows" : "主题、实体与手动关注")
        )
        tile(
            value: "\(followCount)",
            label: english ? "Manual follows" : "手动关注",
            note: model.retainedProfileShown
                ? (english ? "Retained profile · not ranked" : "保留画像·未参与排序")
                : (english ? "Literal keywords only" : "仅词典外字面关键词")
        )
        tile(
            value: "\(model.candidateCount)",
            label: english ? "Snapshot items" : "快照条目",
            note: model.policyVersion.map { english ? "Policy v\($0)" : "策略 v\($0)" } ?? (english ? "No snapshot yet" : "尚无快照")
        )
    }

    private var followCount: Int {
        model.dimensions.filter { $0.kind == .followed }.count
    }

    private func tile(value: String, label: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(palette.mono(17, weight: .bold))
                .foregroundStyle(palette.ink)
            Text(label)
                .font(palette.font(9, weight: .semibold))
                .foregroundStyle(palette.ink)
            Text(note)
                .font(palette.font(8))
                .foregroundStyle(palette.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(palette.shape.fill(palette.cardFill))
        .overlay { palette.shape.strokeBorder(palette.border, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value). \(note)")
    }

    private var combinationCard: some View {
        ExplanationCard(
            palette: palette,
            title: english ? "How the score is mixed" : "分数如何混合",
            subtitle: hasSnapshot
                ? (english ? "Frozen snapshot v\(model.snapshotProfileVersion ?? 0)" : "冻结快照 v\(model.snapshotProfileVersion ?? 0)")
                : (english ? "No snapshot" : "尚无快照")
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if let snapshotPercent = model.snapshotConfidencePercent {
                    row(english ? "Personal × weight" : "个人分 × 权重", "\(snapshotPercent)%")
                    row(english ? "Public baseline × (1 − weight)" : "公共基线 × (1 − 权重)", "\(100 - snapshotPercent)%")
                    row(english ? "Then subtract" : "再减去", english ? "read and reduced-topic penalties" : "已读与减少主题的惩罚")
                } else if let noSnapshotNote = model.noSnapshotNote {
                    Text(noSnapshotNote)
                        .font(palette.font(9))
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(palette.border)
                Text(model.selectionNote)
                    .font(palette.font(9))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(palette.font(10))
                .foregroundStyle(palette.ink)
            Spacer(minLength: 4)
            Text(value)
                .font(palette.mono(10, weight: .semibold))
                .foregroundStyle(palette.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch model.status {
        case .resetting: return "arrow.triangle.2.circlepath"
        case .active: return "checkmark.seal"
        case .off: return "globe"
        case .paused: return "pause.circle"
        case .privateReading: return "eye.slash"
        case .notLoaded: return "hourglass"
        case .unavailable: return "exclamationmark.triangle"
        }
    }
}
