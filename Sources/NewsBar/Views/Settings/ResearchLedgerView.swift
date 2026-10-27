import SwiftUI

/// Compact three-column view of today's shared research ledger. The stacked bar
/// shows consumption against the daily AI cap; the legend breaks it down by
/// origin (burst / keyword / manual).
struct ResearchLedgerView: View {
    @Environment(AppSettings.self) private var settings
    private let ledger: ResearchLedger

    @State private var snapshot = LedgerSnapshot.empty
    @State private var showsResetConfirmation = false

    init(ledger: ResearchLedger = .shared) {
        self.ledger = ledger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if snapshot.isCorrupt {
                corruptState
            } else {
                usageState
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
                ledger.resetToday()
                refresh()
            }
            Button("research.data.cancel".localized, role: .cancel) {}
        } message: {
            Text("research.ledger.reset.message".localized)
        }
    }

    private var usageState: some View {
        VStack(alignment: .leading, spacing: 7) {
            row(
                title: "research.ledger.ai".localized,
                value: "\(snapshot.totalAI) / \(settings.researchDailyAICap)"
            )

            usageBar

            HStack(spacing: 10) {
                legendItem("research.origin.burst".localized, count: snapshot.ai.burst, color: .orange)
                legendItem("research.origin.keyword".localized, count: snapshot.ai.keyword, color: .blue)
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

    private var corruptState: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("research.error.ledger".localized)
                    .font(.system(size: 11, weight: .medium))
                Text("research.ledger.corruptHint".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("research.ledger.reset".localized) {
                showsResetConfirmation = true
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .controlSize(.small)
        }
    }

    private var usageBar: some View {
        GeometryReader { proxy in
            let cap = max(settings.researchDailyAICap, 1)
            let width = proxy.size.width
            let usedFraction = min(1, Double(snapshot.totalAI) / Double(cap))
            let usedWidth = width * usedFraction
            let total = max(snapshot.totalAI, 1)

            HStack(spacing: 0) {
                if snapshot.totalAI > 0 {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: usedWidth * Double(snapshot.ai.burst) / Double(total))
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: usedWidth * Double(snapshot.ai.keyword) / Double(total))
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: usedWidth * Double(snapshot.ai.manual) / Double(total))
                }
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: max(0, width - usedWidth))
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.string(
                "research.ledger.barA11y",
                language: settings.appLanguage,
                snapshot.totalAI,
                settings.researchDailyAICap
            )
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
    }
}
