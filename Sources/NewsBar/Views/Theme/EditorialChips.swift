import SwiftUI

/// A row of chips where exactly one is chosen.
///
/// The native segmented control is not usable everywhere in this app: placed
/// straight on the editorial paper surface (rather than inside a Form row) it
/// draws as glass and its unselected labels disappear. These chips use the
/// app's own button style, so the selection stays readable in both themes and
/// does not change with the system appearance.
struct EditorialChips<Value: Hashable>: View {
    let values: [Value]
    let title: (Value) -> String
    /// Spoken name for the group, e.g. "Plan".
    let groupLabel: String
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 5) {
            ForEach(values, id: \.self) { value in
                let isOn = value == selection
                Button {
                    selection = value
                } label: {
                    Text(title(value))
                }
                .buttonStyle(EditorialActionButtonStyle(tone: isOn ? .selected : .secondary, compact: true))
                .controlSize(.small)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groupLabel)
    }
}
