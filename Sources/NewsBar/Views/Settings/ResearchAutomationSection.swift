import SwiftUI

/// 提醒 → 爆款与研究. Automatic detection is separate from burst push: turning
/// push off must not silently stop the research archive, and vice versa.
struct ResearchAutomationSection: View {
    @Environment(AppSettings.self) private var settings
    @AppStorage("researchNotificationsEnabled") private var researchNotificationsEnabled = true
    @AppStorage("researchNotificationDetailedPreviewEnabled") private var detailedPreviewEnabled = false

    var body: some View {
        Section {
            Toggle("research.auto.enable".localized, isOn: Binding(
                get: { settings.researchAutoEnabled },
                set: { settings.researchAutoEnabled = $0 }
            ))

            Picker("research.auto.detectionLimit".localized, selection: Binding(
                get: { settings.researchDetectionLimit },
                set: { settings.researchDetectionLimit = $0 }
            )) {
                ForEach(Array(AppSettings.validResearchDetectionLimits).sorted(), id: \.self) { value in
                    Text(L10n.string("research.auto.perRound", language: settings.appLanguage, value))
                        .tag(value)
                }
            }
            .disabled(!settings.researchAutoEnabled)

            Toggle("research.auto.popoverChip".localized, isOn: Binding(
                get: { settings.researchShowPopoverChip },
                set: { settings.researchShowPopoverChip = $0 }
            ))

            Toggle("research.markReadOnOpen".localized, isOn: Binding(
                get: { settings.researchMarkReadOnOpen },
                set: { settings.researchMarkReadOnOpen = $0 }
            ))

            Toggle("research.auto.personalization".localized, isOn: Binding(
                get: { settings.researchUsePersonalization },
                set: { settings.researchUsePersonalization = $0 }
            ))
            if settings.researchUsePersonalization, !InterestController.shared.state.learningEnabled {
                Text("research.auto.personalization.off".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("research.auto.notificationSummary".localized, isOn: Binding(
                get: { settings.researchNotificationShowsSummary },
                set: { settings.researchNotificationShowsSummary = $0 }
            ))

            Toggle(
                settings.appLanguage == .en
                    ? "Research result notifications"
                    : "研究结果提醒",
                isOn: $researchNotificationsEnabled
            )
            .onChange(of: researchNotificationsEnabled) { _, enabled in
                guard !enabled else { return }
                Task { await NotificationService.withdrawPendingResearchNotifications() }
            }
            .help(settings.appLanguage == .en
                  ? "Send a notice when a useful report is ready; automatic research remains independently controlled."
                  : "报告达到可读状态时发送提醒；自动研究仍由上方单独控制。")

            Toggle(
                settings.appLanguage == .en
                    ? "Show verified detail in notifications"
                    : "在通知中显示已核验摘要",
                isOn: $detailedPreviewEnabled
            )
            .disabled(!researchNotificationsEnabled)
            .help(settings.appLanguage == .en
                  ? "Off by default. When enabled, a short verified conclusion may appear on the lock screen."
                  : "默认关闭。开启后，锁屏通知可能显示一句已核验结论。")
        } header: {
            Text("research.auto.title".localized)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("research.auto.footer".localized)
                Text(settings.appLanguage == .en
                     ? "Routine automatic research targets up to 3 items. Breaking news may add at most 2, still within the daily task cap; a cap of 1 or 2 is never exceeded."
                     : "普通日目标最多 3 项；突发最多额外加 2 项，仍受每日任务上限限制；每日上限设为 1 或 2 项时也不会突破。")
                    .foregroundStyle(.secondary)
                if let last = settings.researchLastAutomaticDecision {
                    Text(L10n.string("research.auto.lastCheck", language: settings.appLanguage, last))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
