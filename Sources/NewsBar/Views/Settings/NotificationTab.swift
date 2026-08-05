import SwiftUI
import UserNotifications

struct NotificationTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var authorized = false

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text("notif.permissionStatus".localized)
            }

            Section {
                Toggle("notif.hourlyPushNews".localized, isOn: Binding(
                    get: { settings.hourlyPushEnabled },
                    set: { settings.hourlyPushEnabled = $0 }
                ))
                .disabled(!authorized)
            } header: {
                Text("notif.scheduled".localized)
            }

            Section {
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
            } header: {
                Text("notif.dailyPush".localized)
            }

            Section {
                Stepper(L10n.string("notif.pushCountLabel", settings.pushCount), value: Binding(
                    get: { settings.pushCount },
                    set: { settings.pushCount = max(1, min(3, $0)) }
                ), in: 1...3)
                .disabled(!authorized)
            } header: {
                Text("notif.pushQuantity".localized)
            } footer: {
                Text("notif.pushCount.footer".localized)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            let status = await NotificationService.authorizationStatus()
            authorized = (status == .authorized || status == .provisional)
        }
    }
}
