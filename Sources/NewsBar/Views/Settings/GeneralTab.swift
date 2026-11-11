import SwiftUI
import AppKit

/// 通用页签：语言、启动、主题与外观。兴趣画像归「隐私与数据」，阅读器代理归「高级」。
struct GeneralTab: View {
    @Environment(AppSettings.self) private var settings
    /// Injected by `SettingsWindow`; tests and previews leave it nil.
    var updater: SparkleUpdater? = nil
    /// Sparkle's window and AppKit's dialogs resolve their language once per
    /// process, so a switch reaches them on the next launch. The footer says
    /// so only after the person changes the picker — no permanent noise.
    @State private var pendingLanguageRestart = false

    var body: some View {
        Form {
            Section {
                Picker("settings.language".localized, selection: Binding(
                    get: { settings.appLanguage },
                    set: { language in
                        settings.appLanguage = language
                        pendingLanguageRestart = ProcessLanguage.resolvedLanguage() != language
                    }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }

                Toggle("settings.rssTranslation".localized, isOn: Binding(
                    get: { settings.rssTitleTranslationEnabled },
                    set: { settings.rssTitleTranslationEnabled = $0 }
                ))
                .disabled(settings.appLanguage == .zh)
            } header: {
                Text("settings.language".localized)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.appLanguage == .zh
                         ? "settings.language.footer".localized
                         : "settings.rssTranslation.footer".localized)
                    if pendingLanguageRestart {
                        Text("settings.language.restartHint".localized)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LaunchAtLoginRow()
            } header: {
                Text("general.launch".localized)
            }

            if let updater {
                UpdateSettingsSection(updater: updater)
            }

            Section {
                Toggle("general.retroTheme".localized, isOn: Binding(
                    get: { settings.appTheme == .retroEditorial },
                    set: { settings.appTheme = $0 ? .retroEditorial : .modern }
                ))

                HStack(spacing: 8) {
                    themeSwatch(RetroEditorialTokens.paper, label: "general.theme.paper".localized)
                    themeSwatch(RetroEditorialTokens.brick, label: "general.theme.brick".localized)
                    themeSwatch(RetroEditorialTokens.ink, label: "general.theme.ink".localized)
                    Spacer()
                    Text(settings.appTheme.displayName)
                        .font(.system(size: 11, weight: .bold, design: .serif))
                        .foregroundStyle(settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : .secondary)
                }

                Picker("general.appearance".localized, selection: Binding(
                    get: { settings.colorScheme },
                    set: { settings.colorScheme = $0 }
                )) {
                    Text("general.appearance.system".localized).tag("system")
                    Text("general.appearance.light".localized).tag("light")
                    Text("general.appearance.dark".localized).tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(settings.appTheme == .retroEditorial)
            } header: {
                Text("general.theme".localized)
            } footer: {
                Text(settings.appTheme == .retroEditorial
                     ? "general.theme.footer.retro".localized
                     : "general.theme.footer.modern".localized)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Opening this pane is an explicit signal that update controls should
        // work now, even if the launch-delayed scheduler has not started yet.
        .onAppear { updater?.start() }
    }

    private func themeSwatch(_ color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 18, height: 14)
                .overlay(Rectangle().stroke(RetroEditorialTokens.ink, lineWidth: 1))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("general.themeSwatchAccessibility", label))
    }
}
