import SwiftUI

/// Compact article tab strip above the dashboard. The browse pane is the first
/// fixed tab; article tabs are ordered by when they were opened.
struct WorkspaceTabStrip: View {
    let tabs: [WorkspaceTab]
    let activeID: UUID?
    let onSelectBrowse: () -> Void
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var english: Bool { settings.appLanguage == .en }

    var body: some View {
        HStack(spacing: 8) {
            browseTab
            Divider().frame(height: 15)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        articleTab(tab)
                    }
                }
                .padding(.vertical, 5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var browseTab: some View {
        Button(action: onSelectBrowse) {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10, weight: .semibold))
                Text(english ? "Browse" : "浏览")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(
                activeID == nil ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(english ? "Browse" : "浏览")
        .help(english ? "Back to the list" : "返回列表")
    }

    private func articleTab(_ tab: WorkspaceTab) -> some View {
        let active = activeID == tab.id
        return HStack(spacing: 2) {
            Button {
                onSelect(tab.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(active ? Color.accentColor : .secondary)
                    Text(tab.request.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 190, alignment: .leading)
                }
                .padding(.leading, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.request.title)
            .accessibilityLabel(tab.request.title)

            Button {
                onClose(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(active ? 1 : 0.6)
            .accessibilityLabel(english ? "Close tab" : "关闭标签")
            .help(english ? "Close tab" : "关闭标签")
        }
        .padding(.trailing, 3)
        .background(
            active ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(alignment: .bottom) {
            if active {
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(height: 1.5)
                    .padding(.horizontal, 7)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
    }
}
