import SwiftUI

enum RetroEditorialTokens {
    static let paper = Color(red: 0.94, green: 0.87, blue: 0.76)
    static let raisedPaper = Color(red: 0.98, green: 0.92, blue: 0.83)
    static let brick = Color(red: 0.62, green: 0.15, blue: 0.10)
    static let ink = Color(red: 0.08, green: 0.07, blue: 0.06)
    static let fadedInk = Color(red: 0.30, green: 0.25, blue: 0.20)
    static let rule = Color(red: 0.12, green: 0.10, blue: 0.08)
    static let mutedBrick = Color(red: 0.48, green: 0.13, blue: 0.09)
}

enum EditorialButtonTone {
    case primary
    case secondary
    case destructive
}

enum EditorialSourceMark {
    case weibo
    case bilibili
    case rss

    var monogram: String {
        switch self {
        case .weibo: return "热"
        case .bilibili: return "B"
        case .rss: return "R"
        }
    }

    var imprint: String {
        switch self {
        case .weibo: return "WEIBO"
        case .bilibili: return "BILI"
        case .rss: return "WIRE"
        }
    }

    var modernSymbol: String {
        switch self {
        case .weibo: return "flame.fill"
        case .bilibili: return "play.rectangle.fill"
        case .rss: return "antenna.radiowaves.left.and.right"
        }
    }
}

struct EditorialSourceBadge: View {
    @Environment(AppSettings.self) private var settings

    let mark: EditorialSourceMark
    var fallbackTint: Color
    var size: CGFloat = 30
    var rotation: Double = 0

    private var retro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        Group {
            if retro {
                ZStack {
                    Rectangle()
                        .fill(RetroEditorialTokens.ink.opacity(0.72))
                        .offset(x: 2, y: 2)

                    Rectangle()
                        .fill(RetroEditorialTokens.raisedPaper)
                        .overlay {
                            Rectangle()
                                .strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.4)
                        }

                    VStack(spacing: 0) {
                        Text(mark.monogram)
                            .font(.system(size: size * 0.45, weight: .black, design: .serif))
                            .minimumScaleFactor(0.65)
                            .lineLimit(1)

                        Rectangle()
                            .fill(RetroEditorialTokens.brick)
                            .frame(height: max(2, size * 0.08))

                        Text(mark.imprint)
                            .font(.system(size: max(5, size * 0.18), weight: .black, design: .monospaced))
                            .tracking(size >= 28 ? 0.35 : 0)
                            .minimumScaleFactor(0.62)
                            .lineLimit(1)
                            .foregroundStyle(RetroEditorialTokens.brick)
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                }
                .rotationEffect(.degrees(rotation))
            } else {
                EditorialSymbolBadge(
                    symbol: mark.modernSymbol,
                    fallbackTint: fallbackTint,
                    size: size
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct EditorialSymbolBadge: View {
    @Environment(AppSettings.self) private var settings

    let symbol: String
    var fallbackTint: Color = .accentColor
    var size: CGFloat = 28
    var rotation: Double = -1.5

    private var retro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        ZStack {
            if retro {
                Rectangle()
                    .fill(RetroEditorialTokens.brick)
                    .overlay {
                        Rectangle()
                            .strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.4)
                    }
                    .shadow(color: RetroEditorialTokens.ink.opacity(0.7), radius: 0, x: 2, y: 2)
            } else {
                RoundedRectangle(cornerRadius: min(11, size * 0.36), style: .continuous)
                    .fill(fallbackTint.opacity(0.16))
            }

            Image(systemName: symbol)
                .font(.system(size: size * 0.43, weight: .black))
                .foregroundStyle(retro ? RetroEditorialTokens.raisedPaper : fallbackTint)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(retro ? rotation : 0))
        .accessibilityHidden(true)
    }
}

struct EditorialTag: View {
    @Environment(AppSettings.self) private var settings

    let text: String
    var fallbackTint: Color = .secondary
    var filled = false

    private var retro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .black, design: retro ? .serif : .default))
            .tracking(retro ? 0.8 : 0)
            .foregroundStyle(retro && filled ? RetroEditorialTokens.raisedPaper : (retro ? RetroEditorialTokens.brick : fallbackTint))
            .padding(.horizontal, retro ? 7 : 6)
            .padding(.vertical, retro ? 3 : 2)
            .background {
                if retro {
                    Rectangle().fill(filled ? RetroEditorialTokens.brick : RetroEditorialTokens.raisedPaper)
                } else {
                    Capsule().fill(fallbackTint.opacity(0.12))
                }
            }
            .overlay {
                if retro {
                    Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1)
                }
            }
    }
}

struct EditorialSectionHeading: View {
    @Environment(AppSettings.self) private var settings

    let index: String
    let title: String
    let subtitle: String

    private var retro: Bool { settings.appTheme == .retroEditorial }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(index)
                .font(.system(size: 12, weight: .black, design: retro ? .monospaced : .default))
                .foregroundStyle(.white)
                .frame(width: 28, height: 24)
                .background(retro ? RetroEditorialTokens.brick : Color.accentColor)
                .overlay {
                    if retro {
                        Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.2)
                    }
                }
                .editorialClipShape(cornerRadius: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 17, weight: retro ? .black : .semibold, design: retro ? .serif : .default))
                    .tracking(retro ? 0.5 : 0)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: retro ? .serif : .default))
                    .foregroundStyle(retro ? RetroEditorialTokens.fadedInk : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Rectangle()
                .fill(retro ? RetroEditorialTokens.ink : Color(nsColor: .separatorColor))
                .frame(minWidth: 24, maxWidth: 96, minHeight: 2, maxHeight: 2)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EditorialActionButtonStyle: ButtonStyle {
    @Environment(AppSettings.self) private var settings
    @Environment(\.isEnabled) private var isEnabled

    var tone: EditorialButtonTone = .secondary
    var compact = false

    private var retro: Bool { settings.appTheme == .retroEditorial }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 10 : 11, weight: retro ? .black : .medium, design: retro ? .serif : .default))
            .tracking(retro ? 0.35 : 0)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, compact ? 8 : 11)
            .padding(.vertical, compact ? 4 : 6)
            .background { buttonBackground }
            .overlay { buttonBorder }
            .compositingGroup()
            .clipShape(buttonShape)
            .background {
                if retro && isEnabled {
                    Rectangle()
                        .fill(RetroEditorialTokens.ink.opacity(0.7))
                        .offset(x: 2, y: 2)
                }
            }
            .offset(x: configuration.isPressed && retro ? 1 : 0, y: configuration.isPressed && retro ? 1 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        guard retro else { return .primary }
        switch tone {
        case .primary, .destructive: return RetroEditorialTokens.raisedPaper
        case .secondary: return RetroEditorialTokens.ink
        }
    }

    @ViewBuilder
    private var buttonBackground: some View {
        if retro {
            Rectangle().fill(retroFill)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary.opacity(0.65))
        }
    }

    @ViewBuilder
    private var buttonBorder: some View {
        if retro {
            Rectangle().strokeBorder(RetroEditorialTokens.ink, lineWidth: 1.2)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }

    private var buttonShape: AnyShape {
        retro ? AnyShape(Rectangle()) : AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var retroFill: Color {
        switch tone {
        case .primary: return RetroEditorialTokens.brick
        case .secondary: return RetroEditorialTokens.raisedPaper
        case .destructive: return RetroEditorialTokens.ink
        }
    }
}

struct AppThemeBackground: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if settings.appTheme == .retroEditorial {
                ZStack {
                    LinearGradient(
                        colors: [
                            RetroEditorialTokens.raisedPaper,
                            RetroEditorialTokens.paper,
                            RetroEditorialTokens.raisedPaper.opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RetroPaperGrain()
                }
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct RetroPaperGrain: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x1966_0421
            let dotCount = max(220, Int((size.width * size.height) / 1_600))

            for _ in 0..<dotCount {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let x = CGFloat(seed % 10_000) / 10_000 * size.width
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let y = CGFloat(seed % 10_000) / 10_000 * size.height
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let diameter = CGFloat(1 + seed % 3) * 0.42
                let dot = Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter))
                context.fill(dot, with: .color(RetroEditorialTokens.ink.opacity(0.075)))
            }
        }
        .blendMode(.multiply)
        .allowsHitTesting(false)
    }
}

private struct AppThemeSurfaceModifier: ViewModifier {
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        content
            .fontDesign(settings.appTheme == .retroEditorial ? .serif : nil)
            .tint(settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : .accentColor)
            .foregroundStyle(settings.appTheme == .retroEditorial ? RetroEditorialTokens.ink : .primary)
            .background { AppThemeBackground() }
    }
}

private struct NewsCardSurfaceModifier: ViewModifier {
    @Environment(AppSettings.self) private var settings
    let cornerRadius: CGFloat
    let rotation: Double
    let isHovering: Bool

    private var retro: Bool { settings.appTheme == .retroEditorial }
    private var radius: CGFloat { retro ? 0 : cornerRadius }
    private var shadowOffset: CGFloat { isHovering ? 5 : 3 }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(retro ? RetroEditorialTokens.raisedPaper : Color.clear)
                    .background {
                        if !retro {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        retro ? RetroEditorialTokens.rule : Color(nsColor: .separatorColor).opacity(isHovering ? 0.45 : 0.32),
                        lineWidth: retro ? 1.7 : 1
                    )
            }
            .overlay(alignment: .top) {
                if retro {
                    Rectangle()
                        .fill(RetroEditorialTokens.brick)
                        .frame(height: 4)
                }
            }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background {
                if retro {
                    Rectangle()
                        .fill(RetroEditorialTokens.ink.opacity(isHovering ? 0.82 : 0.68))
                        .offset(x: shadowOffset, y: shadowOffset)
                }
            }
            .rotationEffect(.degrees(retro ? rotation : 0))
    }
}

private struct EditorialImageModifier: ViewModifier {
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        content
            .saturation(settings.appTheme == .retroEditorial ? 0 : 1)
            .contrast(settings.appTheme == .retroEditorial ? 1.16 : 1)
            .brightness(settings.appTheme == .retroEditorial ? -0.035 : 0)
    }
}

private struct EditorialHeadingModifier: ViewModifier {
    @Environment(AppSettings.self) private var settings
    let size: CGFloat

    func body(content: Content) -> some View {
        content.font(
            settings.appTheme == .retroEditorial
                ? .system(size: size, weight: .black, design: .serif)
                : .system(size: size, weight: .semibold)
        )
    }
}

private struct EditorialMastheadModifier: ViewModifier {
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        content
            .background(settings.appTheme == .retroEditorial ? RetroEditorialTokens.raisedPaper : .clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(settings.appTheme == .retroEditorial ? RetroEditorialTokens.brick : Color(nsColor: .separatorColor))
                    .frame(height: settings.appTheme == .retroEditorial ? 3 : 1)
            }
    }
}

private struct EditorialClipShapeModifier: ViewModifier {
    @Environment(AppSettings.self) private var settings
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .compositingGroup()
            .clipShape(
                settings.appTheme == .retroEditorial
                    ? AnyShape(Rectangle())
                    : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
    }
}

extension View {
    func appThemeSurface() -> some View {
        modifier(AppThemeSurfaceModifier())
    }

    func newsCardSurface(
        cornerRadius: CGFloat = 18,
        rotation: Double = 0,
        isHovering: Bool = false
    ) -> some View {
        modifier(
            NewsCardSurfaceModifier(
                cornerRadius: cornerRadius,
                rotation: rotation,
                isHovering: isHovering
            )
        )
    }

    func editorialArchiveImage() -> some View {
        modifier(EditorialImageModifier())
    }

    func editorialHeading(size: CGFloat) -> some View {
        modifier(EditorialHeadingModifier(size: size))
    }

    func editorialMasthead() -> some View {
        modifier(EditorialMastheadModifier())
    }

    func editorialClipShape(cornerRadius: CGFloat) -> some View {
        modifier(EditorialClipShapeModifier(cornerRadius: cornerRadius))
    }
}
