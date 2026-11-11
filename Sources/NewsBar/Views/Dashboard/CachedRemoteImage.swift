import AppKit
import SwiftUI

/// A remote image that loads through the shared `ImageCache`.
///
/// `AsyncImage` bypasses the app cache entirely: no memory/disk reuse, no
/// one-request-per-URL coalescing, no failure TTL, and no HTTPS/MIME/size
/// validation. The following feed used it for covers and avatars, so scrolling
/// back to a card downloaded the image again while the other feeds reused it.
///
/// The placeholder is supplied by the caller and must reserve the same space;
/// a loaded image never changes the card's height.
struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL
    /// Decoded thumbnail size in pixels; see `ImageCache.pixelSize(forPoints:displayScale:)`.
    let maxPixelSize: Int
    @ViewBuilder var placeholder: () -> Placeholder

    /// The last decoded image and the URL it belongs to. Pixel size is not part
    /// of the visibility condition: when a window resize moves a card into a
    /// new size bucket, the previous cover stays on screen until the sharper
    /// decode arrives instead of flashing the placeholder and re-downloading in
    /// front of the reader. A different URL still clears immediately.
    @State private var image: NSImage?
    @State private var imageURL: URL?
    @State private var settledKey: String?

    private var requestKey: String {
        "\(url.absoluteString)|\(maxPixelSize)"
    }

    var body: some View {
        Group {
            if let image, imageURL == url {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    // The card owns the frame; this only keeps the decoded
                    // image from painting outside it before the caller clips.
                    .clipped()
            } else {
                placeholder()
            }
        }
        .task(id: requestKey) {
            await load(key: requestKey)
        }
    }

    @MainActor
    private func load(key: String) async {
        // Same request already settled for this appearance: do not re-enter the
        // cache. A recycled card starts from the placeholder again, and the
        // cache answers that first request.
        if settledKey == key { return }
        let loaded = await ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
            imageURL = url
        }
        settledKey = key
    }
}
