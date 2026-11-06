import CoreGraphics

/// How the reader displays a third-party page that is wider than its panel.
enum ReaderZoomMode: String, CaseIterable, Sendable {
    /// Shrink wide pages just enough to fit; leave narrow pages at 100%.
    case fit
    /// Always show the site's actual size, even when it overflows.
    case actual
    /// Show the page larger for comfortable reading on a wide panel.
    case large

    /// `nil` means the scale depends on the current panel and document.
    var fixedScale: CGFloat? {
        switch self {
        case .fit: nil
        case .actual: 1
        case .large: 1.25
        }
    }
}

/// Pure page-zoom arithmetic for the reader.
///
/// macOS WKWebView has no mobile content mode, so a desktop page keeps its
/// designed width no matter how narrow the split panel gets. The only stable
/// remedy is scaling the whole page: the natural content width is measured
/// once per document at 100% and then reused while the panel is resized, which
/// avoids the shrink → reflow → grow feedback loop.
enum ReaderZoomPolicy {
    /// Text below 60% stops being readable; the reader surfaces a hint instead.
    static let minimumScale: CGFloat = 0.6
    static let maximumScale: CGFloat = 1.25
    /// Sub-pixel differences are rounding, not horizontal overflow.
    static let overflowTolerance: CGFloat = 1

    static func fitScale(panelWidth: CGFloat, contentWidth: CGFloat) -> CGFloat {
        guard panelWidth.isFinite, contentWidth.isFinite,
              panelWidth > 0, contentWidth > 0 else { return 1 }
        guard contentWidth > panelWidth + overflowTolerance else { return 1 }
        return clamp(panelWidth / contentWidth)
    }

    static func scale(for mode: ReaderZoomMode) -> CGFloat {
        mode.fixedScale ?? 1
    }

    /// The width that should decide page scale is the widest layout box, not
    /// the scrollable width: a single wide image or code block must not shrink
    /// the whole article. Returns nil when the layout already fits.
    static func naturalContentWidth(layoutWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat? {
        guard layoutWidth.isFinite, viewportWidth.isFinite,
              layoutWidth > 0, viewportWidth > 0,
              layoutWidth > viewportWidth + overflowTolerance else { return nil }
        return layoutWidth
    }

    /// One bounded correction after the first fit, for pages that reflow wider
    /// once they are scaled. Returns nil when no further reduction is safe.
    static func correctiveScale(
        current: CGFloat,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> CGFloat? {
        guard current > minimumScale + 0.0001,
              viewportWidth.isFinite, contentWidth.isFinite,
              viewportWidth > 0,
              contentWidth > viewportWidth + overflowTolerance else { return nil }
        let next = clamp(current * (viewportWidth / contentWidth))
        guard next < current - 0.005 else { return nil }
        return next
    }

    static func clamp(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(maximumScale, max(minimumScale, scale))
    }

    static func percent(_ scale: CGFloat) -> Int {
        guard scale.isFinite else { return 100 }
        return Int((scale * 100).rounded())
    }
}
