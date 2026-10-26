import SwiftUI

enum DashboardMotion {
    /// Structural changes: the list column collapsing, the reader entering.
    static let structural = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Content revealed after the hero lands.
    static let reveal = Animation.easeOut(duration: 0.18)
    /// Small hover / press feedback.
    static let micro = Animation.easeInOut(duration: 0.15)
    /// Reduce Motion: a short cross-fade, no travel.
    static let reduced = Animation.easeInOut(duration: 0.12)
}
