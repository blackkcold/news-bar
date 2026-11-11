import Foundation
import AppKit
import ImageIO

actor ImageCache {
    static let shared = ImageCache()

    static let maxPayloadBytes: Int = 10 * 1024 * 1024
    static let maxCacheBytes: Int = 100 * 1024 * 1024
    static let maxCacheCount: Int = 120
    static let thumbnailMaxPixelSize: Int = 480
    static let failureTTL: TimeInterval = 5 * 60

    private let cache = NSCache<NSString, NSImage>()
    private let session: URLSession
    private var inFlight: [NSString: Task<NSImage?, Never>] = [:]
    private var failedUntil: [NSString: Date] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        // Keep decoded thumbnails in memory and raw responses on disk. The
        // memory-only cache made every scroll back to a card re-download.
        let cacheDirectory = TestIsolation.isActive
            ? TestIsolation.directory("ImageCache")
            : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.newsbar.app/ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        config.urlCache = URLCache(
            memoryCapacity: 24 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            directory: cacheDirectory
        )
        config.requestCachePolicy = .useProtocolCachePolicy
        self.session = URLSession(configuration: config)
        cache.countLimit = Self.maxCacheCount
        cache.totalCostLimit = Self.maxCacheBytes
    }

    /// `maxPixelSize` is part of the cache identity: a narrow list card and a
    /// wide reader banner must not hand each other a blurry or oversized
    /// decode. Callers that do not care keep the historical 480 px default.
    func image(for url: URL, maxPixelSize: Int = thumbnailMaxPixelSize) async -> NSImage? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let pixelSize = min(2_048, max(64, maxPixelSize))
        let key = Self.cacheKey(for: url, maxPixelSize: pixelSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        if let until = failedUntil[key] {
            if until > Date() { return nil }
            failedUntil[key] = nil
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
                return await Self.decodeThumbnailAsync(from: data, maxPixelSize: pixelSize)
            } catch {
                return nil
            }
        }
        inFlight[key] = request

        let image = await request.value
        inFlight[key] = nil
        if let image {
            failedUntil[key] = nil
            cache.setObject(image, forKey: key, cost: imageCost(image))
            return image
        }
        let now = Date()
        if failedUntil.count > 512 {
            failedUntil = failedUntil.filter { $0.value > now }
        }
        failedUntil[key] = now.addingTimeInterval(Self.failureTTL)
        return nil
    }

    /// Pure validation seam — no I/O, safe for unit testing.
    static func isAcceptableResponse(httpResponse: HTTPURLResponse, data: Data) -> Bool {
        guard (200..<300).contains(httpResponse.statusCode) else { return false }
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

    private static func cacheKey(for url: URL, maxPixelSize: Int) -> NSString {
        "\(url.absoluteString)|px-\(maxPixelSize)" as NSString
    }

    /// Coarse pixel bucket for a point size at a given display scale.
    ///
    /// A live resize produces a continuous stream of widths; an exact pixel
    /// request would create one cache entry per width. Rounding up to the next
    /// step keeps the requested detail at normal sizes while bounding the number
    /// of cache identities. The 2 048 cap bounds decoded memory.
    static func pixelSize(
        forPoints points: CGFloat,
        displayScale: CGFloat,
        step: Int = 256
    ) -> Int {
        let safeStep = max(64, step)
        let scale = (displayScale.isFinite && displayScale > 0)
            ? min(displayScale, 8)
            : 2
        guard points.isFinite, points > 0 else { return safeStep }
        let requested = min(points, 4_096) * scale
        let bucketed = Int((requested / CGFloat(safeStep)).rounded(.up)) * safeStep
        return min(2_048, max(safeStep, bucketed))
    }

    private func imageCost(_ image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 0 }
        return representation.pixelsWide * representation.pixelsHigh * 4
    }
}
