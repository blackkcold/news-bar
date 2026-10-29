import SwiftUI

struct ResearchListRow: View {
    @Environment(AppSettings.self) private var settings
    let entry: ResearchIndexEntry
    let isSelected: Bool
    /// Presentation-only retry state. Never persisted.
    var statusOverride: ResearchStatus? = nil

    private var effectiveStatus: ResearchStatus { statusOverride ?? entry.status }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color { isRetro ? RetroEditorialTokens.brick : .accentColor }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(displayTitle)
                        .font(.system(size: 12, weight: entry.isRead ? .regular : .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    if !entry.isRead {
                        Circle()
                            .fill(accent)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("research.unread".localized)
                    }
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("research.action.pin".localized)
                    }
                }

                HStack(spacing: 5) {
                    EditorialSourceBadge(
                        mark: sourceMark,
                        fallbackTint: sourceTint,
                        size: 14
                    )
                    Text(entry.source.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)

                    Text(Self.relativeFormatter.localizedString(for: entry.updatedAt, relativeTo: Date()))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if let issue = entry.issue {
                        Text(issueLabel(issue))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.1))
                            .editorialClipShape(cornerRadius: 4)
                    } else if entry.hasReport {
                        HStack(spacing: 4) {
                            reportBadge
                            if ResearchStatusPresentation.needsAttentionDot(effectiveStatus) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 5, height: 5)
                                    .help(statusLabel)
                                    .accessibilityHidden(true)
                            }
                        }
                    } else {
                        Text(statusLabel)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(statusColor.opacity(0.1))
                            .editorialClipShape(cornerRadius: 4)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(isSelected ? accent.opacity(0.11) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? accent.opacity(0.28) : Color.clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var displayTitle: String {
        entry.topic.isEmpty ? L10n.string("research.status.corrupt", language: settings.appLanguage) : entry.topic
    }

    private var statusLabel: String {
        ResearchStatusPresentation.label(effectiveStatus, language: settings.appLanguage)
    }

    private func issueLabel(_ issue: ResearchEntryIssue) -> String {
        switch issue {
        case .unsupportedVersion:
            return L10n.string("research.issue.unsupportedVersionShort", language: settings.appLanguage)
        case .corrupt:
            return L10n.string("research.status.corrupt", language: settings.appLanguage)
        case .ioUnavailable:
            return L10n.string("research.issue.ioUnavailableShort", language: settings.appLanguage)
        }
    }

    private var accessibilityLabel: String {
        var parts = [displayTitle, entry.source.displayName, statusLabel]
        if let issue = entry.issue {
            parts.append(issueLabel(issue))
        }
        if entry.strength > 0 {
            parts.append(L10n.string("research.strength", language: settings.appLanguage, entry.strength))
        }
        if !entry.isRead {
            parts.append(L10n.string("research.unread", language: settings.appLanguage))
        }
        return parts.joined(separator: "，")
    }

    @ViewBuilder
    private var reportBadge: some View {
        if entry.strength > 0 {
            Text("\(entry.strength)/4")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(accent.opacity(0.1))
                .editorialClipShape(cornerRadius: 4)
                .accessibilityLabel(L10n.string("research.strength", language: settings.appLanguage, entry.strength))
        } else if let verdict = entry.verdict {
            Text(L10n.string("research.verdict.short.\(verdict.rawValue)", language: settings.appLanguage))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(verdictColor(verdict))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(verdictColor(verdict).opacity(0.1))
                .editorialClipShape(cornerRadius: 4)
        }
    }

    private var statusColor: Color {
        ResearchStatusPresentation.tint(effectiveStatus)
    }

    private var sourceMark: EditorialSourceMark {
        switch entry.source {
        case .weibo: return .weibo
        case .bilibili: return .bilibili
        case .rss: return .rss
        }
    }

    private var sourceTint: Color {
        switch entry.source {
        case .weibo: return .orange
        case .bilibili: return .pink
        case .rss: return .blue
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
