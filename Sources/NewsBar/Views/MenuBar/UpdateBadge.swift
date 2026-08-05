import SwiftUI

struct UpdateBadge: View {
    @ObservedObject var checker: UpdateChecker
    @Environment(AppSettings.self) private var settings

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        HStack(spacing: 4) {
            switch checker.state {
            case .idle:
                actionButton(label: isRetro ? "update.update".localized : (settings.updateDevMode ? "update.checkDev".localized : "update.check".localized), icon: "arrow.down.circle") {
                    manualCheck()
                }

            case .checking:
                checkingLabel

            case .upToDate(let version):
                statusLabel(icon: "checkmark.circle.fill", text: L10n.string("update.upToDate", version), color: .green)

            case .updateAvailable:
                actionButton(label: "update.update".localized, icon: "arrow.down.circle.fill") {
                    checker.downloadUpdate()
                }
                dismissButton

            case .downloading(let progress):
                downloadingButton(progress: progress)

            case .downloadComplete:
                actionButton(label: "update.openInstaller".localized, icon: "checkmark.circle.fill") {
                    checker.openDownloadedDMG()
                }

            case .error(let message):
                Button {
                    manualCheck()
                } label: {
                    errorLabel(message: message)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("update.failedRetry".localized)
                .accessibilityValue(message)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: checker.state)
    }

    // MARK: - Subviews

    private func actionButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
        }
        .buttonStyle(EditorialActionButtonStyle(tone: .secondary, compact: true))
        .accessibilityLabel(label)
    }

    private var checkingLabel: some View {
        Group {
            if isRetro {
                EditorialTag(text: "update.checking".localized, fallbackTint: .secondary)
            } else {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 10, height: 10)
                    Text("update.checking".localized)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5))
                .clipShape(Capsule())
            }
        }
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
                }
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(color.opacity(0.1))
                .clipShape(Capsule())
            }
        }
    }

    private var dismissButton: some View {
        Button {
            checker.dismissUpdate()
        } label: {
            Text("update.later".localized)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
        }
        .buttonStyle(EditorialActionButtonStyle(compact: true))
    }

    private func downloadingButton(progress: Double) -> some View {
        Group {
            if isRetro {
                EditorialTag(
                    text: L10n.string("update.downloadingPercent", Int((progress * 100).rounded())),
                    fallbackTint: RetroEditorialTokens.brick
                )
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 9, weight: .medium))
                    Text("update.downloading".localized)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.blue.opacity(0.1)
                            Color.blue.opacity(0.3)
                                .frame(width: max(0, geo.size.width * CGFloat(progress)))
                                .animation(.linear(duration: 0.3), value: progress)
                        }
                    }
                )
                .clipShape(Capsule())
            }
        }
    }

    private func errorLabel(message: String) -> some View {
        Group {
            if isRetro {
                EditorialTag(text: "update.failed".localized, fallbackTint: .orange)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .medium))
                    Text(message)
                        .font(.system(size: 9))
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.1))
                .clipShape(Capsule())
            }
        }
    }

    private func manualCheck() {
        Task {
            await checker.manualCheck()
        }
    }
}
