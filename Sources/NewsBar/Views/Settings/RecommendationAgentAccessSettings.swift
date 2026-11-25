import Foundation
import NewsBarAgentProtocol
import SwiftUI

/// Short-lived, explicit consent for `newsbarctl recommend summary`.
///
/// The section stays visible when diagnostics are off so the gate is
/// discoverable, but it never enables itself and never offers a background
/// "remember this" switch.
struct RecommendationAgentAccessSettings: View {
    let diagnostics: RecommendationDiagnostics
    let english: Bool
    let agentAccessEnabled: Bool

    @State private var authorizing = false

    var body: some View {
        Section {
            if !agentAccessEnabled {
                Text(copy(
                    "Agent access is off in Advanced settings. Turn it on there before granting read access.",
                    "总 Agent 访问已在「高级」中关闭。请先在那里开启，再授予读取权限。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if !diagnostics.canCapture {
                Text(copy(
                    "Turn on recommendation diagnostics and keep local learning active to grant access.",
                    "请先开启推荐诊断，并保持本地学习可用，才能授予读取权限。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let grant = diagnostics.agentGrant {
                granted(grant)
            } else {
                Button(copy("Allow agent read access…", "允许 Agent 读取汇总…")) {
                    authorizing = true
                }
                Text(copy(
                    "Read-only. One fixed summary for a chosen window, for 15 minutes. A CLI request never launches NewsBar.",
                    "只读。按所选窗口生成一份固定汇总，授权 15 分钟。CLI 请求不会唤起 NewsBar。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text(copy("Agent read access", "Agent 读取权限"))
        } footer: {
            Text(copy(
                "The Agent receives aggregate counts only: no titles, URLs, sources, interest words or per-item events. Delivered data cannot be recalled from an agent that already received it.",
                "Agent 只会收到聚合计数：不含标题、链接、来源、兴趣词或逐条事件。已经交付给 Agent 的数据无法收回。"
            ))
        }
        .sheet(isPresented: $authorizing) {
            RecommendationAgentAuthorizationSheet(diagnostics: diagnostics, english: english)
        }
    }

    @ViewBuilder
    private func granted(_ grant: RecommendationAgentAccess.Grant) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = max(0, grant.expiresAt - ProcessInfo.processInfo.systemUptime)
            if remaining > 0 {
                LabeledContent(copy("Time remaining", "剩余时间"), value: duration(remaining))
                Text("\(windowLabel(grant.window)) · \(range(grant.response))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let counts = grant.response.counts {
                    Text(copy(
                        "\(counts.qualifiedExposures) qualified exposures · \(counts.exposuresWithEngagedRead) with engaged reading",
                        "\(counts.qualifiedExposures) 条合格曝光 · \(counts.exposuresWithEngagedRead) 条有效阅读"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(copy(
                        "Fewer than 20 qualified exposures; only the date range is shared.",
                        "合格曝光不足 20 条，只共享日期范围。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(copy(
                    "Already delivered summaries cannot be recalled. Revoking stops the next delivery only.",
                    "已交付的汇总无法收回；撤销只阻止后续交付。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(copy("Revoke access", "撤销访问"), role: .destructive) {
                    diagnostics.revokeAgentAccess()
                }
            } else {
                Text(copy(
                    "Access expired. Authorize again to read a new summary.",
                    "授权已到期。如需读取新的汇总，请重新授权。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(copy("Allow agent read access…", "允许 Agent 读取汇总…")) {
                    authorizing = true
                }
            }
        }
    }

    private func copy(_ en: String, _ zh: String) -> String { english ? en : zh }

    private func windowLabel(_ window: RecommendationSummaryWindow) -> String {
        copy("\(window.days) days", "\(window.days) 天")
    }

    private func range(_ reply: RecommendationSummaryReply) -> String {
        guard let from = reply.availableFromDay, let through = reply.completeThroughDay else {
            return copy("No complete day yet", "暂无完整日")
        }
        let base = "\(from) – \(through)"
        return reply.coverage == .partial
            ? base + " · " + copy("some days incomplete", "部分日期不完整")
            : base
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct RecommendationAgentAuthorizationSheet: View {
    let diagnostics: RecommendationDiagnostics
    let english: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var window = RecommendationDiagnosticWindow.week
    @State private var reply: RecommendationSummaryReply?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copy("Allow agent read access", "允许 Agent 读取汇总"))
                .font(.headline)
            Picker(copy("Window", "窗口"), selection: $window) {
                Text(copy("7 days", "7 天")).tag(RecommendationDiagnosticWindow.week)
                Text(copy("30 days", "30 天")).tag(RecommendationDiagnosticWindow.month)
            }
            .pickerStyle(.segmented)

            if let reply {
                if canGrant(reply) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(copy("Range", "范围"), value: range(reply))
                        if let counts = reply.counts {
                            LabeledContent(
                                copy("Qualified exposures", "合格曝光"),
                                value: "\(counts.qualifiedExposures)"
                            )
                            LabeledContent(
                                copy("Engaged reading", "有效阅读"),
                                value: "\(counts.exposuresWithEngagedRead)"
                            )
                        } else {
                            Text(copy(
                                "Fewer than 20 qualified exposures. The Agent will see insufficient_data and the date range, not counts.",
                                "合格曝光不足 20 条。Agent 只会看到 insufficient_data 与日期范围，不会看到计数。"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Text(copy(
                        "The Agent receives exactly this fixed summary. It may request it repeatedly for 15 minutes, but the numbers do not change.",
                        "Agent 将收到这份固定汇总。15 分钟内可重复读取，但数字不会变化。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(copy(
                        "Data already delivered cannot be recalled. Access ends automatically after 15 minutes or when you revoke it.",
                        "已经交付的数据无法收回。授权会在 15 分钟后自动结束，也可随时撤销。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(message(reply.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if loading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(copy("Summary unavailable.", "汇总暂不可用。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(copy("Cancel", "取消")) { dismiss() }
                Button(copy("Allow for 15 minutes", "允许 15 分钟")) { allow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(reply.map(canGrant) != true)
            }
        }
        .padding(22)
        .frame(width: 440)
        .task(id: window) { await load() }
    }

    private func load() async {
        loading = true
        reply = nil
        error = nil
        let value = await diagnostics.agentReply(window.summaryWindow)
        guard !Task.isCancelled else { return }
        reply = value
        loading = false
    }

    private func allow() {
        guard let reply else { return }
        guard diagnostics.grantAgentAccess(reply) else {
            error = copy(
                "Diagnostics changed before the grant was confirmed. Review the summary and try again.",
                "确认前诊断状态已变化。请重新查看汇总后再试。"
            )
            return
        }
        dismiss()
    }

    private func canGrant(_ reply: RecommendationSummaryReply) -> Bool {
        reply.status == .ok || reply.status == .insufficientData
    }

    private func copy(_ en: String, _ zh: String) -> String { english ? en : zh }

    private func range(_ reply: RecommendationSummaryReply) -> String {
        guard let from = reply.availableFromDay, let through = reply.completeThroughDay else {
            return copy("No complete day yet", "暂无完整日")
        }
        let base = "\(from) – \(through)"
        return reply.coverage == .partial
            ? base + " · " + copy("some days incomplete", "部分日期不完整")
            : base
    }

    private func message(_ status: RecommendationSummaryReply.Status) -> String {
        switch status {
        case .notAuthorized, .rateLimited:
            copy("Diagnostics must be on and local learning active.", "需要开启诊断并保持本地学习可用。")
        case .storageUnavailable, .requestTimedOut:
            copy("Diagnostics storage is unavailable right now.", "诊断存储暂不可用。")
        case .invalidRequest, .appUnavailable:
            copy("Cannot prepare a summary right now.", "暂时无法准备汇总。")
        case .ok, .insufficientData:
            ""
        }
    }
}
