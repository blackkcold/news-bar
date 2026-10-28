import Foundation

enum ReaderFailure: Equatable {
    case unsupportedURL, privateDestination, networkUnavailable, dnsUnavailable, connectionTimedOut, downloadBlocked, processTerminated, safetyRulesUnavailable
    case proxyTrustRequired, proxyUnavailable
    case siteBlocked

    var canRetry: Bool {
        switch self {
        case .networkUnavailable, .dnsUnavailable, .connectionTimedOut, .processTerminated, .safetyRulesUnavailable, .proxyUnavailable: return true
        default: return false
        }
    }

    var symbol: String {
        switch self {
        case .unsupportedURL, .privateDestination, .downloadBlocked: return "exclamationmark.shield"
        case .siteBlocked: return "hand.raised"
        case .networkUnavailable, .dnsUnavailable, .connectionTimedOut, .proxyUnavailable: return "wifi.exclamationmark"
        default: return "exclamationmark.triangle"
        }
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .unsupportedURL, .privateDestination: return language == .en ? "This link cannot be opened here" : "此链接无法在阅读器打开"
        case .downloadBlocked: return language == .en ? "This link is a download" : "此链接指向下载文件"
        case .networkUnavailable: return language == .en ? "Cannot connect to this website" : "暂时无法连接到网站"
        case .dnsUnavailable: return language == .en ? "Cannot resolve this website" : "无法解析网站地址"
        case .connectionTimedOut: return language == .en ? "The connection timed out" : "网站连接超时"
        case .processTerminated: return language == .en ? "The page stopped responding" : "网页已停止响应"
        case .safetyRulesUnavailable: return language == .en ? "Reader is not ready" : "阅读器暂时不可用"
        case .proxyTrustRequired: return language == .en ? "Authorize this network's proxy" : "请授权当前网络的代理"
        case .proxyUnavailable: return language == .en ? "Cannot connect through the proxy" : "暂时无法通过代理连接"
        case .siteBlocked: return language == .en ? "This site blocked the reader" : "该站点拒绝了内嵌访问"
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
        case .dnsUnavailable:
            return english ? "The website's address could not be resolved. Check DNS and try again, or open it in your browser." : "未能解析网站地址。请检查 DNS 后重试，也可以在浏览器中打开原文。"
        case .connectionTimedOut:
            return english ? "The website did not respond in time. Check your network and try again, or open it in your browser." : "网站未在规定时间内响应。请检查网络后重试，也可以在浏览器中打开原文。"
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
        case .siteBlocked:
            return english ? "The site's security policy rejected this in-app session, so retrying will not help. Open the article in your browser." : "该站点按安全风控策略拒绝了内嵌会话，重试通常无效。请在浏览器中打开原文。"
        }
    }

    static func networkError(_ error: Error) -> ReaderFailure {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return .networkUnavailable }
        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dnsUnavailable
        case NSURLErrorTimedOut: return .connectionTimedOut
        default: return .networkUnavailable
        }
    }
}
