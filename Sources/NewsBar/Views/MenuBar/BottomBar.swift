import SwiftUI

struct BottomBar: View {
    @Environment(AppSettings.self) private var settings

    let isRefreshing: Bool
    var batchProgress: BatchProgress = .zero
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onOpenDashboard: () -> Void

    var body: some View {
        Group {
            if settings.appTheme == .retroEditorial {
                retroBottomBar
            } else {
                modernBottomBar
            }
        }
    }

    private var modernBottomBar: some View {
        HStack(spacing: 0) {
            refreshButton

            if isRefreshing && batchProgress.total > 0 {
                Text("\(batchProgress.completed)/\(batchProgress.total)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }

            Spacer()

            dashboardButton

            settingsButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .editorialMasthead()
    }

    private var retroBottomBar: some View {
        HStack(spacing: 8) {
            Button(action: onRefresh) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                        value: isRefreshing
                    )
                    Text(refreshLabel)
                }
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .primary, compact: true))
            .disabled(isRefreshing)

            if isRefreshing && batchProgress.total > 0 {
                EditorialTag(
                    text: "\(batchProgress.completed)/\(batchProgress.total)",
                    fallbackTint: .secondary
                )
            }

            Spacer(minLength: 4)

            Button(action: onOpenDashboard) {
                Label("bottom.overview".localized, systemImage: "rectangle.split.2x1")
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .accessibilityLabel("bottom.openDashboard".localized)

            Button(action: onOpenSettings) {
                Label("settings.badge".localized, systemImage: "gearshape")
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .accessibilityLabel("bottom.openSettings".localized)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .background(RetroEditorialTokens.raisedPaper)
        .overlay(alignment: .top) {
            VStack(spacing: 2) {
                Rectangle().fill(RetroEditorialTokens.brick).frame(height: 3)
                Rectangle().fill(RetroEditorialTokens.ink).frame(height: 1)
            }
        }
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .medium))
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                        value: isRefreshing
                    )
                Text(refreshLabel)
                    .font(.system(size: 9.5))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("bottom.refresh".localized)
        .disabled(isRefreshing)
    }

    private var refreshLabel: String {
        if isRefreshing { return "bottom.refreshing".localized }
        return "bottom.refresh".localized
    }

    private var dashboardButton: some View {
        Button(action: onOpenDashboard) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("bottom.openDashboard".localized)
        .help("bottom.openDashboard".localized)
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("bottom.openSettings".localized)
        .help("bottom.openSettings".localized)
    }
}
