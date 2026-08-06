import SwiftUI
import UserNotifications

/// 提醒页签：定时推送、爆款推送、联网搜索、关键词监控。
/// 标准主题下使用 Liquid Glass 胶囊/浮框；复古主题使用纸张 + 硬描边风格。
struct ReminderTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var authorized = false
    @State private var newKeyword = ""

    var body: some View {
        Form {
            Section {
                permissionRow
            } header: {
                Text("notif.permissionStatus".localized)
            }

            Section {
                Toggle("notif.hourlyPushNews".localized, isOn: Binding(
                    get: { settings.hourlyPushEnabled },
                    set: { settings.hourlyPushEnabled = $0 }
                ))
                .disabled(!authorized)

                Toggle("notif.dailyDigest".localized, isOn: Binding(
                    get: { settings.dailyPushEnabled },
                    set: { newValue in
                        settings.dailyPushEnabled = newValue
                        if newValue {
                            NotificationService.scheduleDailyPush(
                                hour: settings.dailyPushHour,
                                minute: settings.dailyPushMinute
                            )
                        } else {
                            UNUserNotificationCenter.current()
                                .removePendingNotificationRequests(withIdentifiers: ["daily-summary"])
                        }
                    }
                ))
                .disabled(!authorized)

                if settings.dailyPushEnabled {
                    HStack {
                        Text("notif.pushTime".localized)
                        Spacer()
                        DatePicker("", selection: Binding(
                            get: {
                                Calendar.current.date(from: DateComponents(
                                    hour: settings.dailyPushHour,
                                    minute: settings.dailyPushMinute
                                )) ?? Date()
                            },
                            set: { newDate in
                                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                settings.dailyPushHour = comps.hour ?? 9
                                settings.dailyPushMinute = comps.minute ?? 0
                                NotificationService.scheduleDailyPush(
                                    hour: settings.dailyPushHour,
                                    minute: settings.dailyPushMinute
                                )
                            }
                        ), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    }
                }

                Stepper(L10n.string("notif.pushCountLabel", settings.pushCount), value: Binding(
                    get: { settings.pushCount },
                    set: { settings.pushCount = max(1, min(3, $0)) }
                ), in: 1...3)
                .disabled(!authorized)
            } header: {
                Text("notif.scheduled".localized)
            } footer: {
                Text("notif.pushCount.footer".localized)
            }

            Section {
                Toggle("notif.burstPush".localized, isOn: Binding(
                    get: { settings.burstPushEnabled },
                    set: { settings.burstPushEnabled = $0 }
                ))
                .disabled(!authorized)
            } header: {
                Text("notif.burst".localized)
            } footer: {
                Text("notif.burst.footer".localized)
            }

            Section {
                Toggle("notif.webSearch".localized, isOn: Binding(
                    get: { settings.webSearchEnabled },
                    set: { settings.webSearchEnabled = $0 }
                ))

                if settings.webSearchEnabled {
                    SecureField("notif.firecrawlKey".localized, text: Binding(
                        get: { settings.firecrawlAPIKey },
                        set: { settings.firecrawlAPIKey = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("notif.webSearchHeader".localized)
            } footer: {
                Text("notif.webSearch.footer".localized)
            }

            Section {
                Toggle("notif.keywordTracking".localized, isOn: Binding(
                    get: { settings.keywordTrackingEnabled },
                    set: { settings.keywordTrackingEnabled = $0 }
                ))

                if settings.keywordTrackingEnabled {
                    keywordEditor
                }
            } header: {
                Text("notif.keywordTracking".localized)
            } footer: {
                Text("notif.keywordTracking.footer".localized)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            let status = await NotificationService.authorizationStatus()
            authorized = (status == .authorized || status == .provisional)
        }
    }

    private var permissionRow: some View {
        HStack {
            Image(systemName: authorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(authorized ? .green : .orange)
            Text(authorized ? "notif.grantedTitle".localized : "notif.notGrantedTitle".localized)
                .font(.system(size: 12))
            Spacer()
            if !authorized {
                Button("notif.openSystemSettings".localized) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
            }
        }
    }

    private var keywordEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("notif.keywordPrompt".localized)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("notif.keywordPrompt".localized, text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addKeyword)

                Button(action: addKeyword) {
                    Label("notif.keywordAdd".localized, systemImage: "plus")
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if settings.activeKeywords.isEmpty {
                Text("notif.keywordEmpty".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(settings.activeKeywords, id: \.self) { keyword in
                        keywordChip(keyword)
                    }
                }
            }
        }
        .padding(12)
        .background {
            if settings.appTheme == .retroEditorial {
                Rectangle().fill(RetroEditorialTokens.raisedPaper)
            }
        }
        .glassSettingsSurface(cornerRadius: 14)
        .overlay {
            if settings.appTheme == .retroEditorial {
                Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.2)
            }
        }
    }

    private func keywordChip(_ keyword: String) -> some View {
        HStack(spacing: 4) {
            Text(keyword)
                .font(.system(size: 11, weight: .medium))
            Button {
                removeKeyword(keyword)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("notif.keywordRemove", keyword))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if settings.appTheme == .retroEditorial {
                Rectangle().fill(RetroEditorialTokens.brick.opacity(0.12))
            }
        }
        .glassSettingsSurface(cornerRadius: 40, interactive: true)
        .overlay {
            if settings.appTheme == .retroEditorial {
                Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1)
            }
        }
    }

    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !settings.activeKeywords.contains(trimmed) else { return }
        settings.keywordList.append(trimmed)
        newKeyword = ""
    }

    private func removeKeyword(_ keyword: String) {
        settings.keywordList.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == keyword }
    }
}

/// A simple flow layout that wraps its children on multiple lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
