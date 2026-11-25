import SwiftUI

struct RecommendationDiagnosticsSettings: View {
    let diagnostics: RecommendationDiagnostics
    let english: Bool
    @State private var window = RecommendationDiagnosticWindow.week
    @State private var summary: RecommendationDiagnostics.SummaryState?
    @State private var clearPrompt = false
    @State private var refresh = 0
    @State private var cleared: Bool?

    var body: some View {
        Section {
            Toggle(copy("Record recommendation diagnostics", "记录推荐诊断"),
                   isOn: Binding(get: { diagnostics.enabled }, set: diagnostics.setEnabled))
            Text(copy("Only used for analysis on this Mac. Turn it off or clear it at any time without affecting reading.",
                      "只在本机用于分析，可随时关闭或清空，不影响正常阅读。"))
                .font(.caption).foregroundStyle(.secondary)
            if diagnostics.enabled {
                Picker(copy("Summary window", "汇总窗口"), selection: $window) {
                    Text(copy("7 days", "7 天")).tag(RecommendationDiagnosticWindow.week)
                    Text(copy("30 days", "30 天")).tag(RecommendationDiagnosticWindow.month)
                }.pickerStyle(.segmented)
                if diagnostics.canCapture {
                    switch summary {
                    case .ready(let value):
                        details(value)
                    case .insufficient(let value):
                        if let value { range(value) }
                        Text(copy("Not enough data", "数据不足")).foregroundStyle(.secondary)
                    case .unavailable:
                        unavailable
                    case .disabled, nil:
                        Text(copy("Loading summary…", "正在读取汇总…")).foregroundStyle(.secondary)
                    }
                } else if diagnostics.unavailable {
                    unavailable
                } else {
                    Text(copy("Diagnostics need active local learning.", "仅在本地学习开启且未暂停时记录；隐私阅读期间不记录。"))
                        .foregroundStyle(.secondary)
                }
                Button(copy("Refresh summary", "刷新汇总")) { refresh += 1 }
                    .disabled(!diagnostics.canCapture)
            }
            HStack {
                Button(copy("Clear diagnostics…", "清空诊断数据…")) { clearPrompt = true }
                    .disabled(diagnostics.isClearing)
                if let cleared {
                    Text(cleared ? copy("Cleared", "已清空") : copy("Could not clear diagnostics", "未能清空诊断数据"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(copy("Recommendation diagnostics", "推荐诊断"))
        }
        .task(id: RefreshKey(window: window, generation: diagnostics.permissionGeneration, refresh: refresh)) {
            summary = nil
            let value = await diagnostics.summary(window)
            guard !Task.isCancelled else { return }
            summary = value
        }
        .confirmationDialog(copy("Clear recommendation diagnostics?", "清空推荐诊断？"), isPresented: $clearPrompt) {
            Button(copy("Clear diagnostics", "清空诊断"), role: .destructive) {
                Task { cleared = await diagnostics.clear() }
            }
        } message: {
            Text(copy("Bookmarks, rules and your interest profile will not change.", "收藏、屏蔽规则和兴趣画像不会改变。"))
        }
    }

    private struct RefreshKey: Equatable {
        let window: RecommendationDiagnosticWindow
        let generation: UUID
        let refresh: Int
    }

    private var unavailable: some View {
        Text(copy("Diagnostics unavailable", "诊断暂不可用")).foregroundStyle(.secondary)
    }

    private func copy(_ en: String, _ zh: String) -> String { english ? en : zh }

    private func fraction(_ numerator: Int, _ denominator: Int) -> String {
        guard denominator > 0 else { return copy("Not enough data", "数据不足") }
        let percent = (Double(numerator) / Double(denominator)).formatted(.percent.precision(.fractionLength(0...1)))
        return "\(numerator)/\(denominator) · \(percent)"
    }

    private func range(_ value: RecommendationDiagnosticSummary) -> some View {
        let end = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: value.end) ?? value.end
        let days = "\(value.start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
        return Text(value.missingDays == 0 ? days : days + " · " +
            copy("\(value.missingDays) days incomplete", "\(value.missingDays) 天不完整（仅显示已记录样本）"))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func details(_ value: RecommendationDiagnosticSummary) -> some View {
        let opens = value.results[.opened, default: 0]
        return VStack(alignment: .leading, spacing: 4) {
            range(value)
            LabeledContent(copy("Engaged exposures (≥15 s)", "有效阅读曝光（≥15 秒）"), value: fraction(value.engagedExposures, value.exposures))
            LabeledContent(copy("Clicked exposures", "曝光点击转化"), value: fraction(value.clickedExposures, value.exposures))
            LabeledContent(copy("Click attribution", "点击归因覆盖率"), value: fraction(value.sameSnapshot + value.afterRerank, value.clicks))
            if value.clicks > 0 {
                Text(copy("Same snapshot \(value.sameSnapshot) · after rerank \(value.afterRerank) · unattributed \(value.unattributed)",
                          "同快照 \(value.sameSnapshot) · 重排后 \(value.afterRerank) · 未归因 \(value.unattributed)"))
                Text(copy("Opened \(opens) · failed \(value.results[.failed, default: 0]) · blocked \(value.results[.blocked, default: 0]) · unsettled \(value.unsettled)",
                          "成功 \(opens) · 失败 \(value.results[.failed, default: 0]) · 阻断 \(value.results[.blocked, default: 0]) · 未结算 \(value.unsettled)"))
                LabeledContent(copy("Engaged after opening", "打开后有效阅读"), value: fraction(value.engaged, opens))
                LabeledContent(copy("Adaptation known", "适配状态已知"), value: fraction(value.knownAdaptationOpens, opens))
                LabeledContent(copy("Qualified / adapted", "合格阅读／已知适配"), value: fraction(value.qualified, value.adaptedOpens))
                LabeledContent(copy("Deep / adapted", "深读／已知适配"), value: fraction(value.deep, value.adaptedOpens))
            }
            LabeledContent(copy("Negative feedback exposures", "明确负反馈曝光"), value: fraction(value.negativeExposures, value.exposures))
            if value.undo > 0 { LabeledContent(copy("Undo actions", "撤销反馈"), value: "\(value.undo)") }
            DisclosureGroup(copy("Breakdowns · engaged / exposures", "分桶 · 有效阅读／曝光")) {
                bucketLine(copy("Algorithm rank", "算法名次"),
                           zip(["1–5", "6–10", "11–20", "21+"], (0..<4).map { value.rank[$0] }).map { ($0, $1) })
                bucketLine(copy("Profile confidence", "画像置信度"),
                           zip(["0", "(0, 0.5)", "[0.5, 1]", copy("Unknown", "未知")], DiagnosticConfidence.allCases.map { value.confidence[$0] }).map { ($0, $1) })
                bucketLine(copy("Interest match", "兴趣命中"),
                           zip([copy("Untagged", "无标签"), copy("No match", "有标签未命中"), copy("Matched", "已命中")],
                               DiagnosticInterestMatch.allCases.map { value.match[$0] }).map { ($0, $1) })
            }
        }.font(.caption)
    }

    private func bucketLine(_ name: String, _ buckets: [(String, RecommendationDiagnosticSummary.Bucket?)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).fontWeight(.medium)
            ForEach(buckets.map(\.0), id: \.self) { label in
                let bucket = buckets.first { $0.0 == label }?.1
                LabeledContent(label, value: fraction(bucket?.engaged ?? 0, bucket?.exposures ?? 0))
            }
        }.padding(.vertical, 2)
    }
}
