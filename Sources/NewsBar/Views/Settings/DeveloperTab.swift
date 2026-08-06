import SwiftUI
import AppKit

/// 开发者页签：更新测试、AI 模型展开、爆款推送测试。
struct DeveloperTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
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

                    Toggle("burst.testWebSearch".localized, isOn: Binding(
                        get: { settings.burstTestWebSearchEnabled },
                        set: { settings.burstTestWebSearchEnabled = $0 }
                    ))

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
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
