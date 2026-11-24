import SwiftUI

/// Delivery preferences for research reports. They sit with the other push
/// channels (scheduled, burst, keyword, events); the automation that produces
/// the reports stays in AI → Research.
struct ResearchNotificationSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            Toggle("notif.research.enabled".localized, isOn: Binding(
                get: { settings.researchNotificationsEnabled },
                set: { settings.researchNotificationsEnabled = $0 }
            ))
            .onChange(of: settings.researchNotificationsEnabled) { _, enabled in
                guard !enabled else { return }
                Task { await NotificationService.withdrawPendingResearchNotifications() }
            }

            Toggle("notif.research.detail".localized, isOn: Binding(
                get: { settings.researchNotificationDetailedPreviewEnabled },
                set: { settings.researchNotificationDetailedPreviewEnabled = $0 }
            ))
            .disabled(!settings.researchNotificationsEnabled)
        } header: {
            Text("notif.research.title".localized)
        } footer: {
            Text("notif.research.footer".localized)
        }
    }
}
