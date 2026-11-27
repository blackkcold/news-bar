import CoreGraphics

/// The popup sizes itself to its content: a short report gets a short window, a
/// long one grows until it reaches most of the screen and then scrolls.
///
/// Kept free of AppKit so the clamp rules can be asserted without a window.
/// All values are frame heights: `setFrame` and `contentMinSize` are expressed
/// in frame coordinates, which include the title bar.
enum ResearchPanelSizing {
    /// Below this the panel stops reading as a page and starts reading as a
    /// dialog that failed to fill.
    static let minimumFrameHeight: CGFloat = 480

    /// A panel that fills the whole screen stops reading as a panel, and its
    /// title bar would sit against the menu bar. 0.85 leaves both.
    static let maximumFrameFraction: CGFloat = 0.85

    /// The panel is titled. SwiftUI's content height excludes this, the frame
    /// includes it; getting this wrong clips the last 28pt of content.
    static let titlebarHeight: CGFloat = 28

    /// Slack so an exact fit cannot produce a scrollbar from sub-pixel rounding.
    static let breathingRoom: CGFloat = 2

    /// The frame height for a measured content height.
    ///
    /// `screenVisibleHeight` is the visible frame of the screen the window is
    /// on, not the main screen: a panel dragged to a smaller display must not
    /// size itself against the larger one.
    static func frameHeight(
        contentHeight: CGFloat,
        screenVisibleHeight: CGFloat
    ) -> CGFloat {
        let wanted = contentHeight + titlebarHeight + breathingRoom
        let ceiling = max(minimumFrameHeight, screenVisibleHeight * maximumFrameFraction)
        return min(max(wanted, minimumFrameHeight), ceiling)
    }

    /// Origin for a frame whose height changed while its top edge must stay put.
    /// Anchoring the top is what keeps the title and the first line of body copy
    /// still when the detail expands or a shorter report loads.
    static func originKeepingTop(
        currentFrame: CGRect,
        newHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: currentFrame.origin.x, y: currentFrame.maxY - newHeight)
    }
}
