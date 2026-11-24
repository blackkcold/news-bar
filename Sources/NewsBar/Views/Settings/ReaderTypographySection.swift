import SwiftUI

/// Reader appearance defaults.
///
/// The Aa menu inside the reader writes the same `readerMode*` properties, so
/// there is exactly one persisted preference. This page is the discoverable
/// home; the in-reader control is the quick adjustment.
struct ReaderTypographySection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            Picker("settings.reader.fontSize".localized, selection: Binding(
                get: { settings.readerModeFontScale },
                set: { settings.readerModeFontScale = $0 }
            )) {
                Text("settings.reader.fontSize.small".localized).tag(0.9)
                Text("settings.reader.fontSize.standard".localized).tag(1.0)
                Text("settings.reader.fontSize.large".localized).tag(1.15)
                Text("settings.reader.fontSize.xlarge".localized).tag(1.35)
            }
            .pickerStyle(.segmented)

            Picker("settings.reader.lineSpacing".localized, selection: Binding(
                get: { settings.readerModeLineSpacing },
                set: { settings.readerModeLineSpacing = $0 }
            )) {
                Text("settings.reader.lineSpacing.tight".localized).tag(1.35)
                Text("settings.reader.lineSpacing.normal".localized).tag(1.55)
                Text("settings.reader.lineSpacing.loose".localized).tag(1.75)
            }
            .pickerStyle(.menu)

            HStack(spacing: 10) {
                Text("settings.reader.width".localized)
                Slider(value: Binding(
                    get: { settings.readerModeWidth },
                    set: { settings.readerModeWidth = min(760, max(620, $0)) }
                ), in: 620...760, step: 10)
                Text(verbatim: "\(Int(settings.readerModeWidth)) pt")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Picker("settings.reader.pageTheme".localized, selection: Binding(
                get: { settings.readerModeTheme },
                set: { settings.readerModeTheme = $0 }
            )) {
                Text("settings.reader.pageTheme.auto".localized).tag("auto")
                Text("settings.reader.pageTheme.paper".localized).tag("paper")
                Text("settings.reader.pageTheme.dark".localized).tag("dark")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("settings.reader.appearance.title".localized)
        } footer: {
            Text("settings.reader.appearance.footer".localized)
        }

        Section {
            Picker("reader.zoom.menu".localized, selection: Binding(
                get: { ReaderZoomMode(rawValue: settings.readerPageZoomMode) ?? .fit },
                set: { settings.readerPageZoomMode = $0.rawValue }
            )) {
                Text("reader.zoom.fit".localized).tag(ReaderZoomMode.fit)
                Text("reader.zoom.actual".localized).tag(ReaderZoomMode.actual)
                Text("reader.zoom.large".localized).tag(ReaderZoomMode.large)
            }
            .pickerStyle(.menu)
        } header: {
            Text("settings.reader.pages".localized)
        } footer: {
            Text("settings.reader.pages.footer".localized)
        }
    }
}
