import SwiftUI

/// 提醒 → 爆款与研究. Automatic detection is separate from burst push: turning
/// push off must not silently stop the research archive, and vice versa.
struct ResearchAutomationSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            Toggle("research.auto.enable".localized, isOn: Binding(
                get: { settings.researchAutoEnabled },
                set: { settings.researchAutoEnabled = $0 }
            ))

            Picker("research.auto.detectionLimit".localized, selection: Binding(
                get: { settings.researchDetectionLimit },
                set: { settings.researchDetectionLimit = $0 }
            )) {
                ForEach(Array(AppSettings.validResearchDetectionLimits).sorted(), id: \.self) { value in
                    Text(L10n.string("research.auto.perRound", language: settings.appLanguage, value))
                        .tag(value)
                }
            }
            .disabled(!settings.researchAutoEnabled)

            Toggle("research.auto.popoverChip".localized, isOn: Binding(
                get: { settings.researchShowPopoverChip },
                set: { settings.researchShowPopoverChip = $0 }
            ))

            Toggle("research.markReadOnOpen".localized, isOn: Binding(
                get: { settings.researchMarkReadOnOpen },
                set: { settings.researchMarkReadOnOpen = $0 }
            ))

            Toggle("research.auto.personalization".localized, isOn: Binding(
                get: { settings.researchUsePersonalization },
                set: { settings.researchUsePersonalization = $0 }
            ))
            if settings.researchUsePersonalization, !InterestController.shared.state.learningEnabled {
                Text("research.auto.personalization.off".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("research.auto.notificationSummary".localized, isOn: Binding(
                get: { settings.researchNotificationShowsSummary },
                set: { settings.researchNotificationShowsSummary = $0 }
            ))
        } header: {
            Text("research.auto.title".localized)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("research.auto.footer".localized)
                if let last = settings.researchLastAutomaticDecision {
                    Text(L10n.string("research.auto.lastCheck", language: settings.appLanguage, last))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
