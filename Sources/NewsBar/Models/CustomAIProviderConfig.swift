import Foundation

struct ResolvedAIConnection: Sendable {
    var baseURL: String
    var responseFormat: AIProvider.ResponseFormat
    var authHeaderName: String
    var authHeaderPrefix: String
    var apiVersion: String?
    /// Provider id used by the price catalog (`deepseek`, `ollamaCloud`, …).
    var providerID: String = ""
    /// User-entered unit prices for a custom provider, already CNY per 1M tokens.
    var customPrice: ModelPrice? = nil
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
    /// Optional unit prices entered by the user, CNY per million tokens.
    var inputPricePerMTok: Double?
    var outputPricePerMTok: Double?
    var cacheReadPricePerMTok: Double?

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
        pricingNote: String? = nil,
        inputPricePerMTok: Double? = nil,
        outputPricePerMTok: Double? = nil,
        cacheReadPricePerMTok: Double? = nil
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
        self.inputPricePerMTok = inputPricePerMTok
        self.outputPricePerMTok = outputPricePerMTok
        self.cacheReadPricePerMTok = cacheReadPricePerMTok
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
        inputPricePerMTok = try? c.decodeIfPresent(Double.self, forKey: .inputPricePerMTok)
        outputPricePerMTok = try? c.decodeIfPresent(Double.self, forKey: .outputPricePerMTok)
        cacheReadPricePerMTok = try? c.decodeIfPresent(Double.self, forKey: .cacheReadPricePerMTok)
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
            apiVersion: apiVersion ?? (responseFormat == .anthropic ? "2023-06-01" : nil),
            providerID: "custom:\(id)",
            customPrice: unitPrice
        )
    }

    /// Prices are only usable when both input and output are present.
    var unitPrice: ModelPrice? {
        guard let input = inputPricePerMTok, let output = outputPricePerMTok,
              input >= 0, output >= 0 else { return nil }
        return ModelPrice(
            provider: "custom:\(id)",
            modelPrefix: defaultModel ?? "",
            inputPerMTok: input,
            outputPerMTok: output,
            cacheReadPerMTok: cacheReadPricePerMTok,
            cacheWritePerMTok: nil,
            currency: "CNY",
            updatedAt: ""
        )
    }
}
