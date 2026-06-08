import Foundation

enum HTTPClient {
    struct Config {
        let timeout: TimeInterval
        let userAgent: String
        let extraHeaders: [String: String]

        static let weibo = Config(
            timeout: 10,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            extraHeaders: [
                "Referer": "https://weibo.com/",
                "X-Requested-With": "XMLHttpRequest",
                "Cache-Control": "no-cache"
            ]
        )

        static let bilibili = Config(
            timeout: 8,
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            extraHeaders: ["Referer": "https://www.bilibili.com"]
        )

        static let rss = Config(
            timeout: 8,
            userAgent: "NewsBar/1.0 (macOS; RSS Reader)",
            extraHeaders: [:]
        )

        static let ai = Config(
            timeout: 30,
            userAgent: "NewsBar/1.0",
            extraHeaders: [:]
        )
    }

    static func data(for url: URL, config: Config) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in config.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = config.timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NewsBarError.requestFailed
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NewsBarError.requestFailed
        }
        return (data, httpResponse)
    }
}
