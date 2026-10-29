import SwiftUI
import AppKit

/// 开发者页签：更新测试、AI 模型展开、爆款推送测试。
struct DeveloperTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var readerModeURLs = ReaderModeSelfCheck.defaultURLs.joined(separator: "\n")
    @State private var readerModeCheck = ReaderModeSelfCheck()

    var body: some View {
        Form {
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
    }

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
