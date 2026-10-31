import SwiftUI
import AppKit

/// 高级页签：刷新与诊断、阅读器网络代理、开发者测试工具。
/// 原先分散在「刷新」「通用」「开发者」三个页签，都是低频但不可缺的开关。
struct AdvancedTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var logEntries: [RefreshLog.Entry] = []
    @State private var isLogExpanded = false
    @State private var copyFeedback = false
    @State private var readerModeURLs = ReaderModeSelfCheck.defaultURLs.joined(separator: "\n")
    @State private var readerModeCheck = ReaderModeSelfCheck()

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

            ReaderProxySettingsSection()

            Section {
                Button {
                    NotificationCenter.default.post(name: .fireTestNewsPush, object: nil)
                } label: {
                    Label("notif.testPush".localized, systemImage: "bell.badge")
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
            } header: {
                Text("notif.testPush.header".localized)
            } footer: {
                Text("notif.testPush.footer".localized)
            }

            Section {
                Toggle("general.forceLatest".localized, isOn: Binding(
                    get: { settings.updateDevMode },
                    set: { settings.updateDevMode = $0 }
                ))
            } header: {
                Text("settings.developer.update".localized)
            } footer: {
                Text("general.developer.footer".localized)
            }

            Section {
                Toggle("general.showAllModels".localized, isOn: Binding(
                    get: { settings.showAllAIModels },
                    set: { settings.showAllAIModels = $0 }
                ))
            } header: {
                Text("settings.developer.ai".localized)
            }

            Section {
                Toggle("burst.testMode".localized, isOn: Binding(
                    get: { settings.burstTestMode },
                    set: { settings.burstTestMode = $0 }
                ))

                if settings.burstTestMode {
                    TextField("burst.testTopic.placeholder".localized, text: Binding(
                        get: { settings.burstTestTopic },
                        set: { settings.burstTestTopic = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !settings.burstTestTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            NotificationCenter.default.post(name: .fireFakeBurstPush, object: nil)
                        }
                    }

                    HStack {
                        Button {
                            NotificationCenter.default.post(name: .fillBurstTestTopic, object: nil)
                        } label: {
                            Label("burst.testTopic.fillTop".localized, systemImage: "arrow.down.to.line")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(EditorialActionButtonStyle(compact: true))

                        Button {
                            NotificationCenter.default.post(name: .fireFakeBurstPush, object: nil)
                        } label: {
                            Label("burst.testPush".localized, systemImage: "flame.fill")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                        .disabled(settings.burstTestTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } header: {
                Text("burst.testMode".localized)
            } footer: {
                Text("burst.testMode.footer".localized)
            }

            Section {
                TextEditor(text: $readerModeURLs)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 72, maxHeight: 120)
                    .accessibilityLabel(settings.appLanguage == .en ? "Reader-mode self-check URLs, one per line" : "阅读模式自检 URL，每行一条")
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await readerModeCheck.run(urls: readerModeURLs
                                .split(separator: "\n")
                                .map(String.init))
                        }
                    } label: {
                        Label(settings.appLanguage == .en ? "Run reader-mode check" : "运行阅读模式自检", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                    .disabled(readerModeCheck.isRunning)
                    if readerModeCheck.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button(settings.appLanguage == .en ? "Reset URLs" : "恢复默认") {
                        readerModeURLs = ReaderModeSelfCheck.defaultURLs.joined(separator: "\n")
                    }
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .disabled(readerModeCheck.isRunning)
                }
                ForEach(readerModeCheck.results) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.url)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                        Text(selfCheckLine(result))
                            .font(.system(size: 10))
                            .foregroundStyle(result.ok ? .green : .orange)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(settings.appLanguage == .en
                     ? "Scores and reasons are printed to the console as READER-MODE lines. This check loads the URLs in a temporary web view; it makes no AI request."
                     : "得分与原因会以 READER-MODE 行打印到控制台。自检会在临时网页视图中真实加载这些地址，不调用 AI。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text(settings.appLanguage == .en ? "Reader mode self-check" : "阅读模式自检")
            } footer: {
                Text(settings.appLanguage == .en
                     ? "The automated suite tests only the Swift parser with golden fixtures. The JS extractor needs a real page, so this run is manual."
                     : "自动化测试只覆盖 Swift 侧解析与固定样本；JS 抽取器需要真实页面，因此这里手动运行。")
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

    // MARK: - Refresh diagnostics

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

    // MARK: - Reader-mode self-check

    private func selfCheckLine(_ result: ReaderModeSelfCheck.Result) -> String {
        let status = result.ok
            ? (settings.appLanguage == .en ? "ok" : "成功")
            : (settings.appLanguage == .en ? "failed" : "失败")
        let reason = result.reason.map { " · \($0)" } ?? ""
        return String(
            format: "%@ · score %d · %@ · %d blocks · %d chars · %.2fs%@",
            status,
            result.score,
            result.selector ?? "-",
            result.blocks,
            result.characters,
            result.seconds,
            reason
        )
    }
}
