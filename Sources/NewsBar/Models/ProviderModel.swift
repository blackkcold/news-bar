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
    case invalidEndpoint, unauthorized, unsupportedEndpoint, malformedResponse, responseTooLarge, incompletePagination, emptyCatalog, network, server(Int)

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
        case .unsupportedEndpoint: return english ? "This provider did not expose a compatible model-list endpoint. No model IDs were guessed." : "提供商未提供兼容的模型列表接口，未猜测或填入旧型号。"
        case .emptyCatalog: return english ? "The provider returned no eligible text-generation models." : "提供商当前未返回可用的文本生成模型。"
        case .malformedResponse, .incompletePagination: return english ? "The model list was incomplete or unreadable. Try refreshing it." : "模型列表格式异常或分页不完整，请重新获取。"
        case .responseTooLarge: return english ? "The model list exceeded the safety size limit." : "模型列表超过安全大小上限。"
        case .server(let status): return english ? "The provider's model-list request failed (HTTP \(status))." : "提供商模型列表请求失败（HTTP \(status)）。"
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

enum ProviderModelParser {
    private struct Envelope: Decodable {
        let data: [Entry]?
        let models: [Entry]?
        let has_more: Bool?
        let last_id: String?
        let nextPageToken: String?
    }

    private struct Entry: Decodable {
        let id: String?
        let name: String?
        let model: String?
        let display_name: String?
        let displayName: String?
        let created: Double?
        let created_at: String?
        let modified_at: String?
        let capabilities: [String]?
        let supportedGenerationMethods: [String]?
        let output_modalities: [String]?
        let enabled: Bool?
        let deprecated: Bool?
        let status: String?
    }

    static func parse(_ data: Data, format: ProviderModelFormat) throws -> ProviderModelPage {
        guard data.count <= 1024 * 1024 else { throw ProviderModelError.responseTooLarge }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw ProviderModelError.malformedResponse }
        let entries: [Entry]
        switch format {
        case .ollama, .google:
            guard let models = envelope.models else { throw ProviderModelError.malformedResponse }
            entries = models
        case .openAI, .anthropic:
            guard let models = envelope.data else { throw ProviderModelError.malformedResponse }
            entries = models
        }
        guard entries.count <= 5000 else { throw ProviderModelError.responseTooLarge }
        var seen: Set<String> = []
        let models = entries.compactMap { entry -> ProviderModel? in
            guard entry.enabled != false, entry.deprecated != true,
                  !["retired", "disabled", "deleted", "unavailable", "deprecated"].contains(entry.status?.lowercased() ?? "") else { return nil }
            let raw: String?
            switch format {
            case .ollama:
                if let caps = entry.capabilities, !caps.contains("completion") { return nil }
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
            return ProviderModel(id: id, displayName: entry.display_name ?? entry.displayName, createdAt: date)
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
