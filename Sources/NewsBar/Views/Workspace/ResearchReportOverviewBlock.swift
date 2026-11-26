import SwiftUI

/// Background context, moved out of the conclusion and into the detail area.
///
/// The popup shows it as plain copy rather than a second `DisclosureGroup`:
/// with the fold strip present, the first screen already has exactly one
/// disclosure control, and two of them in the same column compete for the same
/// action. The workbench keeps its inline disclosure, so this block only ever
/// appears when a presentation opts out of that.
struct ResearchReportOverviewBlock: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.researchReportPresentation) private var presentation

    let text: String

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("research.report.overview".localized)
                .font(.system(size: 11, weight: .semibold, design: isRetro ? .serif : .default))
                .foregroundStyle(.secondary)
            Text(text)
                .font(presentation.bodyFont(12, isRetro: isRetro))
                .lineSpacing(2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
