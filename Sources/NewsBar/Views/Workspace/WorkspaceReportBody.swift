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
