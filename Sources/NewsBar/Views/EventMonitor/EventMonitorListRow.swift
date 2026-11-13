import SwiftUI

struct EventMonitorListRow: View {
    @Environment(AppSettings.self) private var settings

    let event: NewsEvent
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !event.eventDescription.isEmpty && event.eventDescription != event.title {
                        Text(event.eventDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .layoutPriority(1)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(L10n.string(
                        "event.publisherCount",
                        language: settings.appLanguage,
                        event.countablePublisherCount,
                        3
                    ))
                    .font(.headline.monospacedDigit())
                    .accessibilityLabel(L10n.string(
                        "event.publisherCount.accessibility",
                        language: settings.appLanguage,
                        event.countablePublisherCount,
                        3
                    ))

                    Text("event.publisherCount.caption".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { statusTags; budgetAndConflictTags }
                VStack(alignment: .leading, spacing: 5) { statusTags; budgetAndConflictTags }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.publicImportanceReason ?? "event.reason.unknown".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(event.lastEvidenceAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: settings.appTheme == .retroEditorial ? 2 : 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: settings.appTheme == .retroEditorial ? 2 : 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 1.2 : 0.7
                )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(
            "event.row.accessibility",
            language: settings.appLanguage,
            event.title,
            event.countablePublisherCount,
            3,
            L10n.string(lifecycleKey, language: settings.appLanguage)
        ))
        .accessibilityValue(isSelected ? "event.selection.selected".localized : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var statusTags: some View {
        EditorialTag(
            text: L10n.string(lifecycleKey, language: settings.appLanguage),
            fallbackTint: lifecycleTint,
            filled: event.lifecycle == .tracking
        )
        if event.wasNotified {
            EditorialTag(text: "event.status.notified".localized, fallbackTint: .purple)
        }
    }

    @ViewBuilder
    private var budgetAndConflictTags: some View {
        if event.trackingStatus == .budgetDeferred {
            EditorialTag(text: "event.status.budgetPaused".localized, fallbackTint: .orange)
        }
        if event.hasConflict {
            EditorialTag(text: "event.status.conflict".localized, fallbackTint: .red)
        }
    }

    private var lifecycleKey: String {
        switch event.lifecycle {
        case .queued: return "event.status.candidate"
        case .tracking: return "event.status.tracking"
        case .expired: return "event.status.expired"
        }
    }

    private var lifecycleTint: Color {
        switch event.lifecycle {
        case .queued: return Color.gray
        case .tracking: return Color.green
        case .expired: return Color.gray.opacity(0.65)
        }
    }
}
