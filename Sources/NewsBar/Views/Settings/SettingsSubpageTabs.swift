import SwiftUI

/// A second-level page switcher for settings groups that outgrew one screen.
///
/// Deliberately not `EditorialChips`: those use the same button treatment as
/// actions, so "switch page" and "do something" look identical. This is a tab
/// bar — the selected tab carries an underline and primary text, the rest stay
/// secondary, and the row keeps a fixed height so the first section starts at
/// the same y in every pane.
struct SettingsSubpageTabs<Value: Hashable>: View {
    @Environment(AppSettings.self) private var settings

    let values: [Value]
    let title: (Value) -> String
    /// Spoken name for the group, e.g. "Reading pages".
    let groupLabel: String
    @Binding var selection: Value

    private var tint: Color {
        settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : .accentColor
    }

    var body: some View {
        HStack(spacing: 20) {
            ForEach(Array(values.enumerated()), id: \.element) { index, value in
                tab(value, index: index)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: SettingsSubpageBar.height, alignment: .bottom)
        .background(alignment: .bottom) {
            SettingsSubpageBar.rule
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groupLabel)
    }

    private func tab(_ value: Value, index: Int) -> some View {
        let isOn = value == selection
        return Button {
            guard selection != value else { return }
            selection = value
        } label: {
            VStack(spacing: 7) {
                Text(title(value))
                    .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? tint : Color.secondary)
                    .lineLimit(1)
                Rectangle()
                    .fill(isOn ? tint : Color.clear)
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(
            KeyEquivalent(Character(String(index + 1))),
            modifiers: .command
        )
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Reserves the tab bar's height for panes that have only one level, so the
/// first section does not jump when the user switches between panes.
struct SettingsSubpageBarPlaceholder: View {
    var body: some View {
        Color.clear
            .frame(height: SettingsSubpageBar.height)
            .background(alignment: .bottom) {
                SettingsSubpageBar.rule
            }
            .accessibilityHidden(true)
    }
}

enum SettingsSubpageBar {
    /// The tab row and its placeholder share this height. Keep it in one place:
    /// a mismatch shows up as the first section shifting between panes.
    static let height: CGFloat = 36

    static var rule: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.45))
            .frame(height: 1)
    }
}
