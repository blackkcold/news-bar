import SwiftUI

/// Shown on the RSS settings pane when no source has ever been added.
///
/// The card is deliberately a single, calm surface: three starter picks with
/// one-tap add, the three-step mental model, and one disclosure that reveals
/// the full catalog. Everything it needs is passed in, so the rendering tests
/// can exercise it without the rest of the settings surface.
struct RSSOnboardingCard: View {
    @Environment(AppSettings.self) private var settings

    let picks: [RSSRecommendation]
    let showsAllRecommendations: Bool
    let onAdd: (RSSRecommendation) -> Void
    let onToggleAll: () -> Void
    let onImportOPML: () -> Void

    private var retro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !picks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(picks.enumerated()), id: \.element.id) { index, pick in
                        if index > 0 { divider }
                        pickRow(pick)
                    }
                }
            }

            steps
            actionRow
        }
        .padding(14)
        .background { cardBackground }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            EditorialSourceBadge(mark: .rss, fallbackTint: .blue, size: 38, rotation: -1)

            VStack(alignment: .leading, spacing: 4) {
                Text("rss.onboarding.title".localized)
                    .font(.system(size: 15, weight: retro ? .black : .semibold, design: retro ? .serif : .default))
                    .foregroundStyle(retro ? RetroEditorialTokens.ink : .primary)

                Text("rss.onboarding.body".localized)
                    .font(.system(size: 11, weight: .regular, design: retro ? .serif : .default))
                    .foregroundStyle(retro ? RetroEditorialTokens.fadedInk : .secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Steps

    private var steps: some View {
        HStack(spacing: 8) {
            step(number: "1", text: "rss.onboarding.step1")
            step(number: "2", text: "rss.onboarding.step2")
            step(number: "3", text: "rss.onboarding.step3")
            Spacer(minLength: 0)
        }
    }

    private func step(number: String, text: String) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.system(size: 9, weight: .black, design: retro ? .monospaced : .default))
                .foregroundStyle(retro ? RetroEditorialTokens.raisedPaper : .white)
                .frame(width: 16, height: 16)
                .background(retro ? RetroEditorialTokens.brick : Color.accentColor, in: Circle())
                .overlay {
                    if retro {
                        Circle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1)
                    }
                }

            Text(text.localized)
                .font(.system(size: 10, weight: .medium, design: retro ? .serif : .default))
                .foregroundStyle(retro ? RetroEditorialTokens.fadedInk : .secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Picks

    private func pickRow(_ pick: RSSRecommendation) -> some View {
        HStack(alignment: .center, spacing: 10) {
            EditorialTag(
                text: pick.category.rawValue,
                fallbackTint: tint(for: pick.category)
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(pick.name)
                    .font(.system(size: 12.5, weight: .medium, design: retro ? .serif : .default))
                    .foregroundStyle(retro ? RetroEditorialTokens.ink : .primary)
                    .lineLimit(1)

                Text(reason(for: pick.name))
                    .font(.system(size: 10, weight: .regular, design: retro ? .serif : .default))
                    .foregroundStyle(retro ? RetroEditorialTokens.fadedInk : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("rss.add".localized) {
                onAdd(pick)
            }
            .buttonStyle(EditorialActionButtonStyle(tone: .prominent, compact: true))
            .controlSize(.small)
            .accessibilityLabel(L10n.string("rss.addNamed", pick.name))
            .accessibilityHint("rss.addHint".localized)
        }
        .padding(.vertical, 7)
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                onImportOPML()
            } label: {
                Label("rss.onboarding.import".localized, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .controlSize(.small)

            Button {
                onToggleAll()
            } label: {
                Text(
                    showsAllRecommendations
                        ? "rss.onboarding.hideAll".localized
                        : L10n.string("rss.onboarding.showAll", RSSRecommendations.all.count)
                )
            }
            .buttonStyle(EditorialActionButtonStyle(compact: true))
            .controlSize(.small)

            Spacer(minLength: 0)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(retro ? RetroEditorialTokens.ink.opacity(0.18) : Color(nsColor: .separatorColor).opacity(0.28))
            .frame(height: 1)
            .padding(.leading, 0)
    }

    // MARK: - Surface

    @ViewBuilder
    private var cardBackground: some View {
        if retro {
            Rectangle()
                .fill(RetroEditorialTokens.raisedPaper)
                .overlay {
                    Rectangle()
                        .strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.2)
                }
                .shadow(color: RetroEditorialTokens.ink.opacity(0.16), radius: 0, x: 2, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                }
        }
    }

    // MARK: - Content helpers

    private func tint(for category: RSSRecommendation.Category) -> Color {
        switch category {
        case .tech: return .blue
        case .general: return .orange
        case .finance: return .green
        case .design: return .purple
        case .international: return .indigo
        case .lifestyle: return .pink
        }
    }

    private func reason(for name: String) -> String {
        switch name {
        case "中国新闻网": return "rss.onboarding.pick.chinanews".localized
        case "量子位": return "rss.onboarding.pick.quantum".localized
        case "FT 中文网": return "rss.onboarding.pick.ft".localized
        default: return URL(string: RSSStarterPickURL.fallback(for: name))?.host ?? ""
        }
    }
}

/// Keeps the starter reason lookup independent from the catalog object so the
/// card can render a stable fallback if a pick is temporarily missing.
private enum RSSStarterPickURL {
    static func fallback(for name: String) -> String {
        RSSRecommendations.all.first { $0.name == name }?.url ?? ""
    }
}
