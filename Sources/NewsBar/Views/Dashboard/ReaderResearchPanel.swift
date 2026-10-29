import SwiftUI

struct ReaderResearchPanel: View {
    let model: ReaderResearchPanelModel
    let language: AppLanguage
    let onClose: () -> Void
    let onOpen: (String) -> Void
    let onVerify: () -> Void
    let canVerify: Bool

    private var english: Bool { language == .en }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(english ? "Research" : "研究")
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel(english ? "Close research" : "关闭研究侧栏")
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let entry = model.match, let record = model.record {
                        matchedCard(entry, record: record)
                    } else {
                        Text(english ? "No research found for this page." : "未找到与当前页面相关的研究。")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    Text(english ? "Recent research" : "最近研究")
                        .font(.subheadline.weight(.semibold))
                    if model.recent.isEmpty {
                        Text(english ? "No recent research" : "暂无研究记录")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.recent) { entry in
                        Button { onOpen(entry.id) } label: {
                            ResearchListRow(entry: entry, isSelected: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            Divider()
            Button(action: onVerify) {
                Label(english ? "Verify this page" : "对当前页面发起核查", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canVerify)
            .padding(16)
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .shadow(color: .black.opacity(0.14), radius: 12, x: -3)
        .accessibilityElement(children: .contain)
    }

    private func matchedCard(_ entry: ResearchIndexEntry, record: ResearchRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(entry.status.isActive ? Color.orange : Color.accentColor)
                    .frame(width: 7, height: 7).accessibilityHidden(true)
                Text(entry.topic).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 0)
            }
            Text(L10n.string("research.status.\(entry.status.rawValue)", language: language))
                .font(.caption).foregroundStyle(.secondary)
            if let report = record.report {
                Text(ResearchNotificationSummary.make(report: report, language: language))
                    .font(.callout).lineLimit(3)
                HStack {
                    if let verdict = entry.verdict {
                        Text(L10n.string("research.verdict.\(verdict.rawValue)", language: language))
                        Text("\(entry.strength)/4")
                    }
                    Text(english ? "\(report.evidence.count) evidence items" : "\(report.evidence.count) 条证据")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if entry.status.isActive {
                ProgressView().controlSize(.small)
                Text(record.run.phase == .idle || record.run.phase == .done
                     ? L10n.string("research.status.\(entry.status.rawValue)", language: language)
                     : L10n.string("research.phase.\(record.run.phase.rawValue)", language: language))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(english ? "Open report" : "打开报告") { onOpen(entry.id) }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
