import SwiftUI

struct ResearchProgressView: View {
    @Environment(AppSettings.self) private var settings
    let run: ResearchRun
    let onCancel: () -> Void

    private let phases: [(phase: ResearchRun.Phase, key: String, symbol: String)] = [
        (.planning, "research.phase.planning", "sparkles"),
        (.searching, "research.phase.searching", "magnifyingglass"),
        (.reading, "research.phase.reading", "doc.text"),
        (.extracting, "research.phase.extracting", "list.bullet.rectangle"),
        (.synthesizing, "research.phase.synthesizing", "square.stack.3d.up"),
        (.validating, "research.phase.validating", "checkmark.shield"),
    ]

    private var currentIndex: Int {
        if run.phase == .done { return phases.count }
        return phases.firstIndex { $0.phase == run.phase } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("research.progress.title".localized)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("research.action.cancel".localized, action: onCancel)
                    .buttonStyle(EditorialActionButtonStyle(tone: .destructive, compact: true))
            }

            ProgressView(
                value: Double(min(currentIndex + 1, phases.count)),
                total: Double(phases.count)
            )
            .tint(.accentColor)

            HStack(spacing: 0) {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                    VStack(spacing: 4) {
                        Image(systemName: index < currentIndex ? "checkmark.circle.fill" : phase.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(
                                index < currentIndex
                                    ? Color.green
                                    : (index == currentIndex ? Color.accentColor : Color.secondary)
                            )
                        Text(L10n.string(phase.key, language: settings.appLanguage))
                            .font(.system(size: 8))
                            .foregroundStyle(index <= currentIndex ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Text(
                L10n.string(
                    "research.progress.counts",
                    language: settings.appLanguage,
                    run.queriesCompleted,
                    run.pagesRead,
                    run.aiCalls
                )
            )
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .newsCardSurface(cornerRadius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("research.progress.title".localized)
    }
}
