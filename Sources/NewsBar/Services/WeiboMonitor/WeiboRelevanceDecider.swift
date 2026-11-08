import Foundation

/// Everything the decision model needs beyond the post text. Short leaks are
/// unreadable without the account; the model gets it in structured form.
struct WeiboDecisionContext: Sendable, Equatable {
    var screenName: String
    var recentTopics: [String]
    var isLongText: Bool
}

struct WeiboDecisionResult: Sendable, Equatable {
    var isAd: Double
    var isOffTopic: Double
    var topic: String?
    var topicConfidence: Double?
    var infoScore: Double?
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var costMicros: Int64
}

enum WeiboDecisionError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case transport(String)

    var isTransient: Bool {
        switch self {
        case .invalidResponse, .httpStatus, .transport:
            return true
        }
    }
}

/// A decision model answers a handful of atomic questions about one piece of
/// text. It never writes the feed; the service fuses the answer with the local
/// rules and keeps the rules in charge.
protocol WeiboRelevanceDeciding: Sendable {
    var providerID: String { get }
    /// True when the text never leaves the machine.
    var isLocal: Bool { get }
    /// True when the endpoint has no monetary cost for the user.
    var isFree: Bool { get }
    func decide(text: String, context: WeiboDecisionContext) async throws -> WeiboDecisionResult
}

/// Any endpoint that speaks the System One `/v1/systemone` protocol. OpenCode
/// Console, Ollama (local and cloud) and TypeSafe differ only in base URL,
/// model and auth, so one client covers all four without a fake adapter.
struct WeiboSystemOneClient: WeiboRelevanceDeciding {
    enum Kind: String, Sendable {
        case openCodeFree
        case openCodePaid
        case ollamaLocal
        case ollamaCloud
        case typeSafe
    }

    let kind: Kind
    let providerID: String
    let isLocal: Bool
    let isFree: Bool
    private let endpoint: URL
    private let model: String
    private let authorization: String?
    private let session: URLSession

    init(
        kind: Kind,
        endpoint: URL,
        model: String,
        authorization: String?,
        timeout: TimeInterval = 2.6,
        session: URLSession? = nil
    ) {
        self.kind = kind
        self.providerID = kind.rawValue
        self.isLocal = kind == .ollamaLocal
        self.isFree = kind == .openCodeFree || kind == .ollamaLocal
        self.endpoint = endpoint
        self.model = model
        self.authorization = authorization

        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 1
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    static func openCodeFree(
        apiKey: String? = ProcessInfo.processInfo.environment["OPENCODE_API_KEY"]
    ) -> WeiboSystemOneClient {
        WeiboSystemOneClient(
            kind: .openCodeFree,
            endpoint: URL(string: "https://opencode.ai/inference/systemone/v1/systemone")!,
            model: "jev-1.13-free",
            authorization: apiKey.map { "Bearer \($0)" }
        )
    }

    static func openCodePaid(apiKey: String) -> WeiboSystemOneClient {
        WeiboSystemOneClient(
            kind: .openCodePaid,
            endpoint: URL(string: "https://opencode.ai/inference/systemone/v1/systemone")!,
            model: "jev-1.13",
            authorization: "Bearer \(apiKey)"
        )
    }

    static func ollamaLocal(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!
    ) -> WeiboSystemOneClient {
        WeiboSystemOneClient(
            kind: .ollamaLocal,
            endpoint: baseURL.appendingPathComponent("v1/systemone"),
            model: "tev1:0.8b",
            authorization: nil,
            timeout: 4.0
        )
    }

    static func ollamaCloud(apiKey: String) -> WeiboSystemOneClient {
        WeiboSystemOneClient(
            kind: .ollamaCloud,
            endpoint: URL(string: "https://ollama.com/v1/systemone")!,
            model: "nimble:cloud",
            authorization: "Bearer \(apiKey)"
        )
    }

    static func typeSafe(apiKey: String) -> WeiboSystemOneClient {
        WeiboSystemOneClient(
            kind: .typeSafe,
            endpoint: URL(string: "https://api.typesafe.ai/v1/systemone")!,
            model: "jev-latest",
            authorization: "Bearer \(apiKey)"
        )
    }

    func decide(text: String, context: WeiboDecisionContext) async throws -> WeiboDecisionResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        let state: [String: Any] = [
            "account": context.screenName,
            "text": text,
            "is_long_text": context.isLongText,
            "account_recent_topics": context.recentTopics,
        ]
        let questions: [String: Any] = [
            "is_ad": [
                "type": "noul",
                "instructions": "这条微博是在推销、带货、抽奖或商业推广吗？新闻里顺带提到品牌不算。",
            ],
            "is_off": [
                "type": "noul",
                "instructions": "这条微博的内容与手机、电脑、数码产品、软件或 AI 无关吗？",
            ],
            "topic": [
                "type": "choice",
                "instructions": "这条微博的主题是什么？",
                "criteria": [
                    "phone": "手机/平板/穿戴",
                    "pc": "电脑/外设",
                    "ai": "AI/模型/开源",
                    "software": "系统/App/更新",
                    "auto": "汽车",
                    "life": "生活/美食/风景",
                    "ent": "影视/游戏/娱乐",
                    "policy": "政策/行业",
                    "other": "其他",
                ],
            ],
            "info": [
                "type": "score",
                "instructions": "这条微博的信息量如何？",
                "criteria": ["无实质信息", "有观点无细节", "有具体参数或事实"],
            ],
        ]
        let body: [String: Any] = [
            "model": model,
            "state": state,
            "questions": questions,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WeiboDecisionError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw WeiboDecisionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WeiboDecisionError.httpStatus(http.statusCode)
        }
        return try Self.parse(data, fallbackModel: model)
    }

    // MARK: - Response

    static func parse(_ data: Data, fallbackModel: String) throws -> WeiboDecisionResult {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let answers = root["answers"] as? [String: Any] else {
            throw WeiboDecisionError.invalidResponse
        }
        let isAd = noul(answers["is_ad"]) ?? 0
        let isOff = noul(answers["is_off"]) ?? 0
        let topicAnswer = answers["topic"] as? [String: Any]
        let topic = topicAnswer?["choice"] as? String
        var topicConfidence: Double?
        if let probabilities = topicAnswer?["probabilities"] as? [String: Any],
           let choice = topic,
           let value = probabilities[choice] as? Double {
            topicConfidence = min(1, max(0, value))
        }
        let infoScore = (answers["info"] as? [String: Any])?["score"] as? Double

        let usage = root["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0
        let cost = usage?["cost"] as? Double ?? 0

        return WeiboDecisionResult(
            isAd: min(1, max(0, isAd)),
            isOffTopic: min(1, max(0, isOff)),
            topic: topic,
            topicConfidence: topicConfidence,
            infoScore: infoScore,
            model: root["model"] as? String ?? fallbackModel,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costMicros: Int64((max(0, cost) * 1_000_000).rounded())
        )
    }

    private static func noul(_ raw: Any?) -> Double? {
        guard let answer = raw as? [String: Any] else { return nil }
        if let value = answer["noul"] as? Double { return value }
        if let value = answer["noul"] as? Int { return Double(value) }
        return nil
    }
}

/// Stops calling a provider after three consecutive failures. A tripped
/// breaker never changes a verdict: the local rules already produced one.
struct WeiboRelevanceCircuitBreaker: Sendable, Equatable {
    static let failureThreshold = 3
    static let cooldown: TimeInterval = 10 * 60

    private(set) var consecutiveFailures = 0
    private(set) var openUntil: Date?

    func isOpen(now: Date) -> Bool {
        guard let openUntil else { return false }
        return openUntil > now
    }

    func canRequest(now: Date) -> Bool {
        !isOpen(now: now)
    }

    mutating func noteSuccess() {
        consecutiveFailures = 0
        openUntil = nil
    }

    mutating func noteFailure(now: Date) {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failureThreshold {
            openUntil = now.addingTimeInterval(Self.cooldown)
            consecutiveFailures = 0
        }
    }

    mutating func reset() {
        consecutiveFailures = 0
        openUntil = nil
    }
}
