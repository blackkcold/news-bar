import Foundation
import AppKit

actor ImageCache {
    static let shared = ImageCache()

    static let maxPayloadBytes: Int = 10 * 1024 * 1024
    static let maxCacheBytes: Int = 100 * 1024 * 1024
    static let maxCacheCount: Int = 50

    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
        cache.countLimit = Self.maxCacheCount
        cache.totalCostLimit = Self.maxCacheBytes
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard Self.isAcceptableResponse(httpResponse: httpResponse, data: data) else { return nil }
            guard let image = NSImage(data: data) else { return nil }
            cache.setObject(image, forKey: url as NSURL, cost: data.count)
            return image
        } catch {
            return nil
        }
    }

    /// Pure validation seam — no I/O, safe for unit testing.
    static func isAcceptableResponse(httpResponse: HTTPURLResponse, data: Data) -> Bool {
        guard data.count <= maxPayloadBytes else { return false }
        guard data.count > 0 else { return false }
        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.hasPrefix("image/") else { return false }
        return true
    }
}