import SwiftUI

/// A draft editor for event-interest rules.
///
/// It is a sheet rather than a pane section: the editor is nine blocks long and
/// its Save contract (draft first, persist on Save) differs from every other
/// setting, which applies immediately.
struct EventInterestRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "target")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        settings.appTheme == .retroEditorial
                            ? RetroEditorialTokens.brick
                            : Color.accentColor
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("event.interest.title".localized)
                        .font(.system(size: 14, weight: .semibold))
                    Text("event.interest.sheet.subtitle".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("settings.close".localized)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Form {
                EventMonitorInterestSettingsForm(showsCancel: true, onCancel: { dismiss() })
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 660, minHeight: 640)
        .appThemeSurface()
    }
}
