import SwiftUI

/// Verification section of a research report: strength first, verdict second,
/// then claims (each traceable to evidence chips), conflicts, gaps, and the
/// method used for this run.
struct VerificationPanel: View {
    @Environment(AppSettings.self) private var settings
    let verification: VerificationReport
    let method: ResearchMethod?
    let evidence: [EvidenceItem]
    let recordID: String

    private var accent: Color {
        settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            strengthRow
            Text(
                L10n.string(
                    "research.independentSources",
                    language: settings.appLanguage,
                    verification.independentSources
                )
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            if let method {
                methodView(method)
            }

            if !verification.claims.isEmpty {
                Divider()
                ForEach(verification.claims) { claim in
                    claimRow(claim)
                }
            }

            if !verification.conflicts.isEmpty {
                Divider()
                Text("research.conflicts".localized)
                    .font(.system(size: 10, weight: .semibold))
                ForEach(verification.conflicts, id: \.self) { conflict in
                    Text("• \(conflict)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if !verification.missing.isEmpty {
                Divider()
                Text("research.missing".localized)
                    .font(.system(size: 10, weight: .semibold))
                ForEach(verification.missing, id: \.self) { missing in
                    Text("• \(missing)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var strengthRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < verification.strength ? accent : Color.secondary.opacity(0.15))
                        .frame(width: 20, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                L10n.string(
                    "research.strength.a11y",
                    language: settings.appLanguage,
                    verification.strength
                )
            )

            Text(L10n.string("research.strength", language: settings.appLanguage, verification.strength))
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
            EditorialTag(
                text: L10n.string(
                    "research.verdict.\(verification.verdict.rawValue)",
                    language: settings.appLanguage
                ),
                fallbackTint: verdictColor(verification.verdict),
                filled: true
            )
        }
    }

    private func claimRow(_ claim: ClaimCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: claimIcon(claim.status))
                    .font(.system(size: 9))
                    .foregroundStyle(claimColor(claim.status))
                    .accessibilityLabel(claimAccessibility(claim.status))
                Text(claim.claim)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }

            if !claim.evidenceIDs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(claim.evidenceIDs, id: \.self) { id in
                        ResearchEvidenceChip(
                            id: id,
                            evidence: evidence.first { $0.id == id },
                            contextID: recordID
                        )
                    }
                }
            }

            if !claim.note.isEmpty {
                Text(claim.note)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Method

    private func methodView(_ method: ResearchMethod) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                methodRow(
                    "research.method.providers".localized,
                    value: method.providers.isEmpty
                        ? "research.method.none".localized
                        : method.providers.map(providerName).joined(separator: " · ")
                )
                methodRow(
                    "research.method.queries".localized,
                    value: L10n.string(
                        "research.method.value.queries",
                        language: settings.appLanguage,
                        method.queries.count
                    )
                )
                methodRow(
                    "research.method.pages".localized,
                    value: L10n.string(
                        "research.method.value.pages",
                        language: settings.appLanguage,
                        method.pagesRead
                    )
                )
                methodRow(
                    "research.method.recency".localized,
                    value: L10n.string(
                        "research.method.recency.\(method.recency)",
                        language: settings.appLanguage
                    )
                )
                if method.failovers > 0 {
                    methodRow(
                        "research.method.failovers".localized,
                        value: L10n.string(
                            "research.method.value.failovers",
                            language: settings.appLanguage,
                            method.failovers
                        )
                    )
                }
                if !method.queries.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(method.queries.prefix(6)), id: \.self) { query in
                            Text("· \(query)")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("research.method.title".localized)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func methodRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 9))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    private func providerName(_ raw: String) -> String {
        SearchProviderID(rawValue: raw)?.displayName ?? raw
    }

    private func verdictColor(_ verdict: VerificationReport.Verdict) -> Color {
        switch verdict {
        case .confirmed, .mostlyConfirmed: return .green
        case .mixed: return .orange
        case .unverified: return .secondary
        case .refuted: return .red
        }
    }

    private func claimIcon(_ stance: EvidenceStance?) -> String {
        switch stance {
        case .supports: return "checkmark.circle.fill"
        case .refutes: return "xmark.circle.fill"
        case .unclear, .none: return "questionmark.circle"
        }
    }

    private func claimColor(_ stance: EvidenceStance?) -> Color {
        switch stance {
        case .supports: return .green
        case .refutes: return .red
        case .unclear, .none: return .orange
        }
    }

    private func claimAccessibility(_ stance: EvidenceStance?) -> String {
        switch stance {
        case .supports: return "research.stance.supports".localized
        case .refutes: return "research.stance.refutes".localized
        case .unclear, .none: return "research.stance.unclear".localized
        }
    }
}
