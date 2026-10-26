import Foundation

enum ReaderFailure: Equatable {
    case unsupportedURL, privateDestination, networkUnavailable, downloadBlocked, processTerminated, safetyRulesUnavailable
    case proxyTrustRequired, proxyUnavailable

    var canRetry: Bool {
        switch self {
        case .networkUnavailable, .processTerminated, .safetyRulesUnavailable, .proxyUnavailable: return true
        default: return false
        }
    }

    var symbol: String {
        switch self {
        case .unsupportedURL, .privateDestination, .downloadBlocked: return "exclamationmark.shield"
        case .networkUnavailable, .proxyUnavailable: return "wifi.exclamationmark"
        default: return "exclamationmark.triangle"
        }
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .unsupportedURL, .privateDestination: return language == .en ? "This link cannot be opened here" : "此链接无法在阅读器打开"
        case .downloadBlocked: return language == .en ? "This link is a download" : "此链接指向下载文件"
        case .networkUnavailable: return language == .en ? "Cannot connect to this website" : "暂时无法连接到网站"
        case .processTerminated: return language == .en ? "The page stopped responding" : "网页已停止响应"
        case .safetyRulesUnavailable: return language == .en ? "Reader is not ready" : "阅读器暂时不可用"
        case .proxyTrustRequired: return language == .en ? "Authorize this network's proxy" : "请授权当前网络的代理"
        case .proxyUnavailable: return language == .en ? "Cannot connect through the proxy" : "暂时无法通过代理连接"
        }
    }

    func message(language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .unsupportedURL:
            return english ? "Only public HTTPS news links are supported. Local files, HTTP links and app-specific links are not opened." : "仅支持公网 HTTPS 新闻链接。不加载本地文件、HTTP 链接或其他应用的专用链接。"
        case .privateDestination:
            return english ? "This address resolves to a local or private network and was blocked. The reader's safety protections remain enabled." : "此地址指向本地或内网，已被拦截。阅读器的安全防护保持开启。"
        case .networkUnavailable:
            return english ? "Check your network connection and try again, or open the article in your browser." : "请检查网络后重试，也可以在浏览器中打开原文。"
        case .downloadBlocked:
            return english ? "Downloads are not handled in the reader. Use your browser if you intended to download this file." : "阅读器不下载文件。如果确实需要下载，请主动在浏览器中打开。"
        case .processTerminated:
            return english ? "Reload to continue, or open the article in your browser." : "请重新加载以继续阅读，也可以在浏览器中打开原文。"
        case .safetyRulesUnavailable:
            return english ? "Safety rules could not be prepared. Try again to restart the reader, or open the article in your browser." : "安全规则暂未准备就绪。请重试以重新启动阅读器，或在浏览器中打开原文。"
        case .proxyTrustRequired:
            return ReaderProxyError.trustRequired.message(language: language)
        case .proxyUnavailable:
            return ReaderProxyError.unavailable.message(language: language)
        }
    }
}
