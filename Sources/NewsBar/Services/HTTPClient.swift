import Foundation

enum HTTPClient {
    struct Config {
        let timeout: TimeInterval
        let userAgent: String
        let extraHeaders: [String: String]
        /// Maximum allowed response body size in bytes.
        ///
        /// Responses whose declared `Content-Length` or actually received payload
        /// exceeds this ceiling are rejected with `NewsBarError.requestFailed`.
        let maxBodySize: Int

        static let weibo = Config(
            timeout: 10,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            extraHeaders: [
                "Referer": "https://weibo.com/",
                "X-Requested-With": "XMLHttpRequest",
                "Cache-Control": "no-cache"
            ],
            maxBodySize: 4 * 1024 * 1024
        )

        static let bilibili = Config(
            timeout: 8,
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            extraHeaders: ["Referer": "https://www.bilibili.com"],
            maxBodySize: 4 * 1024 * 1024
        )

        static let rss = Config(
            timeout: 8,
            userAgent: "NewsBar/1.0 (macOS; RSS Reader)",
            extraHeaders: [:],
            maxBodySize: 8 * 1024 * 1024
        )

        static let ai = Config(
            timeout: 30,
            userAgent: "NewsBar/1.0",
            extraHeaders: [:],
            maxBodySize: 2 * 1024 * 1024
        )
    }

    /// Pure, side-effect free validation of a response body size against a ceiling.
    ///
    /// - Parameters:
    ///   - declaredContentLength: Value of the `Content-Length` header, if present.
    ///     `nil` means the header was absent (the received-byte count is authoritative).
    ///   - receivedByteCount: Number of bytes actually received in the payload.
    ///   - maxBodySize: Configured ceiling in bytes. Non-positive values are invalid.
    /// - Returns: `true` if the response is acceptable, `false` if it must be rejected.
    static func validateResponseSize(
        declaredContentLength: Int?,
        receivedByteCount: Int,
        maxBodySize: Int
    ) -> Bool {
        guard maxBodySize > 0 else { return false }

        if let declared = declaredContentLength, declared > maxBodySize {
            return false
        }

        if receivedByteCount > maxBodySize {
            return false
        }

        return true
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

        let declaredLength: Int? = {
            guard let raw = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                  let parsed = Int(raw) else { return nil }
            return parsed
        }()
        guard validateResponseSize(
            declaredContentLength: declaredLength,
            receivedByteCount: data.count,
            maxBodySize: config.maxBodySize
        ) else {
            throw NewsBarError.requestFailed
        }

        return (data, httpResponse)
    }
}
