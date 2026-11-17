import SwiftUI

// MARK: - Shared section chrome

struct WorkspaceSectionHeader: View {
    @Environment(AppSettings.self) private var settings

    let symbol: String
    let title: String
    var trailing: String? = nil

    private var isRetro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .black,
                              design: isRetro ? .serif : .default))
                .tracking(isRetro ? 0.7 : 0.25)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.4))
                .frame(height: 1)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceOriginBadge: View {
    let isEvent: Bool

    var body: some View {
        Text(isEvent ? "workspace.origin.event".localized : "workspace.origin.research".localized)
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(isEvent ? Color.orange : Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((isEvent ? Color.orange : Color.accentColor).opacity(0.10))
            .editorialClipShape(cornerRadius: 4)
    }
}

struct WorkspaceVerificationBadge: View {
    let verification: WorkspaceEvidenceVerification

    private var key: String {
        switch verification {
        case .verifiedQuote: return "workspace.evidence.verified"
        case .unverifiedQuote: return "workspace.evidence.unverified"
        case .snippetOnly: return "workspace.evidence.snippet"
        }
    }

    private var tint: Color {
        switch verification {
        case .verifiedQuote: return .green
        case .unverifiedQuote: return .orange
        case .snippetOnly: return .secondary
        }
    }

    var body: some View {
        Text(key.localized)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.10))
            .editorialClipShape(cornerRadius: 4)
    }
}

// MARK: - Full report reading

/// The full report, not a summary card. Used by the latest report and by every
/// historical version, so an old version is as readable as the current one.
struct WorkspaceReportBody: View {
    @Environment(AppSettings.self) private var settings

    let report: BurstResearch
    var isHistorical = false
    let onOpenURL: (String, String) -> Void

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var evidenceByID: [String: EvidenceItem] {
        Dictionary(report.evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !report.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                section("workspace.report.summary".localized, symbol: "text.alignleft") {
                    Text(report.summary)
                        .font(.system(size: 13, weight: .regular,
                                      design: isRetro ? .serif : .default))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !report.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                section("workspace.report.overview".localized, symbol: "doc.richtext") {
                    Text(report.overview)
                        .font(.system(size: 12, design: isRetro ? .serif : .default))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let verification = report.verification {
                verificationSection(verification)
            }

            if !report.limitations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                section("workspace.report.limitations".localized, symbol: "exclamationmark.bubble") {
                    Text(report.limitations)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            evidenceSection
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if let verification = report.verification {
                    Text(L10n.string(
                        "research.verdict.\(verification.verdict.rawValue)",
                        language: settings.appLanguage
                    ))
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(verdictColor(verification.verdict))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(verdictColor(verification.verdict).opacity(0.11))
                    .editorialClipShape(cornerRadius: 5)

                    Text("\(verification.strength)/4")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(L10n.string(
                        "workspace.report.independent",
                        language: settings.appLanguage,
                        verification.independentSources
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                } else {
                    Text("workspace.report.legacy".localized)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                if isHistorical {
                    Text("workspace.report.historical".localized)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.10))
                        .editorialClipShape(cornerRadius: 4)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let generatedAt = report.generatedAt {
                    Label(generatedAt.formatted(date: .abbreviated, time: .shortened),
                          systemImage: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Label(L10n.string(
                    "workspace.report.depth",
                    language: settings.appLanguage,
                    L10n.string("workspace.research.depth.\(report.depth.rawValue)", language: settings.appLanguage)
                ), systemImage: "scope")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                if let method = report.method, method.pagesRead > 0 {
                    Label(L10n.string(
                        "workspace.report.pages",
                        language: settings.appLanguage,
                        method.pagesRead
                    ), systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func verificationSection(_ verification: VerificationReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !verification.claims.isEmpty {
                section("workspace.report.claims".localized, symbol: "checklist") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(verification.claims.enumerated()), id: \.offset) { _, claim in
                            claimRow(claim)
                        }
                    }
                }
            }

            if !verification.conflicts.isEmpty {
                section("workspace.report.conflicts".localized, symbol: "arrow.triangle.branch") {
                    bulletList(verification.conflicts, tint: .orange)
                }
            }

            if !verification.missing.isEmpty {
                section("workspace.report.missing".localized, symbol: "questionmark.circle") {
                    bulletList(verification.missing, tint: .secondary)
                }
            }
        }
    }

    private func claimRow(_ claim: ClaimCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: claimSymbol(claim.status))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(claimColor(claim.status))
                    .accessibilityHidden(true)
                Text(claim.claim)
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !claim.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(claim.note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 15)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let cited = claim.evidenceIDs.compactMap { evidenceByID[$0] }
            if !cited.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cited) { item in
                        evidenceQuote(item, compact: true)
                    }
                }
                .padding(.leading, 15)
            }
        }
    }

    private var evidenceSection: some View {
        section(
            "workspace.report.evidence".localized,
            symbol: "quote.bubble",
            trailing: "\(report.evidence.count)"
        ) {
            if report.evidence.isEmpty {
                Text("workspace.evidence.empty".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.evidence) { item in
                        evidenceQuote(item, compact: false)
                    }
                }
            }
        }
    }

    private func evidenceQuote(_ item: EvidenceItem, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(item.id)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(item.title.isEmpty ? item.domain : item.title)
                    .font(.system(size: compact ? 10 : 11, weight: .medium))
                    .lineLimit(compact ? 1 : 2)
                Spacer(minLength: 0)
                Text(item.quoteVerified
                     ? "workspace.evidence.verified".localized
                     : "workspace.evidence.unverified".localized)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(item.quoteVerified ? .green : .orange)
            }

            if !item.quote.isEmpty {
                Text("“\(item.quote)”")
                    .font(.system(size: compact ? 10 : 11,
                                  design: isRetro ? .serif : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 3 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 6) {
                Text(item.domain)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Text(stanceText(item.stance))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Text("T\(item.tier.rawValue)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("workspace.evidence.open".localized) {
                    onOpenURL(item.url, item.title.isEmpty ? item.domain : item.title)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(L10n.string(
                    "workspace.evidence.openLabel",
                    language: settings.appLanguage,
                    item.domain
                ))
            }
        }
        .padding(compact ? 7 : 9)
        .background(.quaternary.opacity(compact ? 0.16 : 0.22))
        .editorialClipShape(cornerRadius: 7)
    }

    private func bulletList(_ items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(tint)
                        .frame(width: 4, height: 4)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        symbol: String,
        trailing: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            WorkspaceSectionHeader(symbol: symbol, title: title, trailing: trailing)
            content()
        }
    }

    private func claimSymbol(_ status: EvidenceStance?) -> String {
        switch status {
        case .supports: return "checkmark.circle.fill"
        case .refutes: return "xmark.octagon.fill"
        case .unclear: return "questionmark.circle"
        case nil: return "questionmark.circle"
        }
    }

    private func claimColor(_ status: EvidenceStance?) -> Color {
        switch status {
        case .supports: return .green
        case .refutes: return .red
        case .unclear: return .orange
        case nil: return .secondary
        }
    }

    private func stanceText(_ stance: EvidenceStance) -> String {
        switch stance {
        case .supports: return "workspace.evidence.supports".localized
        case .refutes: return "workspace.evidence.refutes".localized
        case .unclear: return "workspace.evidence.unclear".localized
        }
    }

    private func verdictColor(_ verdict: VerificationReport.Verdict) -> Color {
        switch verdict {
        case .confirmed, .mostlyConfirmed: return .green
        case .mixed: return .orange
        case .unverified: return .secondary
        case .refuted: return .red
        }
    }
}

// MARK: - Markdown

enum WorkspaceReportMarkdown {
    static func make(report: BurstResearch, subjectTitle: String, versionLabel: String?) -> String {
        var lines: [String] = []
        lines.append("# \(subjectTitle)")
        if let versionLabel {
            lines.append("*\(versionLabel)*")
        }
        if let verification = report.verification {
            lines.append(
                "**\(verification.verdict.rawValue)** · \(verification.strength)/4 · "
                    + "\(verification.independentSources) independent sources"
            )
        }
        if let generatedAt = report.generatedAt {
            lines.append(generatedAt.formatted(date: .abbreviated, time: .shortened))
        }
        lines.append("")

        if !report.summary.isEmpty {
            lines.append("## Summary")
            lines.append(report.summary)
            lines.append("")
        }
        if !report.overview.isEmpty {
            lines.append("## Overview")
            lines.append(report.overview)
            lines.append("")
        }
        if let verification = report.verification {
            if !verification.claims.isEmpty {
                lines.append("## Claims")
                for claim in verification.claims {
                    let status = claim.status?.rawValue ?? "unchecked"
                    lines.append("- [\(status)] \(claim.claim)")
                    if !claim.note.isEmpty {
                        lines.append("  - \(claim.note)")
                    }
                }
                lines.append("")
            }
            if !verification.conflicts.isEmpty {
                lines.append("## Conflicts")
                lines.append(contentsOf: verification.conflicts.map { "- \($0)" })
                lines.append("")
            }
            if !verification.missing.isEmpty {
                lines.append("## Missing")
                lines.append(contentsOf: verification.missing.map { "- \($0)" })
                lines.append("")
            }
        }
        if !report.limitations.isEmpty {
            lines.append("## Limitations")
            lines.append(report.limitations)
            lines.append("")
        }
        if !report.evidence.isEmpty {
            lines.append("## Evidence")
            for item in report.evidence {
                lines.append("### \(item.id) \(item.title)")
                lines.append("- \(item.url)")
                lines.append("- \(item.quoteVerified ? "quote verified" : "quote unverified")"
                    + " · tier \(item.tier.rawValue) · \(item.stance.rawValue)")
                if !item.quote.isEmpty {
                    lines.append("")
                    lines.append("> \(item.quote)")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}
