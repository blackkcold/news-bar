import Foundation

/// A stable, non-identifying session id for OpenCode Go.
///
/// The Go API asks every client to send `x-opencode-session` so it can route
/// requests and reuse prompt caches consistently. This is not an account or
/// device identifier: it is a random value kept in UserDefaults, and the
/// `newsbar-` prefix makes traffic from this app recognizable in Go's logs.
enum OpenCodeSession {
    static let defaultsKey = "opencode.go.sessionID"

    static func identifier(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: defaultsKey), !saved.isEmpty {
            return "newsbar-" + saved
        }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: defaultsKey)
        return "newsbar-" + value
    }
}
