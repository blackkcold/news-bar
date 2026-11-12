import Foundation

/// In-memory only. Never persisted or logged: includes the key that was
/// validated with this exact endpoint and model catalog.
struct ValidatedAIConfiguration: Sendable {
    let providerID: String
    let connection: ResolvedAIConnection
    let model: String
    let apiKey: String
    let revision: UUID
}

struct ProviderModel: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String? = nil
    var createdAt: Date? = nil
    /// True when the provider prices this model at zero. OpenCode Zen's free
    /// tier is only callable from OpenCode itself, so it must not be offered
    /// to this app.
    var isFree: Bool = false
    /// False for models whose API cannot serve a chat request, such as System
    /// One's `jev-*` evaluators.
    var isChatCompatible: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, displayName, createdAt, isFree, isChatCompatible
    }
}

extension ProviderModel {
    /// Older cached catalogs predate these flags. A missing flag must decode
    /// instead of invalidating the whole snapshot.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        isFree = try c.decodeIfPresent(Bool.self, forKey: .isFree) ?? false
        isChatCompatible = try c.decodeIfPresent(Bool.self, forKey: .isChatCompatible) ?? true
    }
}

enum ProviderModelSelection {
    static func isDeepSeek(_ id: String) -> Bool {
        id.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).contains("deepseek")
    }

    static func ordered(_ models: [ProviderModel]) -> [ProviderModel] {
        models.sorted {
            let a = isDeepSeek($0.id), b = isDeepSeek($1.id)
            if a != b { return a }
            // Prefer unpinned aliases over date/tag snapshots for a new default.
            let aPinned = $0.id.contains(":"), bPinned = $1.id.contains(":")
            if aPinned != bPinned { return !aPinned }
            return $0.id.compare($1.id, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedDescending
        }
    }

    static func preferred(in models: [ProviderModel], current: String?) -> String? {
        let deepseek = models.filter { isDeepSeek($0.id) }
        let eligible = deepseek.isEmpty ? models : deepseek
        if let current, eligible.contains(where: { $0.id == current }) { return current }
        return ordered(eligible).first?.id
    }
}

enum ProviderModelError: Error, Equatable, Sendable {
    case invalidEndpoint, unauthorized, keyReadFailed, unsupportedEndpoint, malformedResponse, responseTooLarge, incompletePagination, emptyCatalog, network, server(Int)
    case cannotResolveHost(String)
    case tlsFailure(String)
    case timedOut

    var invalidatesCache: Bool {
        switch self {
        case .unauthorized, .emptyCatalog: return true
        default: return false
        }
    }

    func message(language: AppLanguage) -> String {
        let english = language == .en
        switch self {
        case .invalidEndpoint: return english ? "A valid HTTPS provider endpoint is required." : "请配置有效的 HTTPS 提供商端点。"
        case .unauthorized: return english ? "The provider rejected this API key or account access. Cached models will not be used." : "提供商拒绝了当前 API Key 或账户权限，已停止使用缓存模型。"
        case .keyReadFailed: return AISearchError.keyReadFailed.message(language)
        case .unsupportedEndpoint: return english ? "This provider did not expose a compatible model-list endpoint. No model IDs were guessed." : "提供商未提供兼容的模型列表接口，未猜测或填入旧型号。"
        case .emptyCatalog: return english ? "The provider returned no eligible text-generation models." : "提供商当前未返回可用的文本生成模型。"
        case .malformedResponse, .incompletePagination: return english ? "The model list was incomplete or unreadable. Try refreshing it." : "模型列表格式异常或分页不完整，请重新获取。"
        case .responseTooLarge: return english ? "The model list exceeded the safety size limit." : "模型列表超过安全大小上限。"
        case .server(let status): return english ? "The provider's model-list request failed (HTTP \(status))." : "提供商模型列表请求失败（HTTP \(status)）。"
        case .cannotResolveHost(let host): return english ? "Cannot resolve the provider host (\(host)). The domain may be retired or blocked by DNS." : "无法解析提供商域名（\(host)）。该域名可能已注销或 DNS 被拦截。"
        case .tlsFailure(let host): return english ? "Could not establish a secure connection to \(host) (TLS). Check the proxy or certificate." : "与 \(host) 建立加密连接失败（TLS）。请检查代理或证书。"
        case .timedOut: return english ? "The provider request timed out. Try again shortly." : "请求提供商超时，请稍后重试。"
        case .network: return english ? "Cannot refresh the model list. Check the network connection." : "暂时无法刷新模型列表，请检查网络连接。"
        }
    }
}

struct ProviderModelSnapshot: Codable, Sendable {
    let identity: String
    let models: [ProviderModel]
    let fetchedAt: Date
}

struct ProviderModelResult: Sendable {
    enum Source: Sendable { case live, cache, stale }
    let snapshot: ProviderModelSnapshot
    let source: Source
    var refreshError: ProviderModelError? = nil
}

enum ProviderModelFormat: Sendable { case openAI, anthropic, ollama, google }

struct ProviderModelPage: Sendable {
    let models: [ProviderModel]
    let nextCursor: String?
}

/// Keys of an open-ended JSON object. Used where only the presence of keys
/// matters (`api`, TTL-keyed prices) and values may change shape.
private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

enum ProviderModelParser {
    private struct Envelope: Decodable {
        let data: [Entry?]?
        let models: [Entry?]?
        let has_more: Bool?
        let last_id: String?
        let nextPageToken: String?

        enum CodingKeys: String, CodingKey {
            case data, models, has_more, last_id, nextPageToken
        }

        /// Only the root shape is fatal. Every value inside is advisory: a
        /// provider-side type change must not discard the whole catalog.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            data = try? container.decodeIfPresent([Entry?].self, forKey: .data)
            models = try? container.decodeIfPresent([Entry?].self, forKey: .models)
            has_more = try? container.decodeIfPresent(Bool.self, forKey: .has_more)
            last_id = try? container.decodeIfPresent(String.self, forKey: .last_id)
            nextPageToken = try? container.decodeIfPresent(String.self, forKey: .nextPageToken)
        }
    }

    /// Every field decodes on its own. Providers add richer shapes without
    /// warning (object capabilities, TTL-keyed cache prices), and one
    /// unreadable entry must only drop that model — never empty the picker.
    private struct Entry: Decodable {
        let id: String?
        let name: String?
        let model: String?
        let display_name: String?
        let displayName: String?
        let created: Double?
        let created_at: String?
        let modified_at: String?
        let capabilities: FlexibleStringList?
        let supportedGenerationMethods: [String]?
        let output_modalities: [String]?
        let enabled: Bool?
        let deprecated: Bool?
        let status: String?
        let type: String?
        let cost: ModelCost?
        let api: APIMap?

        enum CodingKeys: String, CodingKey {
            case id, name, model, display_name, displayName, created, created_at, modified_at
            case capabilities, supportedGenerationMethods, output_modalities, enabled, deprecated, status, type, cost, api
        }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            id = container.flatMap { try? $0.decodeIfPresent(String.self, forKey: .id) }
            name = container.flatMap { try? $0.decodeIfPresent(String.self, forKey: .name) }
            model = container.flatMap { try? $0.decodeIfPresent(String.self, forKey: .model) }
            display_name = container.flatMap { try? $0.decodeIfPresent(String.self, forKey: .display_name) }
            displayName = container.flatMap { try? $0.decodeIfPresent(String.self, forKey: .displayName) }
            created = container.flatMap { try? $0.decodeIfPresent(Double.self, forKey: .created) }
            created_at = container.flatMap { try? $0.decodeIfPresent(String.self, forKey: .created_at) }
            modified_at = container.flatMap { try? $0.decodeIfPresent(String.self, forKey: .modified_at) }
            capabilities = container.flatMap { try? $0.decodeIfPresent(FlexibleStringList.self, forKey: .capabilities) }
            supportedGenerationMethods = container.flatMap { try? $0.decodeIfPresent([String].self, forKey: .supportedGenerationMethods) }
            output_modalities = container.flatMap { try? $0.decodeIfPresent([String].self, forKey: .output_modalities) }
            enabled = container.flatMap { try? $0.decodeIfPresent(Bool.self, forKey: .enabled) }
            deprecated = container.flatMap { try? $0.decodeIfPresent(Bool.self, forKey: .deprecated) }
            status = container.flatMap { try? $0.decodeIfPresent(String.self, forKey: .status) }
            type = container.flatMap { try? $0.decodeIfPresent(String.self, forKey: .type) }
            cost = container.flatMap { try? $0.decodeIfPresent(ModelCost.self, forKey: .cost) }
            api = container.flatMap { try? $0.decodeIfPresent(APIMap.self, forKey: .api) }
        }
    }

    /// OpenCode's catalog nests prices under `cost.text`. Zero input and
    /// output marks the free models that only OpenCode itself may call.
    private struct ModelCost: Decodable {
        struct Text: Decodable {
            struct Side: Decodable {
                struct Cache: Decodable {
                    let read: PriceAmount?
                    let write: PriceAmount?
                }
                let price: PriceAmount?
                let cache: Cache?
            }
            let input: Side?
            let output: Side?
        }
        let text: Text?
    }

    /// A price is normally a number. OpenCode already publishes TTL-keyed
    /// cache-write prices (`{"30m":0.25,"12h":0.5}`), so both shapes must
    /// decode; the ceiling is the safe value for a local estimate.
    private struct PriceAmount: Decodable {
        let value: Double?

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let number = try? single.decode(Double.self) {
                value = number
                return
            }
            guard let object = try? decoder.container(keyedBy: DynamicKey.self) else {
                value = nil
                return
            }
            value = object.allKeys.compactMap { try? object.decode(Double.self, forKey: $0) }.max()
        }
    }

    /// Only the keys matter: `chat-completions`, `responses`, `messages`,
    /// `generate-content` and `systemone`. Decoding the values would bind the
    /// app to a shape that changes as models gain capabilities.
    private struct APIMap: Decodable {
        let keys: Set<String>

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            keys = Set(container.allKeys.map(\.stringValue))
        }
    }

    /// Ollama lists capabilities as strings; OpenCode lists them as an object.
    /// A wrong shape must not fail the entire catalog, so anything other than
    /// a string array decodes to an empty list.
    private struct FlexibleStringList: Decodable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            values = (try? container.decode([String].self)) ?? []
        }
    }

    static func parse(_ data: Data, format: ProviderModelFormat) throws -> ProviderModelPage {
        guard data.count <= 1024 * 1024 else { throw ProviderModelError.responseTooLarge }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw ProviderModelError.malformedResponse }
        let entries: [Entry]
        switch format {
        case .ollama, .google:
            guard let models = envelope.models else { throw ProviderModelError.malformedResponse }
            entries = models.compactMap { $0 }
        case .openAI, .anthropic:
            guard let data = envelope.data else { throw ProviderModelError.malformedResponse }
            entries = data.compactMap { $0 }
        }
        guard entries.count <= 5000 else { throw ProviderModelError.responseTooLarge }
        var seen: Set<String> = []
        let models = entries.compactMap { entry -> ProviderModel? in
            guard entry.enabled != false, entry.deprecated != true,
                  !["retired", "disabled", "deleted", "unavailable", "deprecated"].contains(entry.status?.lowercased() ?? "") else { return nil }
            let raw: String?
            switch format {
            case .ollama:
                if let caps = entry.capabilities?.values, !caps.contains("completion") { return nil }
                raw = entry.name ?? entry.model
            case .google:
                guard entry.supportedGenerationMethods?.contains("generateContent") == true else { return nil }
                raw = entry.name.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            default: raw = entry.id
            }
            if let outputs = entry.output_modalities, !outputs.contains("text") { return nil }
            guard let id = raw, !id.isEmpty, id.utf8.count <= 256,
                  id.range(of: "^[A-Za-z0-9._:/@+\\-]+$", options: .regularExpression) != nil,
                  !["embedding", "whisper", "tts", "image-generation", "dall-e"].contains(where: id.lowercased().contains),
                  seen.insert(id).inserted else { return nil }
            let date: Date?
            if let timestamp = entry.created { date = Date(timeIntervalSince1970: timestamp) }
            else if let rawDate = entry.created_at ?? entry.modified_at { date = ISO8601DateFormatter().date(from: rawDate) }
            else { date = nil }
            let costText = entry.cost?.text
            let zeroPriced = costText?.input?.price?.value == 0 && costText?.output?.price?.value == 0
            let freeByName = id.lowercased().hasSuffix("-free")
            let apiKeys = entry.api?.keys ?? []
            let chatType = entry.type == nil || entry.type == "chat" || entry.type == "text"
            // The catalog's `api` map is authoritative. Without `chat-completions`
            // this client's OpenAI-shaped request cannot call the model, and
            // offering it would only produce a failed generation.
            let chatProtocol = apiKeys.isEmpty || apiKeys.contains("chat-completions")
            return ProviderModel(
                id: id,
                displayName: entry.display_name ?? entry.displayName,
                createdAt: date,
                isFree: zeroPriced || freeByName,
                isChatCompatible: chatType && chatProtocol && !apiKeys.contains("systemone")
            )
        }
        let cursor: String?
        if format == .google { cursor = envelope.nextPageToken?.isEmpty == false ? envelope.nextPageToken : nil }
        else if envelope.has_more == true {
            guard let last = envelope.last_id, !last.isEmpty, last.utf8.count <= 512 else { throw ProviderModelError.incompletePagination }
            cursor = last
        } else { cursor = nil }
        return ProviderModelPage(models: models, nextCursor: cursor)
    }
}
