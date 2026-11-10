import SwiftUI

/// Compact thinking-level menu shared by the reader panels and the summary
/// surfaces. It is only rendered when the connection offers at least one
/// selectable level; unsupported connections show a note instead of a dead
/// picker.
struct AIThinkingPicker: View {
    let surface: AIThinkingSurface
    let language: AppLanguage
    let level: AIThinkingLevel
    let options: [AIThinkingLevel]
    var isEnabled: Bool = true
    var showsLabel: Bool = true
    let onChange: (AIThinkingLevel) -> Void

    private var selected: AIThinkingLevel {
        if options.contains(level) { return level }
        return options.first ?? .providerDefault
    }

    var body: some View {
        if options.isEmpty {
            EmptyView()
        } else {
            Menu {
                Picker(
                    surface.title(language),
                    selection: Binding(
                        get: { selected },
                        set: { onChange($0) }
                    )
                ) {
                    ForEach(options) { option in
                        Text(option.title(language)).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 10, weight: .medium))
                    if showsLabel {
                        Text(selected.title(language))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .disabled(!isEnabled)
            .help(surface.title(language) + " · " + selected.title(language))
            .accessibilityLabel(surface.title(language))
            .accessibilityValue(selected.title(language))
        }
    }
}
