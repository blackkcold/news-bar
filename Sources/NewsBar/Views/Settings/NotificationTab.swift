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
                    Text(authorized ? "通知权限已开启" : "通知权限未开启")
                        .font(.system(size: 12))
                    Spacer()
                    if !authorized {
                        Button("前往系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("权限状态")
            }

            Section {
                Toggle("每小时推送最新新闻", isOn: Binding(
                    get: { settings.hourlyPushEnabled },
                    set: { settings.hourlyPushEnabled = $0 }
                ))
                .disabled(!authorized)
            } header: {
                Text("定时推送")
            }

            Section {
                Toggle("每日摘要推送", isOn: Binding(
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
                        Text("推送时间")
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
                Text("每日推送")
            }

            Section {
                Stepper("每次推送条数: \(settings.pushCount)", value: Binding(
                    get: { settings.pushCount },
                    set: { settings.pushCount = max(1, min(3, $0)) }
                ), in: 1...3)
                .disabled(!authorized)
            } header: {
                Text("推送数量")
            } footer: {
                Text("每小时推送在每次自动刷新后发送最新内容；每日推送在指定时间发送，内容为最近一次刷新结果。")
            }
        }
        .formStyle(.grouped)
        .task {
            let status = await NotificationService.authorizationStatus()
            authorized = (status == .authorized || status == .provisional)
        }
    }
}