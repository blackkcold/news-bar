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
                    .onChange(of: selectedProvider) { _, _ in
                        apiKeyInput = ""
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
                    .disabled((apiKeyInput.isEmpty && (settings.cachedAPIKey?.isEmpty ?? true)) || isTesting)
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
                Text("API Key 使用 AES-256-GCM 加密存储，绑定本机硬件。获取 Key: \(selectedProvider.keyRetrievalURL)")
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
            } header: {
                Text("模型设置")
            }

            Section {
                summaryLengthRow(
                    title: "Popup 摘要长度",
                    selection: Binding(
                        get: { settings.aiPopupMaxWords },
                        set: { settings.aiPopupMaxWords = $0 }
                    ),
                    presets: Array(AppSettings.validAIPopupMaxWords).sorted()
                )

                summaryLengthRow(
                    title: "Dashboard 摘要长度",
                    selection: Binding(
                        get: { settings.aiDashboardMaxWords },
                        set: { settings.aiDashboardMaxWords = $0 }
                    ),
                    presets: Array(AppSettings.validAIDashboardMaxWords).sorted()
                )
            } header: {
                Text("摘要长度")
            } footer: {
                Text("Popup 用于菜单栏快速阅读，Dashboard 用于更详细的展开阅读。")
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

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("今日已用（总计）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(settings.aiUsageText)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(settings.todayAIRequestCount >= settings.aiDailyCap ? .red : .primary)
                    }
                    ProgressView(
                        value: min(Double(settings.todayAIRequestCount), Double(settings.aiDailyCap)),
                        total: Double(settings.aiDailyCap)
                    )
                    .tint(settings.todayAIRequestCount >= settings.aiDailyCap ? .red : .blue)

                    Divider().opacity(0.3)

                    HStack {
                        Text("Popup")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(settings.aiPopupUsageText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(settings.todayPopupAIRequestCount >= settings.effectiveDailyCap(for: .popup) ? .red : .primary)
                    }
                    HStack {
                        Text("Dashboard")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(settings.aiDashboardUsageText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(settings.todayDashboardAIRequestCount >= settings.effectiveDailyCap(for: .dashboard) ? .red : .primary)
                    }
                    Text("次日重置")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("用量")
            }

            Section {
                Picker("预算模式", selection: Binding(
                    get: { settings.aiBudgetMode },
                    set: { settings.aiBudgetMode = $0 }
                )) {
                    Text("共享上限").tag(AISummaryBudgetMode.shared)
                    Text("独立上限").tag(AISummaryBudgetMode.independent)
                }
                .pickerStyle(.segmented)

                if settings.aiBudgetMode == .shared {
                    HStack {
                        Text("每日请求上限")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { settings.aiDailyCap },
                            set: { settings.aiDailyCap = $0 }
                        )) {
                            ForEach(Array(AppSettings.validAICaps).sorted(), id: \.self) { cap in
                                Text("\(cap) 次").tag(cap)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                } else {
                    summaryLengthRow(
                        title: "Popup 上限",
                        selection: Binding(
                            get: { settings.aiPopupDailyCap },
                            set: { settings.aiPopupDailyCap = $0 }
                        ),
                        presets: Array(AppSettings.validAICaps).sorted(),
                        unitLabel: "次"
                    )
                    summaryLengthRow(
                        title: "Dashboard 上限",
                        selection: Binding(
                            get: { settings.aiDashboardDailyCap },
                            set: { settings.aiDashboardDailyCap = $0 }
                        ),
                        presets: Array(AppSettings.validAICaps).sorted(),
                        unitLabel: "次"
                    )
                }
            } header: {
                Text("限额")
            } footer: {
                Text("共享上限：Popup 和 Dashboard 共用同一额度；独立上限：各自独立计算。达到上限后当日不再发起 AI 请求，次日自动重置")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("AI 总结功能会将当前新闻标题发送至您选择的 AI 提供商进行处理。我们不会记录您的原始标题内容或提示词。API Key 使用 AES-256-GCM 加密存储，绑定本机硬件。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                }
            } header: {
                Text("隐私说明")
            }
        }
        .formStyle(.grouped)
    }

    private func saveAPIKey() {
        isSaving = true
        saveResult = nil
        let sanitized = SecurityPolicies.sanitizeUserInput(apiKeyInput)
        let account = selectedProvider.apiKeyAccount()
        Task {
            let store = EncryptedKeyStore()
            let success = await store.saveAPIKey(sanitized, account: account)
            await MainActor.run {
                if success {
                    settings.cachedAPIKey = sanitized
                    settings.onePasswordRef = onePasswordRef
                    apiKeyInput = ""
                    saveResult = "已保存"
                    NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
                } else {
                    saveResult = "保存失败，请重试"
                }
                isSaving = false
            }
        }
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
            Task {
                let store = EncryptedKeyStore()
                let success = await store.saveAPIKey(key, account: account)
                await MainActor.run {
                    if success {
                        settings.cachedAPIKey = key
                        NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
                    }
                    onePasswordResult = success ? "加载成功，已保存" : "保存失败，请重试"
                }
            }
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
                let rawInput = apiKeyInput
                let apiKey: String
                if !rawInput.isEmpty {
                    apiKey = SecurityPolicies.sanitizeUserInput(rawInput)
                } else if let cachedAPIKey = settings.cachedAPIKey, !cachedAPIKey.isEmpty {
                    apiKey = cachedAPIKey
                } else {
                    testResult = "请先输入或保存 API Key"
                    isTesting = false
                    return
                }
                guard !apiKey.isEmpty else {
                    testResult = "API Key 不能为空"
                    isTesting = false
                    return
                }
                AISummaryService.initBudget(
                    target: .popup,
                    mode: settings.aiBudgetMode,
                    baseline: 0,
                    cap: settings.effectiveDailyCap(for: .popup)
                )
                let result = try await AISummaryService.summarize(
                    items: testItems,
                    maxWords: 30,
                    provider: selectedProvider,
                    model: settings.aiModel,
                    apiKey: apiKey,
                    target: .popup,
                    budgetMode: settings.aiBudgetMode
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
                case .parseFailedWithDetail(let detail):
                    testResult = "响应解析失败：\(detail)"
                default:
                    testResult = "未知错误"
                }
            } catch let error as URLError {
                NSLog("[AITab] testConnection URLError: %@", error.localizedDescription)
                switch error.code {
                case .timedOut:
                    testResult = "连接超时（30s），请检查网络或代理"
                case .notConnectedToInternet:
                    testResult = "无网络连接"
                case .cannotFindHost:
                    testResult = "无法解析服务器：\(selectedProvider.baseURL)"
                case .networkConnectionLost:
                    testResult = "网络连接中断"
                default:
                    testResult = "网络错误：\(error.localizedDescription)"
                }
            } catch let error as DecodingError {
                NSLog("[AITab] testConnection DecodingError: %@", error.localizedDescription)
                testResult = "服务器返回格式异常，请检查模型是否可用"
            } catch {
                NSLog("[AITab] testConnection failed: %@", error.localizedDescription)
                testResult = "连接失败：\(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    private func summaryLengthRow(title: String, selection: Binding<Int>, presets: [Int], unitLabel: String = "字") -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(presets, id: \.self) { value in
                    Text("\(value) \(unitLabel)").tag(value)
                }
            }
            .labelsHidden()
            .frame(width: 92)
        }
    }
}
