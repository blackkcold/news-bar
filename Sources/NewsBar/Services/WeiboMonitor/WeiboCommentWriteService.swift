import Foundation

/// Result of one user-initiated write. Writes are never retried automatically:
/// a rate limit or a challenge must reach the person who asked for the action.
enum WeiboCommentWriteOutcome: Sendable, Equatable {
    /// The server confirmed the new state of the comment.
    case liked(Bool)
    /// The comment was created and the server returned it.
    case replied(WeiboComment)
    case failure(WeiboCommentWriteFailure)
}

enum WeiboCommentWriteFailure: Equatable, Sendable {
    case authRequired
    case rateLimited(retryAfter: TimeInterval?)
    case challenge
    case network
    case server
    case unknown
    /// Nothing was sent: the local sliding window is full or two writes are
    /// closer than the serialization interval.
    case localLimit(retryAfter: TimeInterval)
    case invalidInput

    /// A short, user-facing reason. Kept here so the reader does not have to
    /// duplicate the mapping in three views.
    func message(language: AppLanguage) -> String {
        let zh: String
        switch self {
        case .authRequired:
            zh = "登录已失效，请在设置里重新登录微博。"
        case .rateLimited:
            zh = "微博提示操作过于频繁，稍后再试。"
        case .challenge:
            zh = "微博要求验证身份，请打开原网页完成验证。"
        case .network:
            zh = "网络不通，检查连接后再试。"
        case .server:
            zh = "微博服务暂时不可用，稍后再试。"
        case .unknown:
            zh = "操作没有成功，稍后再试。"
        case .localLimit(let retryAfter):
            zh = "操作太快了，\(Int(ceil(max(1, retryAfter)))) 秒后再试。"
        case .invalidInput:
            zh = "内容不能为空。"
        }
        if language == .en {
            switch self {
            case .authRequired:
                return "Your Weibo session expired. Sign in again in Settings."
            case .rateLimited:
                return "Weibo says this is too frequent. Try again later."
            case .challenge:
                return "Weibo is asking for verification. Open the original page to finish it."
            case .network:
                return "No network connection. Check it and try again."
            case .server:
                return "Weibo is temporarily unavailable. Try again later."
            case .unknown:
                return "The action did not go through. Try again later."
            case .localLimit(let retryAfter):
                return "Too fast. Try again in \(Int(ceil(max(1, retryAfter))))s."
            case .invalidInput:
                return "Write something first."
            }
        }
        return zh
    }
}

/// Performs the two writes the reader supports and owns their local budget.
///
/// Everything here mirrors a real desktop session: the same ephemeral URL
/// session as the feed fetcher, the same cookie header, the same XSRF header
/// and form bodies captured from `weibo.com` on 2026-11-24. The service never
/// guesses an endpoint and never falls back to a second one after a failure.
actor WeiboCommentWriteService {
    /// Local ceiling, deliberately below Weibo's own undocumented limit.
    static let likeBudgetPerHour = 12
    static let replyBudgetPerHour = 6
    /// Two writes never leave back to back; the reader feels the pause.
    static let minimumInterval: TimeInterval = 2.5

    private enum Kind {
        case like
        case reply
    }

    private let session: URLSession
    private var likeSendTimes: [Date] = []
    private var replySendTimes: [Date] = []
    private var lastSendAt: Date?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Like

    /// Sets the comment to `liked`. `updateLike` is not a toggle: the captured
    /// traffic showed two `updateLike` calls leaving the comment liked, so the
    /// opposite action needs `destroyLike`.
    func setLike(
        commentID: String,
        liked: Bool,
        credentials: WeiboCredentials,
        now: Date = Date()
    ) async -> WeiboCommentWriteOutcome {
        guard !commentID.isEmpty else { return .failure(.invalidInput) }
        guard credentials.writeCapability == .ready else { return .failure(.authRequired) }
        if let blocked = gate(.like, now: now) { return .failure(blocked) }

        record(.like, at: now)
        let path = liked ? "updateLike" : "destroyLike"
        let response = await post(
            url: "https://weibo.com/ajax/statuses/\(path)",
            form: [("object_id", commentID), ("object_type", "comment")],
            credentials: credentials
        )

        switch response.kind {
        case .ok:
            // `{"ok":1,"result":true}`; a false result is a silent rejection.
            guard let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  Self.bool(root["result"]) == true else {
                return .failure(.unknown)
            }
            return .liked(liked)
        case .authExpired:
            return .failure(.authRequired)
        case .rateLimited:
            return .failure(.rateLimited(retryAfter: response.retryAfter))
        case .challenge:
            return .failure(.challenge)
        case .network:
            return .failure(.network)
        case .server:
            return .failure(.server)
        case .parseChanged, .emptyList, .unknown:
            return .failure(.unknown)
        }
    }

    // MARK: - Reply

    /// Posts a top-level comment on `postMID`. The captured form has no reply
    /// target; replying to a specific comment is not implemented until that
    /// request is captured too.
    func reply(
        postMID: String,
        text: String,
        credentials: WeiboCredentials,
        now: Date = Date()
    ) async -> WeiboCommentWriteOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !postMID.isEmpty, !trimmed.isEmpty else { return .failure(.invalidInput) }
        guard credentials.writeCapability == .ready else { return .failure(.authRequired) }
        if let blocked = gate(.reply, now: now) { return .failure(blocked) }

        record(.reply, at: now)
        let response = await post(
            url: "https://weibo.com/ajax/comments/create",
            form: [
                ("id", postMID),
                ("comment", trimmed),
                ("pic_id", ""),
                ("is_repost", "0"),
                ("comment_ori", "0"),
                ("is_comment", "0"),
            ],
            credentials: credentials
        )

        switch response.kind {
        case .ok:
            guard let created = Self.parseCreatedComment(response.data, now: now) else {
                return .failure(.unknown)
            }
            return .replied(created)
        case .authExpired:
            return .failure(.authRequired)
        case .rateLimited:
            return .failure(.rateLimited(retryAfter: response.retryAfter))
        case .challenge:
            return .failure(.challenge)
        case .network:
            return .failure(.network)
        case .server:
            return .failure(.server)
        case .parseChanged, .emptyList, .unknown:
            return .failure(.unknown)
        }
    }

    // MARK: - Budget

    private func gate(_ kind: Kind, now: Date) -> WeiboCommentWriteFailure? {
        switch kind {
        case .like:
            likeSendTimes.removeAll { now.timeIntervalSince($0) >= 3600 }
            if likeSendTimes.count >= Self.likeBudgetPerHour, let oldest = likeSendTimes.min() {
                return .localLimit(retryAfter: max(1, 3600 - now.timeIntervalSince(oldest)))
            }
        case .reply:
            replySendTimes.removeAll { now.timeIntervalSince($0) >= 3600 }
            if replySendTimes.count >= Self.replyBudgetPerHour, let oldest = replySendTimes.min() {
                return .localLimit(retryAfter: max(1, 3600 - now.timeIntervalSince(oldest)))
            }
        }
        if let lastSendAt {
            let elapsed = now.timeIntervalSince(lastSendAt)
            if elapsed < Self.minimumInterval {
                return .localLimit(retryAfter: Self.minimumInterval - elapsed)
            }
        }
        return nil
    }

    private func record(_ kind: Kind, at now: Date) {
        lastSendAt = now
        switch kind {
        case .like:
            likeSendTimes.append(now)
        case .reply:
            replySendTimes.append(now)
        }
    }

    // MARK: - HTTP

    private struct Response {
        let kind: WeiboRiskKind
        let data: Data
        let retryAfter: TimeInterval?
    }

    private func post(
        url: String,
        form: [(String, String)],
        credentials: WeiboCredentials
    ) async -> Response {
        guard let cookies = credentials.desktopCookieHeader, !cookies.isEmpty,
              let target = URL(string: url) else {
            return Response(kind: .authExpired, data: Data(), retryAfter: nil)
        }

        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://weibo.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://weibo.com", forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue("v1.1.260", forHTTPHeaderField: "client-version")
        if let token = Self.cookieValue(named: "XSRF-TOKEN", in: cookies) {
            request.setValue(token.removingPercentEncoding ?? token, forHTTPHeaderField: "x-xsrf-token")
        }
        request.httpBody = Self.formBody(form)

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let kind = WeiboRiskSignal.classify(
                statusCode: http?.statusCode,
                data: data,
                contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                error: nil
            )
            return Response(kind: kind, data: data, retryAfter: Self.retryAfter(from: http))
        } catch {
            return Response(
                kind: WeiboRiskSignal.classify(statusCode: nil, data: nil, contentType: nil, error: error),
                data: Data(),
                retryAfter: nil
            )
        }
    }

    private static let desktopUserAgent = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 \
    (KHTML, like Gecko) Version/17.6 Safari/605.1.15
    """

    private static func formBody(_ pairs: [(String, String)]) -> Data {
        let body = pairs
            .map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func cookieValue(named name: String, in header: String) -> String? {
        for pair in header.split(separator: ";", omittingEmptySubsequences: true) {
            let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespaces)
                      .caseInsensitiveCompare(name) == .orderedSame else { continue }
            let raw = fields[1].trimmingCharacters(in: .whitespaces)
            let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !unquoted.isEmpty { return unquoted }
        }
        return nil
    }

    private static func retryAfter(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(0, seconds)
    }

    // MARK: - Response parsing

    private static func parseCreatedComment(_ data: Data, now: Date) -> WeiboComment? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else { return nil }

        let id = string(payload["idstr"]) ?? string(payload["id"]) ?? string(payload["mid"])
        guard let id, !id.isEmpty else { return nil }

        let user = payload["user"] as? [String: Any]
        let uid = string(user?["idstr"]) ?? string(user?["id"]) ?? ""
        let screenName = string(user?["screen_name"]) ?? ""
        let rawText = string(payload["text_raw"]) ?? string(payload["text"]) ?? ""
        let createdAt = date(string(payload["created_at"]), now: now) ?? now

        return WeiboComment(
            id: id,
            mid: string(payload["mid"]) ?? id,
            uid: uid,
            screenName: screenName,
            avatarURL: string(user?["profile_image_url"]),
            text: rawText,
            createdAt: createdAt,
            likeCount: integer(payload["like_counts"]) ?? 0,
            replyToName: nil,
            isAuthor: bool(payload["is_mblog_author"]) ?? false,
            runs: nil,
            liked: false
        )
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.lowercased() == "true" }
        return nil
    }

    private static func date(_ raw: String?, now: Date) -> Date? {
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: raw)
    }
}
