import AppKit

enum URLOpener {

    @MainActor
    static func open(_ urlString: String) {
        NewsNavigationRouter.shared.open(url: urlString, surface: "newsLink")
    }
}
