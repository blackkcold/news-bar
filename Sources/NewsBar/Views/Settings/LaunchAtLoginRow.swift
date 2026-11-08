import ServiceManagement
import SwiftUI

/// One shared control for the existing general toggle and the monitor page.
/// `launchAtLogin` is a single preference; the actual `SMAppService` status is
/// the source of truth for whether it is currently active.
struct LaunchAtLoginRow: View {
    @Environment(AppSettings.self) private var settings
    @State private var status: SMAppService.Status = .notRegistered
    @State private var errorMessage: String?

    var titleKey: String = "general.launchAtLogin"
    var hintKey: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(
                L10n.string(titleKey, language: settings.appLanguage),
                isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            settings.launchAtLogin = LaunchAtLogin.isEnabled
                            status = LaunchAtLogin.status
                        } catch {
                            settings.launchAtLogin = LaunchAtLogin.isEnabled
                            status = LaunchAtLogin.status
                            NSLog("[LaunchAtLogin] %@", error.localizedDescription)
                            errorMessage = L10n.string(
                                "weibo.advanced.loginItemFailed",
                                language: settings.appLanguage
                            )
                        }
                    }
                )
            )

            if settings.launchAtLogin && !LaunchAtLogin.isEnabled && status != .requiresApproval {
                Text(L10n.string("weibo.advanced.loginItemInactive", language: settings.appLanguage))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            if status == .requiresApproval {
                HStack(spacing: 8) {
                    Text(L10n.string("weibo.advanced.loginItemApproval", language: settings.appLanguage))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Button(L10n.string("weibo.advanced.openLoginItems", language: settings.appLanguage)) {
                        LaunchAtLogin.openSystemSettings()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }

            if let hintKey {
                Text(L10n.string(hintKey, language: settings.appLanguage))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { status = LaunchAtLogin.status }
        .alert(
            L10n.string("settings.launchAtLogin.error", language: settings.appLanguage),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
            Button(L10n.string("weibo.advanced.openLoginItems", language: settings.appLanguage)) {
                LaunchAtLogin.openSystemSettings()
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
