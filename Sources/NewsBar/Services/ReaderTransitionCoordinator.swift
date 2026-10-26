import AppKit
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
///
/// The list used to be rasterized here to hide its width change. The capture
/// forced a full redraw of the list subtree on the tap's main thread (the most
/// expensive frame in the app) and the layout still ran behind the bitmap. The
/// Dashboard now commits the width change in one frame and lets the hero
/// animation carry the eye, so no snapshot is needed.
@MainActor
@Observable
final class ReaderTransitionCoordinator {
    static let shared = ReaderTransitionCoordinator()

    private var pending: ReaderTransitionOrigin?

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

    func requestClose() {
        NewsNavigationRouter.shared.close()
    }
}
