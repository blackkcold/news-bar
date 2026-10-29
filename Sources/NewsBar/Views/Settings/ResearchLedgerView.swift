import SwiftUI

/// Compact three-column view of today's shared research ledger. The stacked bar
/// shows consumption against the daily AI cap; the legend breaks it down by
/// origin (burst / keyword / manual). When the file cannot be read the view
/// says so explicitly instead of painting a fake zero.
struct ResearchLedgerView: View {
    @Environment(AppSettings.self) private var settings
    private let ledger: ResearchLedger

    @State private var snapshot = LedgerSnapshot.empty
    @State private var quota = AIQuotaStore.shared.snapshot()
    @State private var showsResetConfirmation = false
    @State private var resetMessage: String?
    @State private var resetMessageIsError = false

    init(ledger: ResearchLedger = .shared) {
        self.ledger = ledger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch snapshot.availability {
            case .loading:
                loadingState
            case .available:
                usageState
            case .corrupt:
                unavailableState(
                    titleKey: "research.error.ledger",
                    hintKey: "research.ledger.corruptHint",
                    allowsReset: true
                )
            case .ioUnavailable:
                unavailableState(
                    titleKey: "research.ledger.unavailable",
                    hintKey: "research.ledger.unavailableHint",
                    allowsReset: false
                )
            case .unsupportedVersion:
                unavailableState(
                    titleKey: "research.ledger.unsupported",
                    hintKey: "research.ledger.unsupportedHint",
                    allowsReset: false
                )
            }
            if let resetMessage {
                Text(resetMessage)
                    .font(.caption2)
                    .foregroundStyle(resetMessageIsError ? .red : .secondary)
            }
        }
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .researchRecordsChanged)) { _ in
            refresh()
        }
        .confirmationDialog(
            "research.ledger.reset.title".localized,
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("research.ledger.reset".localized, role: .destructive) {
                let ledgerOK = ledger.resetToday()
                let quotaOK = AIQuotaStore.shared.resetToday()
                let succeeded = ledgerOK && quotaOK
                settings.refreshAIUsageMirror()
                resetMessage = succeeded
                    ? "research.ledger.reset.done".localized
                    : "research.ledger.reset.failed".localized
                resetMessageIsError = !succeeded
                refresh()
            }
            Button("research.data.cancel".localized, role: .cancel) {}
        } message: {
            Text("research.ledger.reset.message".localized)
        }
    }

    private var loadingState: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("research.ledger.loading".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var usageState: some View {
        VStack(alignment: .leading, spacing: 7) {
            row(
                title: "research.ledger.ai".localized,
                value: quotaValueText
            )

            if settings.effectiveAILimitMode == .cost || settings.aiCountLimit != nil {
                usageBar
            } else {
                Text("research.ledger.aiUnlimitedHint".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                legendItem("research.origin.burst".localized, count: snapshot.ai.burst, color: .orange)
                legendItem("research.origin.keyword".localized, count: snapshot.ai.keyword, color: .blue)
                legendItem("research.origin.interest".localized, count: snapshot.ai.interest, color: .purple)
                legendItem("research.origin.manual".localized, count: snapshot.ai.manual, color: .green)
                Spacer(minLength: 0)
            }

            Divider()

            row(
                title: "research.ledger.tasks".localized,
                value: "\(snapshot.totalTasks) / \(settings.researchDailyTaskCap)"
            )
            row(
                title: "research.ledger.search".localized,
                value: L10n.string(
                    "research.ledger.searchValue",
                    language: settings.appLanguage,
                    snapshot.totalSearch
                )
            )
        }
    }

    private func unavailableState(
        titleKey: String,
        hintKey: String,
        allowsReset: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(titleKey.localized)
                    .font(.system(size: 11, weight: .medium))
                Text(hintKey.localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("research.ledger.usageUnknown".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("research.ledger.usageUnknown".localized)
            }
            Spacer(minLength: 0)
            if allowsReset {
                Button("research.ledger.reset".localized) {
                    showsResetConfirmation = true
                }
                .buttonStyle(EditorialActionButtonStyle(compact: true))
                .controlSize(.small)
                .disabled(ResearchActivity.isActive)
                .help(
                    ResearchActivity.isActive
                        ? "research.ledger.reset.blocked".localized
                        : ""
                )
            }
        }
    }

    private var quotaValueText: String {
        if settings.effectiveAILimitMode == .cost {
            return "\(AICostFormat.yuan(quota.costMicros)) / \(AICostFormat.yuan(settings.aiCostCapMicros))"
        }
        if let cap = settings.aiCountLimit {
            return "\(quota.count) / \(cap)"
        }
        return L10n.string(
            "research.ledger.aiValueUnlimited",
            language: settings.appLanguage,
            quota.count
        )
    }

    private var usageBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usedWidth = width * usageFraction

            HStack(spacing: 0) {
                Rectangle()
                    .fill(usageAtLimit ? Color.red : Color.blue)
                    .frame(width: usedWidth)
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: max(0, width - usedWidth))
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityUsageLabel)
    }

    private var usageFraction: Double {
        if settings.effectiveAILimitMode == .cost {
            guard settings.aiCostCapMicros > 0 else { return 0 }
            return min(1, Double(quota.costMicros) / Double(settings.aiCostCapMicros))
        }
        let cap = max(settings.aiCountLimit ?? 0, 1)
        return min(1, Double(quota.count) / Double(cap))
    }

    private var usageAtLimit: Bool {
        if settings.effectiveAILimitMode == .cost {
            return settings.aiCostCapMicros > 0 && quota.costMicros >= settings.aiCostCapMicros
        }
        guard let cap = settings.aiCountLimit, cap > 0 else { return false }
        return quota.count >= cap
    }

    private var accessibilityUsageLabel: String {
        if settings.effectiveAILimitMode == .cost {
            return L10n.string(
                "research.ledger.costA11y",
                language: settings.appLanguage,
                AICostFormat.yuan(quota.costMicros),
                AICostFormat.yuan(settings.aiCostCapMicros)
            )
        }
        return L10n.string(
            "research.ledger.barA11y",
            language: settings.appLanguage,
            quota.count,
            settings.aiCountLimit ?? 0
        )
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private func legendItem(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(title) \(count)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        snapshot = ledger.snapshot()
        quota = AIQuotaStore.shared.snapshot()
    }
}
