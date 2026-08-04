import SwiftUI

struct AITab: View {
    @Environment(AppSettings.self) private var settings

    @State private var selectedProviderID: String
    @State private var apiKeyInput = ""
    @State private var onePasswordRef = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var saveResult: String?
    @State private var onePasswordResult: String?
    @State private var isLoadingFrom1Password = false
    @State private var showCustomEditor = false
    @State private var editingCustom: CustomAIProviderConfig?
    @State private var pendingCustomDeletion: CustomAIProviderConfig?

    init() {
        let saved = UserDefaults.standard.string(forKey: "aiProvider") ?? AIProvider.deepseek.rawValue
        _selectedProviderID = State(initialValue: saved)
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
                    get: { selectedProviderID },
                    set: { newProvider in
                        selectedProviderID = newProvider
                        settings.aiProvider = newProvider
                        settings.aiModel = settings.providerDefaultModel(forID: newProvider)
                        settings.cachedAPIKey = nil
                        apiKeyInput = ""
                        testResult = nil
                        saveResult = nil
                    }
                )) {
                    ForEach(settings.providerOptions, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }

                HStack {
                    Button {
                        editingCustom = nil
                        showCustomEditor = true
                    } label: {
                        Label("添加自定义提供商", systemImage: "plus.circle")
                    }
                    .font(.caption)
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
                    .controlSize(.small)

                    Spacer()

                    if settings.isUsingCustomProvider, let custom = settings.selectedCustomProvider {
                        Button {
                            editingCustom = custom
                            showCustomEditor = true
                        } label: {
                            Text("编辑 \(custom.name)")
                        }
                        .font(.caption)
                        .buttonStyle(EditorialActionButtonStyle(compact: true))
                        .controlSize(.small)

                        Button {
                            pendingCustomDeletion = custom
                        } label: {
                            Text("删除")
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("AI 提供商")
            } footer: {
                if settings.isUsingCustomProvider {
                    Text("当前为自定义提供商，可在上方编辑或删除。")
                }
            }

            Section {
                SecureField(settings.providerApiKeyPlaceholder(forID: selectedProviderID), text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: selectedProviderID) { _, _ in
                        apiKeyInput = ""
                    }

                HStack {
                    Button {
                        saveAPIKey()
                    } label: {
                        Text(isSaving ? "保存中..." : "保存")
                    }
                    .disabled(apiKeyInput.isEmpty || isSaving)
                    .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                    .controlSize(.small)

                    Button {
                        testConnection()
                    } label: {
                        Text(isTesting ? "测试中..." : "测试连接")
                    }
                    .disabled((apiKeyInput.isEmpty && (settings.cachedAPIKey?.isEmpty ?? true)) || isTesting)
                    .buttonStyle(EditorialActionButtonStyle(compact: true))
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
                Text("API Key 使用 AES-256-GCM 加密存储，绑定本机硬件。获取 Key: \(settings.providerKeyRetrievalURL(forID: selectedProviderID))")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(settings.providerOnePasswordHint(forID: selectedProviderID), text: $onePasswordRef)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onAppear {
                            if onePasswordRef.isEmpty {
                                onePasswordRef = settings.onePasswordRef
                            }
                        }
                        .onChange(of: selectedProviderID) { _, _ in
                            onePasswordRef = settings.onePasswordRef
                        }

                    HStack {
                        Button {
                            loadFrom1Password()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "key.horizontal")
                                Text(isLoadingFrom1Password ? "加载中..." : "从 1Password 加载")
                            }
                        }
                        .disabled(onePasswordRef.isEmpty || isLoadingFrom1Password)
                        .buttonStyle(EditorialActionButtonStyle(compact: true))
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
                    ForEach(settings.providerModels(forID: selectedProviderID), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            } header: {
                Text("模型设置")
            } footer: {
                if !settings.isUsingCustomProvider && !settings.showAllAIModels {
                    Text("默认折叠为 DeepSeek 系模型；可在「通用 → 开发者选项」开启「显示全部 AI 模型」查看供应商全部模型。")
                }
            }

            Section {
                summaryLengthRow(
                    title: "共享摘要长度",
                    selection: Binding(
                        get: { settings.aiDashboardMaxWords },
                        set: { settings.aiDashboardMaxWords = $0 }
                    ),
                    presets: Array(AppSettings.validAIDashboardMaxWords).sorted()
                )
            } header: {
                Text("摘要长度")
            } footer: {
                Text("Popup 和 Dashboard 共用一次生成结果；Popup 每类最多显示 2 条，Dashboard 显示完整简报。")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("费用说明")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(settings.providerPricingInfo(forID: selectedProviderID), id: \.title) { item in
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

                    Text("同一份摘要同时服务 Popup 与 Dashboard，不重复计费。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("次日重置")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("用量")
            }

            Section {
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
            } header: {
                Text("限额")
            } footer: {
                Text("共享摘要达到上限后当日不再发起 AI 请求，次日自动重置。")
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
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showCustomEditor) {
            CustomAIProviderEditor(provider: editingCustom) { saved in
                editingCustom = nil
                showCustomEditor = false
                if let saved, !saved.id.isEmpty {
                    let customID = "custom:\(saved.id)"
                    selectedProviderID = customID
                    settings.aiProvider = customID
                    settings.aiModel = settings.providerDefaultModel(forID: customID)
                    settings.cachedAPIKey = nil
                    apiKeyInput = ""
                    testResult = nil
                    saveResult = nil
                }
            }
            .environment(settings)
            .frame(minWidth: 460, minHeight: 460)
        }
        .confirmationDialog(
            "删除自定义提供商？",
            isPresented: Binding(
                get: { pendingCustomDeletion != nil },
                set: { if !$0 { pendingCustomDeletion = nil } }
            ),
            presenting: pendingCustomDeletion
        ) { custom in
            Button("删除 \(custom.name)", role: .destructive) {
                deleteCustomProvider(custom)
            }
            Button("取消", role: .cancel) { }
        } message: { custom in
            Text("将从列表中移除“\(custom.name)”及其 API Key。此操作不可恢复。")
        }
    }

    private func deleteCustomProvider(_ custom: CustomAIProviderConfig) {
        settings.customAIProviders.removeAll { $0.id == custom.id }
        pendingCustomDeletion = nil
        if settings.isUsingCustomProvider == false, settings.aiProvider == "custom:\(custom.id)" {
            settings.aiProvider = AIProvider.deepseek.rawValue
            selectedProviderID = AIProvider.deepseek.rawValue
            settings.aiModel = settings.providerDefaultModel(forID: selectedProviderID)
            settings.cachedAPIKey = nil
        }
    }

    private func saveAPIKey() {
        isSaving = true
        saveResult = nil
        let sanitized = SecurityPolicies.sanitizeUserInput(apiKeyInput)
        let account = settings.activeAPIKeyAccount
        Task {
            let store = EncryptedKeyStore()
            let success = await store.saveAPIKey(sanitized, account: account)
            await MainActor.run {
                if success {
                    settings.cachedAPIKey = sanitized
                    settings.onePasswordRef = onePasswordRef
                    apiKeyInput = ""
                    saveResult = "已保存"
                    UserDefaults.standard.set(true, forKey: "hasAIKey-\(account)")
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
        guard OnePasswordService.isValidReference(onePasswordRef) else {
            onePasswordResult = "格式错误：应以 op:// 开头，格式为 op://Vault/Item/Field"
            return
        }

        settings.onePasswordRef = onePasswordRef
        isLoadingFrom1Password = true
        onePasswordResult = nil

        Task {
            do {
                let key = try await OnePasswordService.readSecretAsync(reference: onePasswordRef)
                let account = settings.activeAPIKeyAccount
                let store = EncryptedKeyStore()
                let success = await store.saveAPIKey(key, account: account)
                await MainActor.run {
                    if success {
                        apiKeyInput = key
                        settings.cachedAPIKey = key
                        NotificationCenter.default.post(name: .apiKeyConfigured, object: nil)
                    }
                    onePasswordResult = success ? "加载成功，已保存" : "保存失败，请重试"
                    isLoadingFrom1Password = false
                }
            } catch OnePasswordError.notInstalled {
                await MainActor.run {
                    onePasswordResult = "1Password CLI 未安装，请运行: brew install 1password-cli"
                    isLoadingFrom1Password = false
                }
            } catch OnePasswordError.timeout {
                await MainActor.run {
                    onePasswordResult = "超时：请先解锁 1Password 桌面应用"
                    isLoadingFrom1Password = false
                }
            } catch OnePasswordError.readFailed {
                await MainActor.run {
                    onePasswordResult = "读取失败：请检查引用格式和权限"
                    isLoadingFrom1Password = false
                }
            } catch OnePasswordError.invalidReference {
                await MainActor.run {
                    onePasswordResult = "格式错误：应以 op:// 开头，格式为 op://Vault/Item/Field"
                    isLoadingFrom1Password = false
                }
            } catch {
                NSLog("[AITab] loadFrom1Password failed: %@", error.localizedDescription)
                await MainActor.run {
                    onePasswordResult = "未知错误"
                    isLoadingFrom1Password = false
                }
            }
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
                    connection: settings.resolvedAIConnection,
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
                    testResult = "无法解析服务器：\(settings.resolvedAIConnection.baseURL)"
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

private struct CustomAIProviderEditor: View {
    @Environment(AppSettings.self) private var settings
    let provider: CustomAIProviderConfig?
    let onSaved: (CustomAIProviderConfig?) -> Void

    @State private var name: String
    @State private var baseURL: String
    @State private var modelsText: String
    @State private var defaultModel: String
    @State private var isAnthropicFormat = false
    @State private var authHeaderName: String
    @State private var authHeaderPrefix: String
    @State private var apiVersion: String
    @State private var pricingNote: String
    @State private var errorMessage: String?

    init(provider: CustomAIProviderConfig?, onSaved: @escaping (CustomAIProviderConfig?) -> Void) {
        self.provider = provider
        self.onSaved = onSaved
        _name = State(initialValue: provider?.name ?? "")
        _baseURL = State(initialValue: provider?.baseURL ?? "")
        _modelsText = State(initialValue: (provider?.models ?? []).joined(separator: "\n"))
        _defaultModel = State(initialValue: provider?.defaultModel ?? "")
        _isAnthropicFormat = State(initialValue: provider?.responseFormat == .anthropic)
        _authHeaderName = State(initialValue: provider?.authHeaderName ?? "Authorization")
        _authHeaderPrefix = State(initialValue: provider?.authHeaderPrefix ?? "Bearer ")
        _apiVersion = State(initialValue: provider?.apiVersion ?? "")
        _pricingNote = State(initialValue: provider?.pricingNote ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(provider == nil ? "添加自定义提供商" : "编辑提供商")
                .font(.system(size: 15, weight: .semibold))

            TextField("昵称", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("端点 URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            TextField("默认模型", text: $defaultModel)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("模型列表（每行一个 model id）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $modelsText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }

            Toggle("Anthropic 兼容格式", isOn: $isAnthropicFormat)

            if isAnthropicFormat {
                TextField("认证头名称（默认 x-api-key）", text: $authHeaderName)
                    .textFieldStyle(.roundedBorder)
                TextField("认证前缀（默认空）", text: $authHeaderPrefix)
                    .textFieldStyle(.roundedBorder)
                TextField("API 版本（默认 2023-06-01）", text: $apiVersion)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("认证头名称（默认 Authorization）", text: $authHeaderName)
                    .textFieldStyle(.roundedBorder)
                TextField("认证前缀（默认 Bearer ）", text: $authHeaderPrefix)
                    .textFieldStyle(.roundedBorder)
            }

            TextField("计费说明（可选）", text: $pricingNote)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("取消") {
                    onSaved(nil)
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))

                Spacer()

                Button("保存") {
                    save()
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .disabled(name.isEmpty || baseURL.isEmpty || modelsText.isEmpty)
            }
        }
        .padding(20)
        .adaptiveColorScheme()
        .appThemeSurface()
    }

    private func save() {
        guard !name.isEmpty, !baseURL.isEmpty else { return }
        let models = modelsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !models.isEmpty else {
            errorMessage = "请至少填写一个模型"
            return
        }

        var normalizedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if URL(string: normalizedURL)?.scheme == nil {
            normalizedURL = "https://" + normalizedURL
        }
        guard URL(string: normalizedURL) != nil else {
            errorMessage = "端点 URL 无效"
            return
        }

        let config = CustomAIProviderConfig(
            id: provider?.id ?? UUID().uuidString,
            name: SecurityPolicies.sanitizeUserInput(name),
            baseURL: normalizedURL,
            models: models,
            defaultModel: defaultModel.trimmingCharacters(in: .whitespacesAndNewlines),
            responseFormat: isAnthropicFormat ? .anthropic : .openAI,
            authHeaderName: authHeaderName.isEmpty ? (isAnthropicFormat ? "x-api-key" : "Authorization") : authHeaderName,
            authHeaderPrefix: authHeaderPrefix,
            apiVersion: apiVersion.isEmpty ? nil : apiVersion,
            pricingNote: pricingNote.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if let existing = provider, let idx = settings.customAIProviders.firstIndex(where: { $0.id == existing.id }) {
            settings.customAIProviders[idx] = config
        } else {
            settings.customAIProviders.append(config)
        }
        onSaved(config)
    }
}
