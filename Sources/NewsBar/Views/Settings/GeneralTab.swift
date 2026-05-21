import SwiftUI

struct GeneralTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                Toggle("定时刷新（每小时自动刷新一次）", isOn: Binding(
                    get: { settings.autoRefreshEnabled },
                    set: { settings.autoRefreshEnabled = $0 }
                ))
            } header: {
                Text("刷新设置")
            } footer: {
                Text("开启后，App 启动 5 秒后自动获取最新新闻，之后每小时刷新一次。")
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
                Picker("主题", selection: Binding(
                    get: { settings.colorScheme },
                    set: { settings.colorScheme = $0 }
                )) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("外观")
            }
        }
        .formStyle(.grouped)
    }
}
