import SwiftUI

struct AITab: View {
    @Environment(AppSettings.self) private var settings

    @State private var selectedProvider: AIProvider
    @State private var apiKeyInput = ""
    @State private var onePasswordRef = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var saveResult: String?
    @State private var onePasswordResult: String?

    init() {
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "deepseek")
            ?? .deepseek
        _selectedProvider = State(initialValue: provider)
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用 AI 总结", isOn: Binding(
                    get: { settings.aiSummaryEnabled },
                    set: { settings.aiSummaryEnabled = $0 }
                ))
            } header: {
                Text("功能开关")
            }

            Section {
                Picker("提供商", selection: Binding(
                    get: { selectedProvider },
                    set: { newProvider in
                        selectedProvider = newProvider
                        settings.aiProvider = newProvider.rawValue
                        settings.aiModel = newProvider.defaultModel
                        apiKeyInput = ""
                        testResult = nil
                        saveResult = nil
                        if let key = KeychainManager.readAPIKey(account: newProvider.apiKeyAccount()) {
                            apiKeyInput = key
                        }
                    }
                )) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } header: {
                Text("AI 提供商")
            }

            Section {
                SecureField(selectedProvider.apiKeyPlaceholder, text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onAppear {
                        if apiKeyInput.isEmpty,
                           let key = KeychainManager.readAPIKey(account: selectedProvider.apiKeyAccount()) {
                            apiKeyInput = key
                        }
                    }
                    .onChange(of: selectedProvider) { _, newProvider in
                        apiKeyInput = ""
                        if let key = KeychainManager.readAPIKey(account: newProvider.apiKeyAccount()) {
                            apiKeyInput = key
                        }
                    }

                HStack {
                    Button {
                        saveAPIKey()
                    } label: {
                        Text(isSaving ? "保存中..." : "保存")
                    }
                    .disabled(apiKeyInput.isEmpty || isSaving)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        testConnection()
                    } label: {
                        Text(isTesting ? "测试中..." : "测试连接")
                    }
                    .disabled(apiKeyInput.isEmpty || isTesting)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let result = saveResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("成功") ? .green : .red)
                }

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("成功") ? .green : .red)
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("API Key 存储在系统钥匙串中，不会明文保存到磁盘。获取 Key: \(selectedProvider.keyRetrievalURL)")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(selectedProvider.onePasswordHint, text: $onePasswordRef)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onAppear {
                            if onePasswordRef.isEmpty {
                                onePasswordRef = settings.onePasswordRef
                            }
                        }
                        .onChange(of: selectedProvider) { _, _ in
                            onePasswordRef = settings.onePasswordRef
                        }

                    HStack {
                        Button {
                            loadFrom1Password()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "key.horizontal")
                                Text("从 1Password 加载")
                            }
                        }
                        .disabled(onePasswordRef.isEmpty)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if let result = onePasswordResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.contains("成功") ? .green : .orange)
                    }
                }
            } header: {
                Text("1Password 集成")
            } footer: {
                Text("格式: op://Vault/Item/Field。安装 op CLI (brew install 1password-cli) 并开启桌面集成后可使用。密钥加载后缓存 30 天。")
            }

            Section {
                Picker("模型", selection: Binding(
                    get: { settings.aiModel },
                    set: { settings.aiModel = $0 }
                )) {
                    ForEach(selectedProvider.models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }

                HStack {
                    Text("总结最大字数")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.aiMaxWords },
                        set: { settings.aiMaxWords = $0 }
                    )) {
                        Text("50 字").tag(50)
                        Text("100 字").tag(100)
                        Text("150 字").tag(150)
                        Text("200 字").tag(200)
                        Text("300 字").tag(300)
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            } header: {
                Text("模型设置")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("费用说明")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(selectedProvider.pricingInfo, id: \.title) { item in
                        Text("\(item.title): \(item.detail)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("费用说明")
            }
        }
        .formStyle(.grouped)
    }

    private func saveAPIKey() {
        isSaving = true
        saveResult = nil
        let sanitized = SecurityPolicies.sanitizeUserInput(apiKeyInput)
        let account = selectedProvider.apiKeyAccount()
        let success = KeychainManager.saveAPIKey(sanitized, account: account)
        if success {
            settings.cachedAPIKey = sanitized
            settings.onePasswordRef = onePasswordRef
            apiKeyInput = ""
            saveResult = "已保存到钥匙串"
            NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
        } else {
            saveResult = "保存失败，请检查系统钥匙串权限"
        }
        isSaving = false
    }

    private func loadFrom1Password() {
        guard !onePasswordRef.isEmpty else { return }
        guard onePasswordRef.hasPrefix("op://") else {
            onePasswordResult = "格式错误：应以 op:// 开头"
            return
        }

        settings.onePasswordRef = onePasswordRef

        do {
            let key = try OnePasswordService.readSecret(reference: onePasswordRef)
            apiKeyInput = key
            let account = selectedProvider.apiKeyAccount()
            let success = KeychainManager.saveAPIKey(key, account: account)
            if success {
                settings.cachedAPIKey = key
                NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
            }
            onePasswordResult = "加载成功，已保存到钥匙串"
        } catch OnePasswordError.notInstalled {
            onePasswordResult = "1Password CLI 未安装，请运行: brew install 1password-cli"
        } catch OnePasswordError.timeout {
            onePasswordResult = "超时：请先解锁 1Password 桌面应用"
        } catch OnePasswordError.readFailed {
            onePasswordResult = "读取失败：请检查引用格式和权限"
        } catch {
            onePasswordResult = "未知错误"
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            do {
                let testItems = [
                    NewsItem(title: "测试新闻", url: "https://example.com", source: .weibo)
                ]
                let apiKey = settings.cachedAPIKey ?? apiKeyInput
                guard !apiKey.isEmpty else {
                    testResult = "请先保存 API Key"
                    isTesting = false
                    return
                }
                let result = try await AISummaryService.summarize(
                    items: testItems,
                    maxWords: 30,
                    provider: selectedProvider,
                    model: settings.aiModel,
                    apiKey: apiKey
                )
                if !result.summary.isEmpty {
                    testResult = "连接成功"
                } else {
                    testResult = "返回为空"
                }
            } catch NewsBarError.apiKeyInvalid {
                testResult = "API Key 无效 (401)"
            } catch let error as NewsBarError {
                switch error {
                case .requestFailed:
                    testResult = "请求失败，请检查网络或模型名"
                case .invalidURL:
                    testResult = "内部错误：URL 无效"
                case .parseFailed:
                    testResult = "响应解析失败，模型可能不可用"
                default:
                    testResult = "未知错误"
                }
            } catch {
                testResult = "连接失败，请检查网络"
            }
            isTesting = false
        }
    }
}
