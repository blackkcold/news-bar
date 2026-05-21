import Foundation

enum BilibiliHotService {

    private static let endpoint = "https://api.bilibili.com/x/web-interface/popular"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    static func fetch() async throws -> [NewsItem] {
        guard let url = URL(string: "\(endpoint)?ps=3&pn=1") else {
            throw NewsBarError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NewsBarError.requestFailed
        }

        struct BilibiliResponse: Decodable {
            struct DataBlock: Decodable {
                struct Video: Decodable {
                    let title: String
                    let short_link_v2: String?
                    let short_link: String?
                    let bvid: String?
                }
                let list: [Video]
            }
            let data: DataBlock
        }

        let decoded = try JSONDecoder().decode(BilibiliResponse.self, from: data)

        return decoded.data.list.enumerated().map { index, video in
            let link = video.short_link_v2 ?? video.short_link ?? "https://www.bilibili.com/video/\(video.bvid ?? "")"
            return NewsItem(
                title: SecurityPolicies.sanitizeUserInput(video.title),
                url: link,
                source: .bilibili,
                rank: index + 1
            )
        }
    }
}
