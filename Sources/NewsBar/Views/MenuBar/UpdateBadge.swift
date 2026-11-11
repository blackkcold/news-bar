import SwiftUI

/// The popover's only update affordance.
///
/// Sparkle performs its checks in the background, so an always-visible
/// "check for updates" label was pure noise in a 48pt header. The badge now
/// appears only when it has something to say: an update is available, one is
/// ready to install on quit, a check is running, or the last check failed.
/// The full control surface lives in Settings → 通用 → 更新.
struct UpdateBadge: View {
    @ObservedObject var updater: SparkleUpdater
    @Environment(AppSettings.self) private var settings

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        Group {
            switch updater.state {
            case .idle:
                EmptyView()

            case .checking:
                checkingLabel

            case .upToDate(let version):
                statusLabel(
                    icon: "checkmark.circle.fill",
                    text: L10n.string("update.upToDate", version),
                    color: .green
                )

            case .available(let version):
                updateButton(
                    text: L10n.string("update.availableShort", version),
                    icon: "arrow.down.circle.fill"
                )

            case .ready:
                updateButton(
                    text: L10n.string("update.readyShort"),
                    icon: "checkmark.circle.fill"
                )

            case .failed:
                retryButton
            }
        }
        .animation(.easeInOut(duration: 0.18), value: updater.state)
    }

    // MARK: - Subviews

    private func updateButton(text: String, icon: String) -> some View {
        Button {
            updater.checkForUpdates()
        } label: {
            if isRetro {
                EditorialTag(text: text, fallbackTint: RetroEditorialTokens.brick)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                    Text(text)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint(L10n.string("update.badge.hint"))
    }

    private var checkingLabel: some View {
        Group {
            if isRetro {
                EditorialTag(text: L10n.string("update.checking"), fallbackTint: .secondary)
            } else {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.55)
                        .frame(width: 10, height: 10)
                    Text(L10n.string("update.checking"))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5))
                .clipShape(Capsule())
            }
        }
        .accessibilityLabel(L10n.string("update.checking"))
    }

    private func statusLabel(icon: String, text: String, color: Color) -> some View {
        Group {
            if isRetro {
                EditorialTag(text: text, fallbackTint: color)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .medium))
                    Text(text)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(color.opacity(0.1))
                .clipShape(Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var retryButton: some View {
        Button {
            updater.checkForUpdates()
        } label: {
            Group {
                if isRetro {
                    EditorialTag(text: L10n.string("update.failed"), fallbackTint: .orange)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .medium))
                        Text(L10n.string("update.failed"))
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.1))
                    .clipShape(Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(failureMessage)
        .accessibilityLabel(L10n.string("update.failedRetry"))
        .accessibilityValue(failureMessage)
    }

    private var failureMessage: String {
        if case .failed(let message) = updater.state, !message.isEmpty {
            return message
        }
        return L10n.string("update.failedRetry")
    }
}
