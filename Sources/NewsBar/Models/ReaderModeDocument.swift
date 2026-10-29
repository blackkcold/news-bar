import Foundation

/// Native reader-mode document.
///
/// The extractor sends plain text and image URLs only; no HTML ever crosses the
/// web bridge. Decoding therefore doubles as sanitization: unknown block types
/// are dropped, every link is re-checked against `ReaderNavigationPolicy`, and
/// hard caps bound block count, block length and total characters.
struct ReaderModeDocument: Equatable, Sendable {
    static let maxBlocks = 400
    static let maxTextPerBlock = 8_000
    static let maxTotalCharacters = 60_000
    static let maxListItems = 50
    static let maxListItemCharacters = 500
    static let maxCaptionCharacters = 300
    static let maxURLCharacters = 2_048
    static let minimumTextCharacters = 400
    static let minimumTextBlocks = 3
    static let maxImages = 20

    struct Block: Identifiable, Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case paragraph = "p"
            case heading2 = "h2"
            case heading3 = "h3"
            case unorderedList = "ul"
            case orderedList = "ol"
            case quote
            case pre
            case image = "img"
            case figure
            case rule = "hr"

            var isTextual: Bool {
                switch self {
                case .paragraph, .heading2, .heading3, .unorderedList, .orderedList, .quote, .pre:
                    return true
                case .image, .figure, .rule:
                    return false
                }
            }

            var isImage: Bool { self == .image || self == .figure }
        }

        let id: Int
        let kind: Kind
        let text: String?
        let items: [String]
        let src: String?
        let alt: String?
        let caption: String?
        let href: String?

        init(
            id: Int,
            kind: Kind,
            text: String? = nil,
            items: [String] = [],
            src: String? = nil,
            alt: String? = nil,
            caption: String? = nil,
            href: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.items = items
            self.src = src
            self.alt = alt
            self.caption = caption
            self.href = href
        }

        var plainText: String {
            if let text, !text.isEmpty { return text }
            if !items.isEmpty { return items.joined(separator: " ") }
            if let caption, !caption.isEmpty { return caption }
            return ""
        }
    }

    let url: String
    let title: String
    let byline: String?
    let siteName: String?
    let publishedAt: String?
    let lang: String?
    let wordCount: Int
    let blocks: [Block]

    var textBlocks: [Block] { blocks.filter { $0.kind.isTextual } }
    var imageBlocks: [Block] { blocks.filter { $0.kind.isImage && $0.src != nil } }
    var characterCount: Int { textBlocks.reduce(0) { $0 + $1.plainText.count } }

    /// A document is usable only with enough real paragraphs. Anything less
    /// keeps the web view visible so the reader never shows a blank page.
    var isUsable: Bool {
        textBlocks.count >= Self.minimumTextBlocks && characterCount >= Self.minimumTextCharacters
    }

    var plainText: String {
        blocks
            .map(\.plainText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Decoding

    /// Decodes the JS payload. Returns `nil` when the extraction failed, the URL
    /// changed, or the document is too thin to display.
    init?(json: Data, expectedURL: String) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: json) else { return nil }
        self.init(wire: wire, expectedURL: expectedURL)
    }

    init?(payload: [String: Any], expectedURL: String) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        self.init(wire: wire, expectedURL: expectedURL)
    }

    private init?(wire: Wire, expectedURL: String) {
        guard wire.ok else { return nil }
        guard let url = Self.sanitizedURL(wire.url),
              ContentIdentity.canonicalURL(url) == ContentIdentity.canonicalURL(expectedURL) else { return nil }

        let title = Self.clean(wire.title).isEmpty
            ? (URL(string: url)?.host ?? url)
            : String(Self.clean(wire.title).prefix(300))

        var blocks: [Block] = []
        var totalCharacters = 0
        var imageCount = 0

        for raw in wire.blocks {
            guard blocks.count < Self.maxBlocks else { break }
            guard let kind = Block.Kind(rawValue: raw.type) else { continue }
            if kind.isImage {
                guard imageCount < Self.maxImages,
                      let src = Self.sanitizedURL(raw.src) else { continue }
                let alt = raw.alt.map { String(Self.clean($0).prefix(Self.maxCaptionCharacters)) }
                let caption = raw.caption.map { String(Self.clean($0).prefix(Self.maxCaptionCharacters)) }
                blocks.append(Block(
                    id: blocks.count,
                    kind: kind,
                    src: src,
                    alt: alt?.isEmpty == true ? nil : alt,
                    caption: caption?.isEmpty == true ? nil : caption
                ))
                imageCount += 1
                continue
            }

            switch kind {
            case .rule:
                blocks.append(Block(id: blocks.count, kind: .rule))
            case .unorderedList, .orderedList:
                let items = (raw.items ?? [])
                    .prefix(Self.maxListItems)
                    .map { String(Self.clean($0).prefix(Self.maxListItemCharacters)) }
                    .filter { !$0.isEmpty }
                guard !items.isEmpty else { continue }
                let used = items.reduce(0) { $0 + $1.count }
                guard totalCharacters + used <= Self.maxTotalCharacters else { break }
                totalCharacters += used
                blocks.append(Block(id: blocks.count, kind: kind, items: items))
            default:
                guard let rawText = raw.text else { continue }
                let text = String(Self.clean(rawText, preservingNewlines: kind == .pre).prefix(Self.maxTextPerBlock))
                guard !text.isEmpty else { continue }
                let candidate = Block(id: blocks.count, kind: kind, text: text, href: Self.sanitizedURL(raw.href))
                guard !Self.isNoise(candidate) else { continue }
                guard totalCharacters + text.count <= Self.maxTotalCharacters else { break }
                totalCharacters += text.count
                blocks.append(candidate)
            }
        }

        let textBlocks = blocks.filter { $0.kind.isTextual }
        let characterCount = textBlocks.reduce(0) { $0 + $1.plainText.count }
        guard textBlocks.count >= Self.minimumTextBlocks,
              characterCount >= Self.minimumTextCharacters else { return nil }

        self.url = url
        self.title = title
        self.byline = Self.optionalText(wire.byline, limit: 200)
        self.siteName = Self.optionalText(wire.siteName, limit: 200)
        self.publishedAt = Self.optionalText(wire.publishedAt, limit: 64)
        self.lang = Self.optionalText(wire.lang, limit: 16)
        self.blocks = blocks
        let plain = blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        self.wordCount = wire.wordCount > 0 ? wire.wordCount : Self.estimatedWordCount(plain)
    }

    // MARK: - Cleaning

    static func clean(_ raw: String, preservingNewlines: Bool = false) -> String {
        var value = raw
            .replacingOccurrences(
                of: "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(
                of: "[\u{200B}-\u{200F}\u{FEFF}]",
                with: "",
                options: .regularExpression
            )
        value = preservingNewlines
            ? value.replacingOccurrences(of: "[\\t\\r\\x0B\\x0C ]+", with: " ", options: .regularExpression)
            : value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only public HTTPS URLs survive; the reader navigation policy is applied
    /// again here even though the JS layer already rejected non-HTTPS values.
    static func sanitizedURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxURLCharacters,
              let url = ReaderNavigationPolicy.allowedURL(trimmed),
              url.scheme?.lowercased() == "https" else { return nil }
        return url.absoluteString
    }

    /// Second-stage boilerplate filter. The JS extractor already strips
    /// nav/footer/share containers; this catches short leftovers that survived
    /// a site's unusual markup. Long paragraphs are never discarded, so real
    /// prose cannot be mistaken for chrome.
    static func isNoise(_ block: Block) -> Bool {
        guard block.kind.isTextual else { return false }
        if block.kind == .heading2 || block.kind == .heading3 { return false }
        let text = block.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        // A short standalone link is navigation, not article prose. A long
        // linked paragraph can still be part of the text and is kept.
        if block.href != nil && text.count <= 40 { return true }
        let letters = text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        guard letters else { return true }
        guard text.count <= 60 else { return false }
        let folded = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        let exact: Set<String> = [
            "advertisement", "ad", "sponsored", "share", "share this", "share on",
            "subscribe", "newsletter", "sign up for our newsletter", "related articles",
            "read more", "comments", "cookie", "cookies", "sign in", "log in", "follow us",
            "广告", "分享", "订阅", "相关阅读", "阅读更多", "评论", "登录",
        ]
        if exact.contains(folded) { return true }
        let prefixes = [
            "share this", "share on", "sign up for our newsletter", "related articles",
            "read more:", "广告", "分享", "订阅", "相关阅读", "阅读更多", "登录",
            "责任编辑", "微信扫一扫", "关注该公众号", "责任编辑：",
        ]
        return prefixes.contains { folded.hasPrefix($0) }
    }

    private static func optionalText(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let cleaned = String(clean(raw).prefix(limit))
        return cleaned.isEmpty ? nil : cleaned
    }

    static func estimatedWordCount(_ text: String) -> Int {
        var count = 0
        var inLatinRun = false
        for scalar in text.unicodeScalars {
            if (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) {
                count += 1
                inLatinRun = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inLatinRun { count += 1 }
                inLatinRun = true
            } else {
                inLatinRun = false
            }
        }
        return count
    }

    // MARK: - Wire format

    private struct Wire: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
            let items: [String]?
            let src: String?
            let alt: String?
            let caption: String?
            let href: String?
        }

        let ok: Bool
        let reason: String?
        let url: String
        let title: String
        let byline: String?
        let siteName: String?
        let publishedAt: String?
        let lang: String?
        let wordCount: Int
        let blocks: [Block]
    }
}
