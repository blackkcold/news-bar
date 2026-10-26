import SwiftUI

/// Shared visual tokens. The explanation surface reuses the app's editorial
/// shapes and retro palette without owning a second design system.
struct ExplanationPalette {
    let retro: Bool

    var accent: Color { retro ? RetroEditorialTokens.brick : .accentColor }
    var ink: Color { retro ? RetroEditorialTokens.ink : .primary }
    var secondary: Color { retro ? RetroEditorialTokens.fadedInk : .secondary }
    var cardFill: Color {
        retro ? RetroEditorialTokens.raisedPaper : Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }
    var border: Color {
        retro ? RetroEditorialTokens.rule : Color(nsColor: .separatorColor).opacity(0.4)
    }
    var background: Color {
        retro ? RetroEditorialTokens.paper : Color(nsColor: .windowBackgroundColor)
    }
    var shape: EditorialSurfaceShape {
        EditorialSurfaceShape(cornerRadius: retro ? 0 : 12, isRetro: retro)
    }

    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: retro ? .serif : .default)
    }

    func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct ExplanationCard<Content: View>: View {
    let palette: ExplanationPalette
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(palette.font(12, weight: .bold))
                        .foregroundStyle(palette.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(palette.font(10))
                            .foregroundStyle(palette.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.shape.fill(palette.cardFill))
        .overlay {
            palette.shape.strokeBorder(palette.border, lineWidth: palette.retro ? 1.5 : 1)
        }
        .overlay(alignment: .top) {
            if palette.retro {
                Rectangle().fill(palette.accent).frame(height: 3)
            }
        }
        .clipShape(palette.shape)
    }
}

struct ExplanationNote: View {
    let text: String
    let palette: ExplanationPalette
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(palette.font(10, weight: .semibold))
                .foregroundStyle(palette.secondary)
            Text(text)
                .font(palette.font(10))
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Entry

struct RecommendationExplanationEntry: View {
    let statusTitle: String
    let detail: String
    let theme: AppTheme
    var language: AppLanguage = .zh
    let action: () -> Void

    private var palette: ExplanationPalette { ExplanationPalette(retro: theme == .retroEditorial) }
    private var title: String {
        language == .en ? "How recommendations work" : "推荐原理与我的兴趣"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .font(palette.font(15, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(palette.font(12, weight: .semibold))
                        .foregroundStyle(palette.ink)
                    Text(detail)
                        .font(palette.font(10))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(statusTitle)
                    .font(palette.font(9, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.accent.opacity(0.12), in: Capsule())
                Image(systemName: "chevron.right")
                    .font(palette.font(10, weight: .semibold))
                    .foregroundStyle(palette.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail), \(statusTitle)")
        .accessibilityHint(language == .en
            ? "Opens a read-only explanation of local recommendations."
            : "打开只读的本地推荐解释。")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Sheet chrome

/// Small testable seam for the sheet's explicit exit. A rendered sheet must
/// expose a discoverable Done/Close control for keyboard and VoiceOver users;
/// relying on the system Esc interception alone is not enough.
enum RecommendationExplanationChrome {
    static let closeButtonIdentifier = "recommendationExplanation.close"

    static func closeLabel(_ language: AppLanguage) -> String {
        language == .en ? "Done" : "完成"
    }

    static func closeAccessibilityLabel(_ language: AppLanguage) -> String {
        language == .en ? "Close the recommendation explanation" : "关闭推荐原理与我的兴趣"
    }
}

struct RecommendationExplanationCloseButton: View {
    let language: AppLanguage
    let palette: ExplanationPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(RecommendationExplanationChrome.closeLabel(language))
                .font(palette.font(10, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(RecommendationExplanationChrome.closeButtonIdentifier)
        .accessibilityLabel(RecommendationExplanationChrome.closeAccessibilityLabel(language))
    }
}

// MARK: - Root sheet

struct RecommendationExplanationView: View {
    let model: RecommendationExplanationModel
    let theme: AppTheme

    @Environment(\.dismiss) private var dismiss
    @State private var segment: RecommendationExplanationSegment
    @State private var selectedDimensionID: String?
    @State private var selectedItemID: String?
    @State private var contentWidth: CGFloat = 0

    init(
        model: RecommendationExplanationModel,
        theme: AppTheme,
        initialSegment: RecommendationExplanationSegment = .overview,
        initialDimensionID: String? = nil,
        initialItemID: String? = nil
    ) {
        self.model = model
        self.theme = theme
        _segment = State(initialValue: initialSegment)
        _selectedDimensionID = State(initialValue: initialDimensionID)
        _selectedItemID = State(initialValue: initialItemID)
    }

    private var palette: ExplanationPalette { ExplanationPalette(retro: theme == .retroEditorial) }
    private var language: AppLanguage { model.language }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border)
            ScrollView {
                sectionContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        // One cheap width read drives the wide two-column
                        // layout; it does not participate in sizing.
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { contentWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { _, newValue in contentWidth = newValue }
                        }
                    }
            }
            Divider().overlay(palette.border)
            footer
        }
        .background(palette.background)
        .tint(palette.accent)
        .fontDesign(theme == .retroEditorial ? .serif : nil)
        .frame(minWidth: 520, idealWidth: 660, maxWidth: 980, minHeight: 400, idealHeight: 540)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(palette.font(18, weight: .semibold))
                    .foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(language == .en ? "How recommendations work" : "推荐原理与我的兴趣")
                        .font(palette.font(15, weight: .bold))
                        .foregroundStyle(palette.ink)
                    Text(model.readOnlyNote)
                        .font(palette.font(9))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(model.statusHeadline)
                    .font(palette.font(9, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(palette.accent.opacity(0.12), in: Capsule())
                    .accessibilityLabel(language == .en ? "Status: \(model.statusHeadline)" : "状态：\(model.statusHeadline)")
                RecommendationExplanationCloseButton(language: language, palette: palette) {
                    dismiss()
                }
            }
            Picker(language == .en ? "Section" : "分段", selection: $segment) {
                ForEach(RecommendationExplanationSegment.allCases) { value in
                    Label(value.title(language), systemImage: value.symbol).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(language == .en ? "Explanation section" : "解释分段")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(palette.retro ? RetroEditorialTokens.raisedPaper : Color.clear)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch segment {
        case .overview:
            ExplanationOverviewSection(model: model, palette: palette) {
                segment = .interests
            }
        case .interests:
            ExplanationInterestsSection(model: model, palette: palette, selection: $selectedDimensionID, wide: contentWidth >= 820)
        case .ranking:
            ExplanationRankingSection(model: model, palette: palette, selection: $selectedItemID, wide: contentWidth >= 820)
        case .dataPrivacy:
            ExplanationPrivacySectionView(model: model, palette: palette)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: model.guideUnavailable ? "exclamationmark.triangle" : "book.closed")
                .font(palette.font(9, weight: .semibold))
                .foregroundStyle(palette.secondary)
            Text(model.guideUnavailable
                 ? model.guideUnavailableNote
                 : (language == .en ? "Offline guide included. No network request." : "已包含离线说明，不请求网络。"))
                .font(palette.font(9))
                .foregroundStyle(palette.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
