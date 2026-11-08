import Foundation

enum WeiboRiskKind: String, Sendable, Equatable {
    case ok
    case authExpired
    case rateLimited
    case challenge
    case network
    case server
    case parseChanged
    case emptyList
    case unknown

    var isRateLimit: Bool {
        self == .rateLimited
    }

    var isAuthentication: Bool {
        self == .authExpired
    }

    var isTransient: Bool {
        switch self {
        case .network, .server, .unknown:
            return true
        case .ok, .authExpired, .rateLimited, .challenge, .parseChanged, .emptyList:
            return false
        }
    }
}

/// Classifies a response before it reaches the parser. Weibo's failure modes
/// are not limited to HTTP status codes: a 200 with `ok:-100` is a login
/// redirect, a 200 with an HTML body is a challenge page, and a 200 with an
/// empty list is a soft block. All three must be distinguishable.
enum WeiboRiskSignal {
    static let riskPhrases = [
        "访问过于频繁",
        "请求过于频繁",
        "操作过于频繁",
        "请稍后再试",
        "请稍后重试",
    ]

    static func classify(
        statusCode: Int?,
        data: Data?,
        contentType: String?,
        error: Error?
    ) -> WeiboRiskKind {
        if let error {
            if error is URLError { return .network }
            return .unknown
        }

        if let statusCode {
            switch statusCode {
            case 418, 429, 403, 432:
                return .rateLimited
            case 500...599:
                return .server
            default:
                break
            }
        }

        guard let data, !data.isEmpty else { return .unknown }

        // Parse JSON first. Scanning the whole body for "请稍后再试" before
        // parsing would classify a perfectly normal post that quotes the phrase
        // as a rate limit and pause the account for an hour.
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ok = integer(root["ok"])
            if ok == 1 { return .ok }

            let url = (root["url"] as? String) ?? ""
            let lower = url.lowercased()
            if ok == -100 || (ok == 0 && (lower.contains("login") || lower.contains("passport"))) {
                return .authExpired
            }

            let message = (root["message"] as? String) ?? (root["msg"] as? String) ?? ""
            if riskPhrases.contains(where: message.contains) {
                return .rateLimited
            }

            // ok:0 without a login URL or a known risk phrase is an ordinary
            // error envelope (bad uid, deleted user, parameter error). Treat it
            // as a per-account unknown, not a global challenge.
            return .unknown
        }

        if isHTML(data: data, contentType: contentType) {
            return .challenge
        }

        if let text = String(data: data, encoding: .utf8),
           riskPhrases.contains(where: text.contains) {
            return .rateLimited
        }

        return .parseChanged
    }

    static func isHTML(data: Data, contentType: String?) -> Bool {
        if let contentType, contentType.lowercased().contains("text/html") {
            return true
        }
        guard let prefix = String(data: data.prefix(256), encoding: .utf8) else { return false }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html")
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
