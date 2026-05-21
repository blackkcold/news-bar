import AppKit

enum URLOpener {

    static func open(_ urlString: String) {
        guard let url = SecurityPolicies.validateURL(urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
