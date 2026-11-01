import SwiftUI

struct ReaderProxySettingsSection: View {
    @Environment(AppSettings.self) private var settings
    private let controller: ReaderProxyController
    @State private var host = ""
    @State private var port = "7890"
    @State private var username = "nikki"
    @State private var password = ""
    @State private var acceptsRisk = false
    @State private var isWorking = false
    @State private var result: String?
    private var english: Bool { settings.appLanguage == .en }

    init() { controller = .shared }
    init(controller: ReaderProxyController) { self.controller = controller }

    var body: some View {
        Section {
            Picker(english ? "Reader network" : "阅读器网络", selection: Binding(get: { controller.mode }, set: { controller.mode = $0 })) {
                Text(english ? "Automatic (recommended)" : "自动跟随系统网络（推荐）").tag(ReaderNetworkMode.strict)
                Text(english ? "Trusted HTTP CONNECT proxy" : "受信任 HTTP CONNECT 代理").tag(ReaderNetworkMode.trustedProxy)
            }
            if controller.mode == .strict {
                automaticNetworkStatus
            }
            if controller.mode == .trustedProxy {
                TextField(english ? "LAN IPv4 address" : "局域网 IPv4 地址", text: $host)
                TextField(english ? "Port" : "端口", text: $port)
                TextField(english ? "Proxy username" : "代理账号", text: $username)
                SecureField(english ? "Password (blank: use saved credential)" : "代理密码（留空复用已保存凭据）", text: $password)
                Label(controller.isAuthorized
                      ? (english ? "Authorized for this network; reopen the article" : "已授权本次网络，请重新打开文章")
                      : (english ? "Not authorized; reader connections are paused" : "尚未授权，阅读器连接已暂停"),
                      systemImage: controller.isAuthorized ? "checkmark.shield" : "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if let endpoint = controller.endpoint, controller.isAuthorized {
                    Text(verbatim: english ? "Active proxy: \(endpoint.host):\(endpoint.port)" : "当前代理：\(endpoint.host):\(endpoint.port)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(english ? "I trust this proxy on the current network and accept the limitations below" : "我信任当前网络的这台代理，并接受下述限制", isOn: $acceptsRisk)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Text(english
                     ? "The proxy resolves website destinations. NewsBar cannot verify the final IP or prevent a trusted proxy from reaching private networks. HTTP proxy credentials are not TLS-protected on the LAN. Use only on a trusted network. Authorization expires on network changes, sleep or app restart."
                     : "网站目标由代理解析，NewsBar 无法核验最终 IP，也无法阻止受信任代理访问私网。HTTP 代理口令在局域网链路上不受 TLS 保护，仅限可信网络。网络变化、睡眠或重启应用会撤销授权。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(english ? "Save & authorize this network" : "保存并授权本次网络") { authorize() }
                        .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                        .disabled(!acceptsRisk || !controller.networkAvailable || isWorking)
                    Button(english ? "Test connection" : "测试连接") { probe() }
                        .buttonStyle(EditorialActionButtonStyle(compact: true))
                        .disabled(!controller.isAuthorized || isWorking)
                    if isWorking { ProgressView().controlSize(.small) }
                }
                if !controller.networkAvailable {
                    Text(english ? "Waiting for an available network…" : "正在等待可用网络…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text(english ? "Reader proxy & Fake-IP compatibility" : "阅读器代理与 Fake-IP 兼容")
        } footer: {
            Text(english
                 ? "Reader only. Automatic mode follows the system DNS and gateway; no system or router settings are changed. Trusted-proxy credentials use this app's local encrypted store; authorization is not connectivity verification."
                 : "仅影响内嵌阅读器。自动模式跟随系统 DNS 与网关，不修改系统或软路由。受信任代理的凭据使用应用既有本机加密存储；授权不等于连接验证。")
        }
        .onAppear {
            host = controller.endpoint?.host ?? "192.168.0.14"
            port = controller.endpoint.map { String($0.port) } ?? "7890"
        }
        .task(id: controller.mode) {
            guard controller.mode == .strict else { return }
            if case .unknown = controller.fakeIPStatus {
                await controller.refreshFakeIPStatus()
            }
        }
        .onChange(of: controller.revision) { _, _ in
            acceptsRisk = false
            password = ""
            result = nil
        }
    }

    @ViewBuilder
    private var automaticNetworkStatus: some View {
        switch controller.fakeIPStatus {
        case .unknown:
            Label(english ? "Not checked yet; the reader checks when it opens an article." : "尚未检测；打开文章时会自动检测。",
                  systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(english ? "Checking this network…" : "正在检测当前网络…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .resolved(let detection):
            Label(detection.isFakeIPNetwork
                  ? (english ? "Router Fake-IP detected; the reader follows the system network." : "已识别旁路由 Fake-IP；阅读器自动跟随系统网络。")
                  : (english ? "No Fake-IP detected; the reader uses the normal public-IP check." : "未识别到 Fake-IP；阅读器使用常规公网 IP 校验。"),
                  systemImage: detection.isFakeIPNetwork ? "checkmark.shield" : "network")
                .font(.caption)
                .foregroundStyle(detection.isFakeIPNetwork ? Color.green : Color.secondary)
            if let router = detection.router {
                Text(verbatim: english ? "Gateway: \(router)" : "网关：\(router)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let probe = detection.probes.first {
                Text(verbatim: "\(probe.host) → \(probe.addresses.isEmpty ? "—" : probe.addresses.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Toggle(english ? "Strictly block Fake-IP (not recommended)" : "严格阻止 Fake-IP（不推荐）",
               isOn: Binding(get: { controller.blocksFakeIP }, set: { controller.blocksFakeIP = $0 }))
            .toggleStyle(.checkbox)
            .font(.caption)

        Text(english
             ? "Automatic mode accepts only the local 198.18.0.0/15 Fake-IP block, and only after a private gateway and at least two public canaries agree. Real private, loopback, link-local and CGNAT addresses remain blocked."
             : "自动模式只在私网网关 + 至少两个公网样例都返回 198.18.0.0/15 时放行 Fake-IP。真实私网、回环、链路本地和 CGNAT 地址仍然拦截。")
            .font(.caption).foregroundStyle(.secondary)

        HStack(spacing: 8) {
            Button(english ? "Detect again" : "重新检测") {
                Task { await controller.refreshFakeIPStatus() }
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .disabled(!controller.networkAvailable || isChecking)
            if isChecking { ProgressView().controlSize(.small) }
        }
        if !controller.networkAvailable {
            Text(english ? "Waiting for an available network…" : "正在等待可用网络…")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var isChecking: Bool {
        if case .checking = controller.fakeIPStatus { return true }
        return false
    }

    private func authorize() {
        guard acceptsRisk, let number = Int(port) else {
            result = ReaderProxyError.invalidEndpoint.message(language: settings.appLanguage)
            return
        }
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        isWorking = true
        result = nil
        Task { @MainActor in
            defer { isWorking = false; password = "" }
            do {
                let endpoint = try ReaderProxyEndpoint(host: address, port: number)
                try await controller.trust(endpoint: endpoint, username: user, password: secret)
            } catch {
                result = (error as? ReaderProxyError ?? .unavailable).message(language: settings.appLanguage)
            }
        }
    }

    private func probe() {
        isWorking = true
        result = nil
        let version = controller.revision
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await controller.probeConnection()
                guard version == controller.revision else { return }
                result = english ? "Proxy connectivity verified. No AI request was made; destination IP and exit region are not verified." : "代理连通性验证成功。未调用 AI；未验证最终目标 IP 或出口地区。"
            } catch {
                guard version == controller.revision else { return }
                result = (error as? ReaderProxyError ?? .unavailable).message(language: settings.appLanguage)
            }
        }
    }
}
