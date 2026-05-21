import SwiftUI

struct AboutTab: View {
    @Environment(AppSettings.self) private var settings

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "newspaper.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NewsBar")
                                .font(.title3.weight(.semibold))
                            Text("版本 \(version) (\(build))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("macOS 菜单栏即时新闻聚合器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    dataSourceRow("微博热搜", "s.weibo.com")
                    dataSourceRow("B站热搜", "bilibili.com")
                    dataSourceRow("RSS 源", "用户自定义")
                }
            } header: {
                Text("数据来源")
            }

            Section {
                Button("清除所有缓存") {
                    Task {
                        let orchestrator = NewsOrchestrator()
                        await orchestrator.clearCache()
                    }
                }
                .foregroundStyle(.red)
            } header: {
                Text("数据管理")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NewsBar 不会收集任何个人信息。")
                    Text("API Key 仅存储在本地系统钥匙串中。")
                    Text("缓存数据仅保存新闻标题，不包含用户数据。")
                    Text("所有网络请求通过 HTTPS 加密传输。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("隐私说明")
            }
        }
        .formStyle(.grouped)
    }

    private func dataSourceRow(_ name: String, _ source: String) -> some View {
        HStack {
            Text(name)
                .font(.caption)
            Spacer()
            Text(source)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
