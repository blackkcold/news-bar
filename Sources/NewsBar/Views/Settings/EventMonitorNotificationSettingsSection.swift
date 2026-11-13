import SwiftUI
import UserNotifications

struct EventMonitorNotificationSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    @State private var authorizationGranted = false
    @State private var controller: NewsEventController?

    var body: some View {
        Section {
            Toggle("event.settings.monitoring".localized, isOn: Binding(
                get: { settings.newsEventMonitoringEnabled },
                set: { settings.newsEventMonitoringEnabled = $0 }
            ))
            .onChange(of: settings.newsEventMonitoringEnabled) { _, _ in
                Task { @MainActor in
                    let controller = NewsEventController.shared(settings: settings)
                    await controller.recoverAndTick(now: Date(), sources: settings.activeSources)
                    self.controller = controller
                }
            }

            Toggle("event.settings.notifications".localized, isOn: Binding(
                get: { settings.newsEventNotificationsEnabled },
                set: { settings.newsEventNotificationsEnabled = $0 }
            ))

            Text("event.settings.independentToggles".localized)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !authorizationGranted {
                Label("event.settings.permissionNeeded".localized, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("notif.openSystemSettings".localized) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
            }

            Button {
                NotificationCenter.default.post(name: .newsEventMonitorRequested, object: nil)
            } label: {
                Label("event.settings.openCenter".localized, systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))

            budgetSummary
        } header: {
            Text("event.settings.section".localized)
        } footer: {
            Text("event.settings.footer".localized)
        }
        .task {
            let status = await NotificationService.authorizationStatus()
            authorizationGranted = status == .authorized || status == .provisional
            controller = NewsEventController.shared(settings: settings)
            await controller?.reload(now: Date())
        }
    }

    @ViewBuilder
    private var budgetSummary: some View {
        let snapshot = controller?.budgetSnapshot ?? NewsEventBudgetSnapshot()
        VStack(alignment: .leading, spacing: 7) {
            Label("event.budget.title".localized, systemImage: "gauge.with.dots.needle.67percent")
                .font(.subheadline.weight(.semibold))
            LabeledContent("event.budget.availability".localized) {
                Text(L10n.string("event.budget.\(snapshot.availability.rawValue)", language: settings.appLanguage))
            }
            if let used = snapshot.checksUsed, let limit = snapshot.checksLimit {
                LabeledContent("event.budget.checkCountLabel".localized) {
                    Text(L10n.string("event.budget.checkCount", language: settings.appLanguage, used, limit))
                        .monospacedDigit()
                }
            }
            if let resetsAt = snapshot.resetsAt {
                LabeledContent("event.budget.resets".localized) {
                    Text(resetsAt.formatted(date: .abbreviated, time: .shortened))
                        .multilineTextAlignment(.trailing)
                }
            }
            if let reason = snapshot.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("event.budget.readOnly".localized)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .newsCardSurface(cornerRadius: 10)
    }
}
