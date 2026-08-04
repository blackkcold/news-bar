import Foundation

struct ResolvedAIConnection: Sendable {
    var baseURL: String
    var responseFormat: AIProvider.ResponseFormat
    var authHeaderName: String
    var authHeaderPrefix: String
    var apiVersion: String?
}

struct CustomAIProviderConfig: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var baseURL: String
    var models: [String]
    var defaultModel: String?
    var responseFormat: AIProvider.ResponseFormat
    var authHeaderName: String
    var authHeaderPrefix: String
    var apiVersion: String?
    var pricingNote: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        models: [String],
        defaultModel: String? = nil,
        responseFormat: AIProvider.ResponseFormat = .openAI,
        authHeaderName: String = "Authorization",
        authHeaderPrefix: String = "Bearer ",
        apiVersion: String? = nil,
        pricingNote: String? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.defaultModel = defaultModel
        self.responseFormat = responseFormat
        self.authHeaderName = authHeaderName
        self.authHeaderPrefix = authHeaderPrefix
        self.apiVersion = apiVersion
        self.pricingNote = pricingNote
    }

    /// CRITICAL: AppSettings decodes `[CustomAIProviderConfig]` with `try?` — a
    /// single throw wipes the entire array. All fields must decode safely.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? ""
        models = (try? c.decode([String].self, forKey: .models)) ?? []
        defaultModel = try? c.decodeIfPresent(String.self, forKey: .defaultModel)
        let rawFormat = (try? c.decodeIfPresent(String.self, forKey: .responseFormat)) ?? "openAI"
        responseFormat = (rawFormat == "anthropic") ? .anthropic : .openAI
        authHeaderName = (try? c.decode(String.self, forKey: .authHeaderName)) ?? "Authorization"
        authHeaderPrefix = (try? c.decode(String.self, forKey: .authHeaderPrefix)) ?? "Bearer "
        apiVersion = try? c.decodeIfPresent(String.self, forKey: .apiVersion)
        pricingNote = try? c.decodeIfPresent(String.self, forKey: .pricingNote)
    }

    var effectiveModels: [String] {
        var list = models
        if let def = defaultModel, !def.isEmpty, !list.contains(def) {
            list.insert(def, at: 0)
        }
        return list.isEmpty ? [""] : list
    }

    func resolvedConnection() -> ResolvedAIConnection {
        ResolvedAIConnection(
            baseURL: baseURL,
            responseFormat: responseFormat,
            authHeaderName: authHeaderName,
            authHeaderPrefix: authHeaderPrefix,
            apiVersion: apiVersion ?? (responseFormat == .anthropic ? "2023-06-01" : nil)
        )
    }
}
