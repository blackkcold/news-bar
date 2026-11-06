import Foundation

enum BilibiliHotService {

    private static let endpoint = "https://api.bilibili.com/x/web-interface/popular"

    static func fetch() async throws -> [NewsItem] {
        guard let url = URL(string: "\(endpoint)?ps=5&pn=1") else {
            throw NewsBarError.invalidURL
        }

        let (data, _) = try await HTTPClient.data(for: url, config: .bilibili)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [NewsItem] {
        struct BilibiliResponse: Decodable {
            struct DataBlock: Decodable {
                struct Video: Decodable {
                    let title: String
                    let short_link_v2: String?
                    let short_link: String?
                    let bvid: String?
                    let pic: String?
                }
                let list: [Video]
            }
            let data: DataBlock
        }

        let decoded = try JSONDecoder().decode(BilibiliResponse.self, from: data)

        return decoded.data.list.enumerated().map { index, video in
            let link = video.short_link_v2 ?? video.short_link ?? "https://www.bilibili.com/video/\(video.bvid ?? "")"
            let validatedURL = SecurityPolicies.validateURL(link)?.absoluteString ?? link
            let directURL: String? = video.bvid.flatMap { bvid in
                guard bvid.range(of: "^BV[A-Za-z0-9]{10}$", options: .regularExpression) != nil else { return nil }
                return "https://www.bilibili.com/video/\(bvid)"
            }
            return NewsItem(
                title: SecurityPolicies.sanitizeUserInput(video.title),
                url: validatedURL,
                source: .bilibili,
                rank: index + 1,
                imageURL: validatedImageURL(video.pic),
                readerURL: directURL
            )
        }
    }

    /// The popular endpoint returns protocol-relative or http cover URLs.
    /// Upgrade the scheme, then apply the same HTTPS/public-host rules as every
    /// other remote image; an unusable cover simply leaves the card text-only.
    private static func validatedImageURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("//") {
            value = "https:" + value
        } else if value.hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        }
        return ReaderNavigationPolicy.allowedURL(value)?.absoluteString
    }
}
