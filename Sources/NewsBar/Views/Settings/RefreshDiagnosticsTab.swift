import SwiftUI
import AppKit

/// 刷新与诊断页签：智能刷新开关、刷新状态、诊断日志。
struct RefreshDiagnosticsTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var logEntries: [RefreshLog.Entry] = []
    @State private var isLogExpanded = false
    @State private var copyFeedback = false

    var body: some View {
        Form {
            Section {
                Toggle("general.autoRefresh".localized, isOn: Binding(
                    get: { settings.autoRefreshEnabled },
                    set: { settings.autoRefreshEnabled = $0 }
                ))
            } header: {
                Text("general.refresh".localized)
            } footer: {
                Text("general.autoRefresh.footer".localized)
            }

            Section {
                statRow(title: "general.todayRefreshCount".localized, value: "\(settings.todayRefreshCount) \("unit.times".localized)")
                statRow(title: "general.todayAICount".localized, value: "\(settings.todayAIRequestCount) \("unit.times".localized)")
                statRow(title: "general.estimatedAICost".localized, value: settings.estimatedAICostText)
                if settings.lastRefreshTimestamp > 0 {
                    statRow(title: "general.lastRefresh".localized, value: formattedLastRefresh)
                }
            } header: {
                Text("general.status".localized)
            } footer: {
                Text("general.status.footer".localized)
            }

            Section {
                logSectionHeader
                if isLogExpanded {
                    logContent
                }
            } header: {
                Text("general.diagnostics".localized)
            } footer: {
                Text("general.diagnostics.footer".localized)
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
                Text("general.refreshLog".localized + " (\(logEntries.count))")
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
            Text("general.noLogs".localized)
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
                        Text(copyFeedback ? "general.copied".localized : "general.copyLogs".localized)
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
                    Text("general.clearLogs".localized)
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
        case .startup:   label = "general.log.trigger.startup".localized; color = .blue
        case .timer1h:   label = "general.log.trigger.timer1h".localized; color = .green
        case .scheduled: label = "general.log.trigger.scheduled".localized; color = .green
        case .wake:      label = "general.log.trigger.wake".localized; color = .cyan
        case .manual:    label = "general.log.trigger.manual".localized; color = .orange
        case .popoverOpen: label = "general.log.trigger.popoverOpen".localized; color = .purple
        case .burst:     label = "general.log.trigger.burst".localized; color = .red
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
}
