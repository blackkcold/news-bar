import AppKit
import CoreGraphics
import Observation

struct ReaderTransitionOrigin {
    let frame: CGRect
    let title: String
}

enum ReaderPresentationPhase: Equatable {
    case idle
    case presented
    case dismissing
}

/// Hands the tapped card's frame to the Dashboard so the reader can morph out of it.
/// Also captures the list once, before its width changes, so the expensive layout
/// happens behind a still image instead of inside the animation.
@MainActor
@Observable
final class ReaderTransitionCoordinator {
    static let shared = ReaderTransitionCoordinator()

    private var pending: ReaderTransitionOrigin?

    /// Registered by DashboardWindow. Must read `listFrame` in the window content
    /// view's coordinate space and return nil if capture is unavailable.
    @ObservationIgnored var snapshotProvider: ((CGRect) -> NSImage?)?
    /// Current visible list region in the Dashboard root coordinate space.
    @ObservationIgnored var listFrame: CGRect = .zero
    @ObservationIgnored private var capturedSnapshot: NSImage?
    @ObservationIgnored private var capturedSnapshotFrame: CGRect = .zero

    func register(frame: CGRect, title: String) {
        guard frame.width > 1, frame.height > 1 else { return }
        pending = ReaderTransitionOrigin(frame: frame, title: title)
    }

    func consume() -> ReaderTransitionOrigin? {
        defer { pending = nil }
        return pending
    }

    func clear() {
        pending = nil
    }

    /// Call from the tap action, before the selection change causes layout.
    func captureSnapshot() {
        capturedSnapshot = nil
        guard listFrame.width > 1, listFrame.height > 1,
              let image = snapshotProvider?(listFrame) else { return }
        capturedSnapshot = image
        capturedSnapshotFrame = listFrame
    }

    func takeSnapshot() -> (image: NSImage, frame: CGRect)? {
        guard let image = capturedSnapshot else { return nil }
        capturedSnapshot = nil
        return (image, capturedSnapshotFrame)
    }

    func discardSnapshot() {
        capturedSnapshot = nil
    }

    /// Reader chrome uses this instead of closing directly, so the list can be
    /// frozen before its width is restored.
    func requestClose() {
        captureSnapshot()
        NewsNavigationRouter.shared.close()
    }
}
