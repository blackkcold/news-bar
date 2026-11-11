import SwiftUI

/// Settings → 通用 → 更新。
///
/// Sparkle owns scheduling, downloading and installation. These controls only
/// mirror its documented settings API, so the app never grows a second update
/// state machine that can disagree with the one doing the work.
struct UpdateSettingsSection: View {
    @ObservedObject var updater: SparkleUpdater
    @Environment(AppSettings.self) private var settings

    private var accent: Color {
        settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : .accentColor
    }

    var body: some View {
        Section {
            Toggle("general.update.autoCheck".localized, isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }
            ))

            Toggle("general.update.autoDownload".localized, isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.setAutomaticallyDownloadsUpdates($0) }
            ))
            .disabled(!updater.automaticallyChecksForUpdates)

            HStack(spacing: 10) {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("general.update.check".localized, systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
                .disabled(!updater.canCheckForUpdates)

                Spacer(minLength: 8)

                Text(L10n.string("general.update.current", updater.currentVersion))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let status = statusLine {
                Label {
                    Text(status.text)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: status.symbol)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status.tint)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("settings.update".localized)
        } footer: {
            Text("general.update.footer".localized)
        }
    }

    private var statusLine: (text: String, symbol: String, tint: Color)? {
        switch updater.state {
        case .idle:
            return nil
        case .checking:
            return (L10n.string("update.checking"), "arrow.triangle.2.circlepath", .secondary)
        case .upToDate(let version):
            return (L10n.string("update.upToDate", version), "checkmark.circle.fill", .green)
        case .available(let version):
            return (L10n.string("general.update.available", version), "arrow.down.circle.fill", accent)
        case .ready:
            return (L10n.string("update.readyShort"), "checkmark.circle.fill", accent)
        case .failed(let message):
            return (message, "exclamationmark.triangle.fill", .orange)
        }
    }
}
