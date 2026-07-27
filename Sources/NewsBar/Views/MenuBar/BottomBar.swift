import SwiftUI

struct BottomBar: View {
    let isRefreshing: Bool
    var batchProgress: (completed: Int, total: Int) = (0, 0)
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onOpenDashboard: () -> Void

    var body: some View {
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
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
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
        .accessibilityLabel("刷新")
        .disabled(isRefreshing)
    }

    private var refreshLabel: String {
        if isRefreshing { return "刷新中..." }
        return "刷新"
    }

    private var dashboardButton: some View {
        Button(action: onOpenDashboard) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开Dashboard")
        .help("打开 Dashboard")
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开设置")
        .help("打开设置")
    }
}
