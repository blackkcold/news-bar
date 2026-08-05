import Foundation
import AppKit
import ImageIO

actor ImageCache {
    static let shared = ImageCache()

    static let maxPayloadBytes: Int = 10 * 1024 * 1024
    static let maxCacheBytes: Int = 100 * 1024 * 1024
    static let maxCacheCount: Int = 50
    static let thumbnailMaxPixelSize: Int = 480

    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession
    private var inFlight: [NSURL: Task<NSImage?, Never>] = [:]

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
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached
        }

        if let pending = inFlight[key] {
            return await pending.value
        }

        let session = session
        let request = Task<NSImage?, Never> {
            do {
                let (data, response) = try await session.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse else { return nil }
                guard Self.isAcceptableResponse(httpResponse: httpResponse, data: data) else { return nil }
                return await Self.decodeThumbnailAsync(from: data)
            } catch {
                return nil
            }
        }
        inFlight[key] = request

        let image = await request.value
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: key, cost: imageCost(image))
            return image
        }
        return nil
    }

    /// Pure validation seam — no I/O, safe for unit testing.
    static func isAcceptableResponse(httpResponse: HTTPURLResponse, data: Data) -> Bool {
        guard data.count <= maxPayloadBytes else { return false }
        guard data.count > 0 else { return false }
        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.hasPrefix("image/") else { return false }
        return true
    }

    /// Decode a bounded thumbnail eagerly so the first SwiftUI render does not decode a full-size image.
    static func decodeThumbnail(from data: Data, maxPixelSize: Int = thumbnailMaxPixelSize) -> NSImage? {
        guard maxPixelSize > 0 else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    /// Decode on a background thread so the actor executor stays free.
    static func decodeThumbnailAsync(from data: Data, maxPixelSize: Int = thumbnailMaxPixelSize) async -> NSImage? {
        let decoded = Task.detached(priority: .userInitiated) {
            decodeThumbnail(from: data, maxPixelSize: maxPixelSize)
        }
        return await decoded.value
    }

    private func imageCost(_ image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 0 }
        return representation.pixelsWide * representation.pixelsHigh * 4
    }
}
