import SwiftUI
import AppKit

struct GeneralTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var logEntries: [RefreshLog.Entry] = []
    @State private var isLogExpanded = false
    @State private var copyFeedback = false

    var body: some View {
        Form {
            Section {
                Toggle("智能定时刷新", isOn: Binding(
                    get: { settings.autoRefreshEnabled },
                    set: { settings.autoRefreshEnabled = $0 }
                ))
            } header: {
                Text("刷新设置")
            } footer: {
                Text("开启后，热搜在界面可见时约每 5 分钟、后台约每 30 分钟检查；RSS 根据更新活跃度在 30 分钟至 3 小时之间自适应。低电量与休眠状态会自动降频。")
            }

            Section {
                statRow(title: "今日刷新次数", value: "\(settings.todayRefreshCount) 次")
                statRow(title: "今日 AI 调用", value: "\(settings.todayAIRequestCount) 次")
                statRow(title: "预估 AI 花费", value: settings.estimatedAICostText)
                if settings.lastRefreshTimestamp > 0 {
                    statRow(title: "最后刷新", value: formattedLastRefresh)
                }
            } header: {
                Text("刷新状态")
            } footer: {
                Text("含启动、定时和手动刷新；AI 花费仅估算 AI 总结请求，不包含微博、B站或 RSS。")
            }

            Section {
                Toggle("开机自启", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            } header: {
                Text("启动")
            }

            Section {
                Toggle("启用复古报刊编辑风", isOn: Binding(
                    get: { settings.appTheme == .retroEditorial },
                    set: { settings.appTheme = $0 ? .retroEditorial : .modern }
                ))

                HStack(spacing: 8) {
                    themeSwatch(RetroEditorialTokens.paper, label: "米白")
                    themeSwatch(RetroEditorialTokens.brick, label: "砖红")
                    themeSwatch(RetroEditorialTokens.ink, label: "墨黑")
                    Spacer()
                    Text(settings.appTheme.displayName)
                        .font(.system(size: 11, weight: .bold, design: .serif))
                        .foregroundStyle(settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : .secondary)
                }

                Picker("明暗外观", selection: Binding(
                    get: { settings.colorScheme },
                    set: { settings.colorScheme = $0 }
                )) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(settings.appTheme == .retroEditorial)
            } header: {
                Text("主题设置")
            } footer: {
                Text(settings.appTheme == .retroEditorial
                     ? "复古报刊主题固定使用米白纸张基底；关闭后恢复现代主题及明暗外观选择。"
                     : "现代主题支持跟随系统、浅色或深色；复古报刊主题使用 1960 年代编辑设计语言。")
            }

            Section {
                logSectionHeader
                if isLogExpanded {
                    logContent
                }
            } header: {
                Text("诊断")
            } footer: {
                Text("记录最近 10 次刷新行为，仅保留诊断信息（不含 Key、密码等敏感数据）。")
            }

            Section {
                Toggle("忽略版本号，强制下载最新版", isOn: Binding(
                    get: { settings.updateDevMode },
                    set: { settings.updateDevMode = $0 }
                ))
            } header: {
                Text("开发者选项")
            } footer: {
                Text("仅用于测试更新功能。开启后「检查更新」将直接获取最新 release 版本，不比对本地版本号。")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            logEntries = await RefreshLog.shared.snapshot()
        }
        .onAppear {
            settings.resetDailyStatsIfNeeded()
        }
    }

    // MARK: - Log Section

    private var logSectionHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isLogExpanded.toggle()
            }
            if isLogExpanded {
                Task {
                    logEntries = await RefreshLog.shared.snapshot()
                }
            }
        } label: {
            HStack {
                Text("刷新日志 (\(logEntries.count))")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isLogExpanded ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var logContent: some View {
        if logEntries.isEmpty {
            Text("暂无刷新记录")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
        } else {
            ForEach(Array(logEntries.reversed().enumerated()), id: \.element.id) { index, entry in
                logEntryRow(entry, index: index + 1)
            }

            HStack {
                Button {
                    Task {
                        let logText = await RefreshLog.shared.snapshotString()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(logText, forType: .string)
                        copyFeedback = true
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copyFeedback = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copyFeedback ? "已复制" : "复制最近 10 次日志")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)

                Button {
                    Task {
                        await RefreshLog.shared.clear()
                        logEntries = []
                    }
                } label: {
                    Text("清空日志")
                        .font(.system(size: 11))
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
                .tint(.red)
            }
            .padding(.top, 4)
        }
    }

    private func logEntryRow(_ entry: RefreshLog.Entry, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(formattedLogTime(entry.timestamp))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                triggerBadge(entry.trigger)
            }
            HStack(spacing: 3) {
                Text(sourcesSummary(entry.sourceResults))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            HStack(spacing: 3) {
                Text("AI: \(entry.aiBefore)→\(entry.aiAfter)")
                    .font(.system(size: 9))
                    .foregroundStyle(aiColor(entry.aiAfter))
                if let err = entry.errorSummary {
                    Text("| \(err)")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func triggerBadge(_ trigger: RefreshLog.Trigger) -> some View {
        let label: String
        let color: Color
        switch trigger {
        case .startup:   label = "启动"; color = .blue
        case .timer1h:   label = "定时"; color = .green
        case .scheduled: label = "智能调度"; color = .green
        case .wake:      label = "唤醒"; color = .cyan
        case .manual:    label = "手动"; color = .orange
        case .popoverOpen: label = "弹窗"; color = .purple
        }
        return Text(label)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .editorialClipShape(cornerRadius: 20)
    }

    private func sourcesSummary(_ results: [String: String]) -> String {
        results.map { "\($0.key):\($0.value)" }.joined(separator: " ")
    }

    private func aiColor(_ state: String) -> Color {
        if state.hasPrefix("error") { return .red }
        if state.hasPrefix("done") || state.hasPrefix("truncated") { return .purple }
        return .secondary
    }

    private func formattedLogTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - Existing Helpers

    private var formattedLastRefresh: String {
        let date = Date(timeIntervalSince1970: settings.lastRefreshTimestamp)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func themeSwatch(_ color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 18, height: 14)
                .overlay(Rectangle().stroke(RetroEditorialTokens.ink, lineWidth: 1))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("主题色 (label)")
    }
}
