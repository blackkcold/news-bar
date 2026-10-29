import AppKit
import SwiftUI

/// Native reader mode. The article is re-laid out with SwiftUI from plain text
/// blocks; no CSS is injected into the page and no HTML is rendered here.
struct ReaderModeView: View {
    let document: ReaderModeDocument
    let language: AppLanguage
    var onOpenLink: (URL) -> Void = { _ in }
    var onExit: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var english: Bool { language == .en }
    private var retro: Bool { settings.appTheme == .retroEditorial }
    private var baseSize: CGFloat { 16 * CGFloat(settings.readerModeFontScale) }
    private var lineSpacing: CGFloat { baseSize * CGFloat(settings.readerModeLineSpacing - 1.0) * 0.6 }
    private var columnWidth: CGFloat { CGFloat(settings.readerModeWidth) }
    private var style: ReaderModePageStyle {
        switch settings.readerModeTheme {
        case "paper": return .paper
        case "dark": return .dark
        default: return retro ? .paper : .dynamic
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: baseSize * 0.85) {
                    header
                    Divider().overlay(style.secondary.opacity(0.3))
                    ForEach(document.blocks) { block in
                        blockView(block)
                    }
                    footer
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
        }
        .background(style.background)
        .foregroundStyle(style.ink)
        .tint(style.accent)
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 10) {
            Button(action: onExit) {
                Label(english ? "Web page" : "网页", systemImage: "safari")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(english ? "Leave reader mode and show the web page" : "退出阅读模式，返回网页")
            .accessibilityLabel(english ? "Leave reader mode" : "退出阅读模式")

            Divider().frame(height: 14)

            Text("Aa")
                .font(.system(size: 11, weight: .bold, design: retro ? .serif : .default))
                .foregroundStyle(style.secondary)
                .accessibilityHidden(true)

            Picker(english ? "Text size" : "字号", selection: Binding(
                get: { settings.readerModeFontScale },
                set: { settings.readerModeFontScale = $0 }
            )) {
                Text(english ? "S" : "小").tag(0.9)
                Text(english ? "M" : "标准").tag(1.0)
                Text(english ? "L" : "大").tag(1.15)
                Text(english ? "XL" : "特大").tag(1.35)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .accessibilityLabel(english ? "Reader text size" : "阅读字号")

            Picker(english ? "Line spacing" : "行距", selection: Binding(
                get: { settings.readerModeLineSpacing },
                set: { settings.readerModeLineSpacing = $0 }
            )) {
                Text(english ? "Tight" : "紧凑").tag(1.35)
                Text(english ? "Normal" : "标准").tag(1.55)
                Text(english ? "Loose" : "宽松").tag(1.75)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 92)
            .accessibilityLabel(english ? "Reader line spacing" : "阅读行距")

            HStack(spacing: 5) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9))
                    .foregroundStyle(style.secondary)
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { settings.readerModeWidth },
                    set: { settings.readerModeWidth = min(760, max(620, $0)) }
                ), in: 620...760, step: 10)
                .frame(width: 90)
                .accessibilityLabel(english ? "Reader text width" : "阅读正文宽度")
                .help(english ? "Text column width \(Int(settings.readerModeWidth)) pt" : "正文宽度 \(Int(settings.readerModeWidth)) pt")
            }

            Picker(english ? "Page" : "页面", selection: Binding(
                get: { settings.readerModeTheme },
                set: { settings.readerModeTheme = $0 }
            )) {
                Text(english ? "Auto" : "自动").tag("auto")
                Text(english ? "Paper" : "纸张").tag("paper")
                Text(english ? "Dark" : "深色").tag("dark")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 152)
            .accessibilityLabel(english ? "Reader page theme" : "阅读页面主题")

            Spacer(minLength: 4)

            Text(english ? "\(document.wordCount) words" : "\(document.wordCount) 字")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(style.secondary)
                .accessibilityLabel(english ? "\(document.wordCount) words" : "全文约 \(document.wordCount) 字")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(style.controlBackground)
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.title)
                .font(.system(size: baseSize * 1.55, weight: .bold, design: retro ? .serif : .default))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                if let byline = document.byline { Text(byline) }
                if let siteName = document.siteName { Text(siteName) }
                if let published = document.publishedAt { Text(published) }
                if let host = URL(string: document.url)?.host { Text(host) }
            }
            .font(.system(size: baseSize * 0.72, design: retro ? .serif : .default))
            .foregroundStyle(style.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 10))
            Text(english
                 ? "Reader mode is reconstructed from plain text. Images load from the article's own site; a failed image never blocks the text."
                 : "阅读模式由纯文本重新排版。图片从原文站点加载；单张图片失败不会阻塞正文。")
                .font(.system(size: 9, design: retro ? .serif : .default))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(style.secondary)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: ReaderModeDocument.Block) -> some View {
        switch block.kind {
        case .paragraph:
            VStack(alignment: .leading, spacing: 4) {
                Text(block.text ?? "")
                    .font(bodyFont)
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                if let href = block.href, let url = URL(string: href) {
                    linkButton(url, title: block.text)
                }
            }
        case .heading2:
            Text(block.text ?? "")
                .font(.system(size: baseSize * 1.32, weight: .bold, design: retro ? .serif : .default))
                .padding(.top, baseSize * 0.35)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .heading3:
            Text(block.text ?? "")
                .font(.system(size: baseSize * 1.12, weight: .semibold, design: retro ? .serif : .default))
                .padding(.top, baseSize * 0.2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .unorderedList, .orderedList:
            VStack(alignment: .leading, spacing: baseSize * 0.32) {
                ForEach(Array(block.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(block.kind == .orderedList ? "\(index + 1)." : "•")
                            .font(bodyFont)
                            .foregroundStyle(style.accent)
                        Text(item)
                            .font(bodyFont)
                            .lineSpacing(lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(style.accent.opacity(0.6))
                    .frame(width: 2)
                Text(block.text ?? "")
                    .font(bodyFont.italic())
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(style.ink.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        case .pre:
            Text(block.text ?? "")
                .font(.system(size: baseSize * 0.86, design: .monospaced))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(style.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: retro ? 0 : 8))
        case .image, .figure:
            ReaderModeImageBlock(
                src: block.src ?? "",
                alt: block.alt,
                caption: block.caption,
                documentURL: document.url,
                language: language,
                style: style,
                maxWidth: columnWidth
            )
        case .rule:
            Divider().overlay(style.secondary.opacity(0.3))
        }
    }

    private var bodyFont: Font {
        .system(size: baseSize, weight: .regular, design: retro ? .serif : .default)
    }

    private func linkButton(_ url: URL, title: String?) -> some View {
        Button {
            onOpenLink(url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                Text(english ? "Open link" : "打开链接")
            }
            .font(.system(size: baseSize * 0.72))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(style.accent)
        .accessibilityLabel(english ? "Open link in the reader" : "在阅读器中打开链接")
        .help(title ?? url.absoluteString)
    }
}

// MARK: - Page style

struct ReaderModePageStyle: Equatable {
    let background: Color
    let controlBackground: Color
    let ink: Color
    let secondary: Color
    let accent: Color
    let codeBackground: Color

    static let dynamic = ReaderModePageStyle(
        background: .clear,
        controlBackground: Color(nsColor: .controlBackgroundColor).opacity(0.4),
        ink: .primary,
        secondary: .secondary,
        accent: .accentColor,
        codeBackground: Color(nsColor: .textBackgroundColor).opacity(0.55)
    )

    static let paper = ReaderModePageStyle(
        background: Color(red: 0.96, green: 0.93, blue: 0.86),
        controlBackground: Color(red: 0.93, green: 0.89, blue: 0.80),
        ink: Color(red: 0.14, green: 0.12, blue: 0.10),
        secondary: Color(red: 0.38, green: 0.34, blue: 0.29),
        accent: RetroEditorialTokens.brick,
        codeBackground: Color(red: 0.91, green: 0.87, blue: 0.78)
    )

    static let dark = ReaderModePageStyle(
        background: Color(red: 0.08, green: 0.09, blue: 0.10),
        controlBackground: Color(red: 0.12, green: 0.13, blue: 0.15),
        ink: Color(red: 0.90, green: 0.89, blue: 0.86),
        secondary: Color(red: 0.61, green: 0.61, blue: 0.58),
        accent: Color(red: 0.85, green: 0.66, blue: 0.36),
        codeBackground: Color(red: 0.13, green: 0.14, blue: 0.16)
    )
}

// MARK: - Images

private struct ReaderModeImageBlock: View {
    let src: String
    let alt: String?
    let caption: String?
    let documentURL: String
    let language: AppLanguage
    let style: ReaderModePageStyle
    let maxWidth: CGFloat

    @State private var image: NSImage?
    @State private var failed = false

    private var english: Bool { language == .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 460)
                        .accessibilityLabel(alt ?? (english ? "Article image" : "文章配图"))
                } else if failed {
                    placeholder
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(style.codeBackground)
                        .frame(height: 120)
                        .overlay { ProgressView().controlSize(.small) }
                        .accessibilityLabel(english ? "Loading image" : "正在加载图片")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(style.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: src) { await load() }
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            Text(alt?.isEmpty == false ? alt! : (english ? "Image could not be loaded" : "图片未能加载"))
        }
        .font(.system(size: 10))
        .foregroundStyle(style.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(english ? "Image could not be loaded" : "图片未能加载")
    }

    private func load() async {
        guard image == nil, !failed, let url = URL(string: src) else { return }
        let host = url.host ?? ""
        let cookies = await BrowserDataController.shared.cookiesForInjection(host: host)
        do {
            let data = try await ReaderModeImageLoader.shared.load(
                url,
                cookies: cookies,
                referer: documentURL
            )
            guard let loaded = NSImage(data: data) else {
                failed = true
                return
            }
            image = loaded
        } catch {
            failed = true
        }
    }
}

/// Small, bounded image fetcher for reader mode. It replays only this site's
/// saved first-party cookies and sends the article URL as referer, matching the
/// reader's own privacy model. Failures are local: the text never waits.
actor ReaderModeImageLoader {
    static let shared = ReaderModeImageLoader()
    static let maxBytes = 8 * 1024 * 1024

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func load(_ url: URL, cookies: [HTTPCookie], referer: String?) async throws -> Data {
        guard url.scheme?.lowercased() == "https",
              ReaderNavigationPolicy.allowedURL(url.absoluteString) != nil else {
            throw ReaderModeImageError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(
            "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8,*/*;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(ReaderUserAgent.value(), forHTTPHeaderField: "User-Agent")
        if !cookies.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        if let referer, let refererURL = URL(string: referer), refererURL.host != nil {
            request.setValue(refererURL.absoluteString, forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ReaderModeImageError.http
        }
        guard data.count <= Self.maxBytes else { throw ReaderModeImageError.tooLarge }
        return data
    }
}

enum ReaderModeImageError: Error, Equatable {
    case invalidURL
    case http
    case tooLarge
}
