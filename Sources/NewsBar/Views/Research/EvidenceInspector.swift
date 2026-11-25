import SwiftUI

/// One evidence card in the report: source title, verified quote, tier, stance
/// and the original link.
struct ResearchEvidenceRow: View {
    @Environment(AppSettings.self) private var settings
    let item: EvidenceItem
    let contextID: String

    private var isRetro: Bool { settings.appTheme == .retroEditorial }
    private var accent: Color {
        isRetro ? RetroEditorialTokens.brick : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.id)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.1))
                    .editorialClipShape(cornerRadius: 4)

                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(L10n.string("research.tier.\(item.tier.rawValue)", language: settings.appLanguage))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: item.quoteVerified ? "checkmark.seal.fill" : "questionmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(item.quoteVerified ? .green : .orange)
                    .accessibilityLabel(
                        (item.quoteVerified ? "research.quoteVerified" : "research.quoteUnverified").localized
                    )
            }

            if !item.quote.isEmpty {
                Text("“\(item.quote)”")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text(item.domain)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(L10n.string("research.stance.\(item.stance.rawValue)", language: settings.appLanguage))
                    .font(.system(size: 9))
                    .foregroundStyle(stanceColor(item.stance))
                if let publishedAt = item.publishedAt {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(Self.dateFormatter.string(from: publishedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                if item.syndicationGroup != nil {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("research.evidence.syndication".localized)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Button("research.action.open".localized) {
                    NewsNavigationRouter.shared.open(
                        url: item.url,
                        title: item.title,
                        surface: "researchEvidence",
                        contextID: contextID
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(accent)
            }
        }
        .padding(11)
        .newsCardSurface(cornerRadius: 10)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func stanceColor(_ stance: EvidenceStance) -> Color {
        switch stance {
        case .supports: return .green
        case .refutes: return .red
        case .unclear: return .orange
        }
    }
}

/// Owned by the transient window so Escape can dismiss a citation before
/// closing the window, even if the key command reaches the host first.
@MainActor @Observable
final class ResearchReportCitationPresentation {
    var activeChip: UUID?

    @discardableResult
    func dismiss() -> Bool {
        guard activeChip != nil else { return false }
        activeChip = nil
        return true
    }
}

extension EnvironmentValues {
    @Entry var researchReportCitations: ResearchReportCitationPresentation? = nil
}

/// Small `E1` chip that opens the evidence inspector popover. A chip whose ID
/// has no matching evidence stays inert and visually muted.
struct ResearchEvidenceChip: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.researchReportCitations) private var readerCitations
    let id: String
    let evidence: EvidenceItem?
    var contextID: String? = nil

    @State private var showsPopover = false
    @State private var chipKey = UUID()
    @FocusState private var hasKeyboardFocus: Bool
    @AccessibilityFocusState(for: .voiceOver) private var hasVoiceOverFocus: Bool

    private var presentation: Binding<Bool> {
        guard let readerCitations else { return $showsPopover }
        return Binding {
            readerCitations.activeChip == chipKey
        } set: { visible in
            if visible {
                readerCitations.activeChip = chipKey
            } else if readerCitations.activeChip == chipKey {
                readerCitations.dismiss()
            }
        }
    }

    private var accent: Color {
        settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : .accentColor
    }

    var body: some View {
        if readerCitations == nil {
            chip
        } else {
            chip
                .focused($hasKeyboardFocus)
                .accessibilityFocused($hasVoiceOverFocus)
                .accessibilityValue((presentation.wrappedValue
                    ? "research.report.sources.expand" : "research.report.sources.collapse").localized)
                .disabled(evidence == nil)
                .onChange(of: presentation.wrappedValue) { wasPresented, isPresented in
                    // Don't move focus back to the first chip if the user
                    // clicked a second one while the first card was open.
                    guard wasPresented, !isPresented, readerCitations?.activeChip == nil else { return }
                    hasKeyboardFocus = true
                    hasVoiceOverFocus = true
                }
        }
    }

    private var chip: some View {
        Button {
            guard evidence != nil else { return }
            presentation.wrappedValue.toggle()
        } label: {
            Text(id)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(evidence == nil ? Color.secondary : accent)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(accent.opacity(evidence == nil ? 0.05 : 0.1))
                .editorialClipShape(cornerRadius: 3)
        }
        .buttonStyle(.plain)
        .help(evidence?.title ?? "")
        .accessibilityLabel(
            L10n.string(
                "research.evidence.chipA11y",
                language: settings.appLanguage,
                id,
                evidence?.title ?? "research.evidence.missing".localized
            )
        )
        .popover(isPresented: presentation, arrowEdge: .bottom) {
            if let evidence {
                ResearchEvidenceInspector(
                    item: evidence,
                    contextID: contextID,
                    onClose: readerCitations.map { _ in { presentation.wrappedValue = false } }
                )
            }
        }
    }
}

private struct ResearchEvidenceInspector: View {
    @Environment(AppSettings.self) private var settings
    let item: EvidenceItem
    let contextID: String?
    var onClose: (() -> Void)? = nil

    var body: some View {
        if let onClose {
            card.onExitCommand(perform: onClose)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(item.id)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                Text(L10n.string("research.tier.\(item.tier.rawValue)", language: settings.appLanguage))
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: item.quoteVerified ? "checkmark.seal.fill" : "questionmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(item.quoteVerified ? .green : .orange)
                    .help(
                        (item.quoteVerified ? "research.quoteVerified" : "research.quoteUnverified").localized
                    )
            }

            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            if !item.quote.isEmpty {
                Text("“\(item.quote)”")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 5) {
                Text(item.domain)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(L10n.string("research.stance.\(item.stance.rawValue)", language: settings.appLanguage))
                    .font(.system(size: 9))
                    .foregroundStyle(stanceColor(item.stance))
                if let publishedAt = item.publishedAt {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(Self.dateFormatter.string(from: publishedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            if item.syndicationGroup != nil {
                Text("research.evidence.syndication".localized)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                if let onClose {
                    Button("research.report.citation.close".localized, action: onClose)
                        .controlSize(.small)
                }
                Spacer()
                Button("research.action.open".localized) {
                    NewsNavigationRouter.shared.open(
                        url: item.url,
                        title: item.title,
                        surface: "researchEvidence",
                        contextID: contextID
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func stanceColor(_ stance: EvidenceStance) -> Color {
        switch stance {
        case .supports: return .green
        case .refutes: return .red
        case .unclear: return .orange
        }
    }
}
