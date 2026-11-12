import Foundation

enum WeiboFeedTier: String, Sendable, Equatable {
    case desktop
    case mobile
}

enum WeiboFetchOutcome: Sendable, Equatable {
    case success(page: WeiboParsedPage, tier: WeiboFeedTier, latency: TimeInterval)
    case failure(kind: WeiboRiskKind, message: String, retryAfter: TimeInterval?)
}

protocol WeiboFeedFetching: Sendable {
    func fetchPage(
        uid: String,
        screenName: String,
        page: Int,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboFetchOutcome

    func fetchLongText(mid: String, credentials: WeiboCredentials) async -> String?
}

/// Network boundary for the monitor. It uses its own ephemeral session on
/// purpose: `URLSession.shared` would silently attach the app's cookie store,
/// and the reader's cookie vault is the only session that may be replayed.
actor WeiboUserFeedService: WeiboFeedFetching, WeiboCommentFetching {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpMaximumConnectionsPerHost = 1
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetchPage(
        uid: String,
        screenName: String,
        page: Int,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboFetchOutcome {
        if credentials.hasDesktopLogin {
            let result = await requestDesktopPage(
                uid: uid,
                screenName: screenName,
                page: page,
                cookies: credentials.desktopCookieHeader,
                now: now
            )
            switch result {
            case .success:
                return result
            case .failure(let kind, _, _):
                // The desktop endpoint is the only automatic path. Fall back to
                // the mobile endpoint only for an auth failure; a rate limit or
                // challenge must never be retried immediately with a second
                // request, and the mobile request would not have its own budget.
                if credentials.hasMobileLogin, kind == .authExpired {
                    return await requestMobilePage(
                        uid: uid,
                        screenName: screenName,
                        page: page,
                        cookies: credentials.mobileCookieHeader,
                        now: now
                    )
                }
                return result
            }
        }

        if credentials.hasMobileLogin {
            return await requestMobilePage(
                uid: uid,
                screenName: screenName,
                page: page,
                cookies: credentials.mobileCookieHeader,
                now: now
            )
        }

        return .failure(
            kind: .authExpired,
            message: "Weibo desktop session is missing",
            retryAfter: nil
        )
    }

    func fetchLongText(mid: String, credentials: WeiboCredentials) async -> String? {
        guard credentials.hasDesktopLogin, let cookies = credentials.desktopCookieHeader else {
            return nil
        }
        guard var components = URLComponents(string: "https://weibo.com/ajax/statuses/longtext") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "id", value: mid)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        applyDesktopHeaders(&request, uid: "", cookies: cookies)

        guard let (data, _) = try? await session.data(for: request) else { return nil }
        return WeiboFeedParser.parseLongText(data)
    }

    // MARK: - Desktop

    private func requestDesktopPage(
        uid: String,
        screenName: String,
        page: Int,
        cookies: String?,
        now: Date
    ) async -> WeiboFetchOutcome {
        guard let cookies, !cookies.isEmpty else {
            return .failure(kind: .authExpired, message: "missing SUB cookie", retryAfter: nil)
        }
        guard var components = URLComponents(string: "https://weibo.com/ajax/statuses/mymblog") else {
            return .failure(kind: .unknown, message: "invalid URL", retryAfter: nil)
        }
        components.queryItems = [
            URLQueryItem(name: "uid", value: uid),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "feature", value: "0"),
        ]
        guard let url = components.url else {
            return .failure(kind: .unknown, message: "invalid URL", retryAfter: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        applyDesktopHeaders(&request, uid: uid, cookies: cookies)

        return await perform(request: request, now: now, tier: .desktop) { data in
            try WeiboFeedParser.parseT0(
                data,
                uid: uid,
                fallbackScreenName: screenName,
                fetchedAt: now
            )
        }
    }

    private func applyDesktopHeaders(_ request: inout URLRequest, uid: String, cookies: String) {
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(uid.isEmpty ? "https://weibo.com/" : "https://weibo.com/u/\(uid)", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://weibo.com", forHTTPHeaderField: "Origin")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        // Some Weibo AJAX endpoints expect the XSRF token mirrored from the
        // cookie. Sending it is normal browser behaviour, not a crawler trick.
        if let token = Self.cookieValue(named: "XSRF-TOKEN", in: cookies) {
            request.setValue(token.removingPercentEncoding ?? token, forHTTPHeaderField: "x-xsrf-token")
        }
    }

    // MARK: - Mobile

    private func requestMobilePage(
        uid: String,
        screenName: String,
        page: Int,
        cookies: String?,
        now: Date
    ) async -> WeiboFetchOutcome {
        guard let cookies, !cookies.isEmpty else {
            return .failure(kind: .authExpired, message: "missing mobile session", retryAfter: nil)
        }
        guard var components = URLComponents(string: "https://m.weibo.cn/api/container/getIndex") else {
            return .failure(kind: .unknown, message: "invalid URL", retryAfter: nil)
        }
        var query = [
            URLQueryItem(name: "type", value: "uid"),
            URLQueryItem(name: "value", value: uid),
            URLQueryItem(name: "containerid", value: "107603\(uid)"),
        ]
        if page > 1 {
            query.append(URLQueryItem(name: "page", value: String(page)))
        }
        components.queryItems = query
        guard let url = components.url else {
            return .failure(kind: .unknown, message: "invalid URL", retryAfter: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://m.weibo.cn/u/\(uid)", forHTTPHeaderField: "Referer")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")

        return await perform(request: request, now: now, tier: .mobile) { data in
            try WeiboFeedParser.parseT1(
                data,
                uid: uid,
                fallbackScreenName: screenName,
                fetchedAt: now,
                now: now
            )
        }
    }

    // MARK: - Shared

    private func perform(
        request: URLRequest,
        now: Date,
        tier: WeiboFeedTier,
        parse: (Data) throws -> WeiboParsedPage
    ) async -> WeiboFetchOutcome {
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let kind = WeiboRiskSignal.classify(
                statusCode: http?.statusCode,
                data: data,
                contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                error: nil
            )
            let latency = Date().timeIntervalSince(started)
            let retryAfter = Self.retryAfter(from: http)

            switch kind {
            case .ok:
                do {
                    let page = try parse(data)
                    return .success(page: page, tier: tier, latency: latency)
                } catch {
                    return .failure(
                        kind: .parseChanged,
                        message: "response shape changed",
                        retryAfter: nil
                    )
                }
            case .authExpired:
                return .failure(kind: .authExpired, message: "login required", retryAfter: retryAfter)
            case .rateLimited:
                return .failure(kind: .rateLimited, message: "rate limited", retryAfter: retryAfter)
            case .challenge:
                return .failure(kind: .challenge, message: "challenge page", retryAfter: retryAfter)
            case .network:
                return .failure(kind: .network, message: "network unavailable", retryAfter: nil)
            case .server:
                return .failure(kind: .server, message: "server error", retryAfter: retryAfter)
            case .parseChanged:
                return .failure(kind: .parseChanged, message: "unexpected body", retryAfter: nil)
            case .emptyList, .unknown:
                return .failure(kind: kind, message: "empty or unknown response", retryAfter: nil)
            }
        } catch {
            return .failure(
                kind: WeiboRiskSignal.classify(
                    statusCode: nil,
                    data: nil,
                    contentType: nil,
                    error: error
                ),
                message: error.localizedDescription,
                retryAfter: nil
            )
        }
    }

    private static func retryAfter(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return max(0, seconds)
    }

    private static func cookieValue(named name: String, in header: String) -> String? {
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator])
            if key == name {
                return String(trimmed[trimmed.index(after: separator)...])
            }
        }
        return nil
    }

    // MARK: - Comments

    /// Comments use the same first-party session and the same free web
    /// endpoints as the feed. No paid API, no second cookie store, and no
    /// retry across endpoints after a rate-limit or challenge signal.
    func fetchComments(
        mid: String,
        uid: String,
        authorUID: String?,
        cursor: String?,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboCommentOutcome {
        if credentials.hasDesktopLogin {
            let outcome = await requestDesktopComments(
                mid: mid,
                uid: uid,
                authorUID: authorUID,
                cursor: cursor,
                cookies: credentials.desktopCookieHeader,
                now: now
            )
            if case .failure(let failure) = outcome, credentials.hasMobileLogin {
                switch failure {
                case .authRequired, .parseChanged, .unknown:
                    // The free mobile path is the fallback for a desktop
                    // session or shape failure. Never retry a rate limit or a
                    // challenge on a second endpoint.
                    return await requestMobileComments(
                        mid: mid,
                        authorUID: authorUID,
                        cursor: cursor,
                        cookies: credentials.mobileCookieHeader,
                        now: now
                    )
                case .rateLimited, .challenge, .network, .server:
                    break
                }
            }
            return outcome
        }

        if credentials.hasMobileLogin {
            return await requestMobileComments(
                mid: mid,
                authorUID: authorUID,
                cursor: cursor,
                cookies: credentials.mobileCookieHeader,
                now: now
            )
        }

        return .failure(.authRequired)
    }

    private func requestDesktopComments(
        mid: String,
        uid: String,
        authorUID: String?,
        cursor: String?,
        cookies: String?,
        now: Date
    ) async -> WeiboCommentOutcome {
        guard let cookies, !cookies.isEmpty else { return .failure(.authRequired) }
        guard var components = URLComponents(string: "https://weibo.com/ajax/statuses/buildComments") else {
            return .failure(.unknown)
        }
        var query = [
            URLQueryItem(name: "id", value: mid),
            URLQueryItem(name: "uid", value: uid),
            URLQueryItem(name: "is_reload", value: "1"),
            URLQueryItem(name: "is_show_bulletin", value: "2"),
            URLQueryItem(name: "is_mix", value: "0"),
            URLQueryItem(name: "count", value: "20"),
        ]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "max_id", value: cursor))
        }
        components.queryItems = query
        guard let url = components.url else { return .failure(.unknown) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        applyDesktopHeaders(&request, uid: uid, cookies: cookies)

        return await performCommentRequest(
            request: request,
            mid: mid,
            authorUID: authorUID,
            tier: .desktop,
            now: now
        )
    }

    private func requestMobileComments(
        mid: String,
        authorUID: String?,
        cursor: String?,
        cookies: String?,
        now: Date
    ) async -> WeiboCommentOutcome {
        guard let cookies, !cookies.isEmpty else { return .failure(.authRequired) }
        guard var components = URLComponents(string: "https://m.weibo.cn/comments/hotflow") else {
            return .failure(.unknown)
        }
        var query = [
            URLQueryItem(name: "id", value: mid),
            URLQueryItem(name: "mid", value: mid),
            URLQueryItem(name: "max_id_type", value: "0"),
        ]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "max_id", value: cursor))
        }
        components.queryItems = query
        guard let url = components.url else { return .failure(.unknown) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://m.weibo.cn/detail/\(mid)", forHTTPHeaderField: "Referer")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")

        return await performCommentRequest(
            request: request,
            mid: mid,
            authorUID: authorUID,
            tier: .mobile,
            now: now
        )
    }

    private func performCommentRequest(
        request: URLRequest,
        mid: String,
        authorUID: String?,
        tier: WeiboCommentTier,
        now: Date
    ) async -> WeiboCommentOutcome {
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let kind = WeiboRiskSignal.classify(
                statusCode: http?.statusCode,
                data: data,
                contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                error: nil
            )
            let latency = Date().timeIntervalSince(started)
            let retryAfter = Self.retryAfter(from: http)

            switch kind {
            case .ok, .parseChanged, .unknown, .emptyList:
                // The free mobile path can return a top-level comment array,
                // which the shared risk classifier cannot recognize. A payload
                // that parses as comments is valid even when the envelope is
                // not the desktop JSON object shape.
                do {
                    let page = try WeiboCommentParser.parse(
                        data,
                        mid: mid,
                        authorUID: authorUID,
                        tier: tier,
                        fetchedAt: now
                    )
                    return .success(page: page, latency: latency)
                } catch {
                    switch kind {
                    case .ok, .parseChanged, .emptyList: return .failure(.parseChanged)
                    default: return .failure(.unknown)
                    }
                }
            case .authExpired:
                return .failure(.authRequired)
            case .rateLimited:
                return .failure(.rateLimited(retryAfter: retryAfter))
            case .challenge:
                return .failure(.challenge)
            case .network:
                return .failure(.network)
            case .server:
                return .failure(.server)
            }
        } catch {
            let kind = WeiboRiskSignal.classify(
                statusCode: nil,
                data: nil,
                contentType: nil,
                error: error
            )
            switch kind {
            case .network: return .failure(.network)
            case .authExpired: return .failure(.authRequired)
            case .rateLimited: return .failure(.rateLimited(retryAfter: nil))
            case .challenge: return .failure(.challenge)
            case .server: return .failure(.server)
            default: return .failure(.unknown)
            }
        }
    }

    // A current desktop Safari UA is less suspicious than a fake rotation and
    // keeps the request shape stable across launches.
    private static let desktopUserAgent = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 \
    (KHTML, like Gecko) Version/17.6 Safari/605.1.15
    """

    private static let mobileUserAgent = """
    Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 \
    (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1
    """
}
