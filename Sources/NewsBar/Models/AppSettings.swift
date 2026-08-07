import Foundation
import Observation
import SwiftUI

/// Identifies which summary context an operation targets.
/// Top-level so both AppSettings and AISummaryService can use it.
enum SummaryTarget: String, Sendable, CaseIterable {
    case popup
    case dashboard
}

/// Budget mode for AI summary daily request caps.
/// - shared: Popup and Dashboard share a single total daily cap (`aiDailyCap`).
/// - independent: Each target has its own daily cap (`aiPopupDailyCap` / `aiDashboardDailyCap`).
enum AISummaryBudgetMode: String, Sendable, CaseIterable {
    case shared
    case independent
}

enum AppTheme: String, Sendable, CaseIterable, Identifiable {
    case modern
    case retroEditorial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modern: return "现代材质"
        case .retroEditorial: return "复古报刊"
        }
    }
}

enum AppLanguage: String, Sendable, Codable, CaseIterable, Identifiable {
    case zh
    case en

    var id: String { rawValue }

    var bcp47: String {
        switch self {
        case .zh: return "zh-CN"
        case .en: return "en"
        }
    }

    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

@Observable
final class AppSettings {
    var autoRefreshEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRefreshEnabled, forKey: "autoRefreshEnabled") }
    }
    var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    var colorScheme: String {
        didSet { UserDefaults.standard.set(colorScheme, forKey: "colorScheme") }
    }
    var appTheme: AppTheme {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme") }
    }
    var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            L10n.currentLanguage = appLanguage
        }
    }
    var rssTitleTranslationEnabled: Bool {
        didSet { UserDefaults.standard.set(rssTitleTranslationEnabled, forKey: "rssTitleTranslationEnabled") }
    }
    @ObservationIgnored var resolvedColorScheme: ColorScheme? {
        if appTheme == .retroEditorial { return .light }
        switch colorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var aiSummaryEnabled: Bool {
        didSet { UserDefaults.standard.set(aiSummaryEnabled, forKey: "aiSummaryEnabled") }
    }
    var aiModel: String {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel") }
    }
    var aiPopupMaxWords: Int {
        didSet { UserDefaults.standard.set(aiPopupMaxWords, forKey: "aiPopupMaxWords") }
    }
    var aiDashboardMaxWords: Int {
        didSet { UserDefaults.standard.set(aiDashboardMaxWords, forKey: "aiDashboardMaxWords") }
    }
    var aiMaxWords: Int {
        didSet { UserDefaults.standard.set(aiMaxWords, forKey: "aiMaxWords") }
    }
    var aiDailyCap: Int {
        didSet { UserDefaults.standard.set(aiDailyCap, forKey: "aiDailyCap") }
    }
    var aiBudgetMode: AISummaryBudgetMode {
        didSet { UserDefaults.standard.set(aiBudgetMode.rawValue, forKey: "aiBudgetMode") }
    }
    /// When true, DeepSeek V4's thinking mode is disabled for faster,
    /// non-truncated summaries. Exposed in Settings → AI.
    var aiDisableDeepSeekThinking: Bool {
        didSet { UserDefaults.standard.set(aiDisableDeepSeekThinking, forKey: "aiDisableDeepSeekThinking") }
    }
    var aiPopupDailyCap: Int {
        didSet { UserDefaults.standard.set(aiPopupDailyCap, forKey: "aiPopupDailyCap") }
    }
    var aiDashboardDailyCap: Int {
        didSet { UserDefaults.standard.set(aiDashboardDailyCap, forKey: "aiDashboardDailyCap") }
    }
    var aiProvider: String {
        didSet {
            guard !isInitializing else { return }
            UserDefaults.standard.set(aiProvider, forKey: "aiProvider")
            cachedAPIKey = nil
        }
    }
    var onePasswordRef: String {
        didSet {
            guard !isInitializing else { return }
            Task {
                let store = EncryptedKeyStore()
                if onePasswordRef.isEmpty {
                    await store.deleteOnePasswordRef()
                } else {
                    _ = await store.saveOnePasswordRef(onePasswordRef)
                }
            }
        }
    }
    var selectedRSSSourceIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(selectedRSSSourceIDs), forKey: "selectedRSSSourceIDs")
        }
    }
    var todayRefreshCount: Int {
        didSet { UserDefaults.standard.set(todayRefreshCount, forKey: "todayRefreshCount") }
    }
    var todayAIRequestCount: Int {
        didSet { UserDefaults.standard.set(todayAIRequestCount, forKey: "todayAIRequestCount") }
    }
    var todayPopupAIRequestCount: Int {
        didSet { UserDefaults.standard.set(todayPopupAIRequestCount, forKey: "todayPopupAIRequestCount") }
    }
    var todayDashboardAIRequestCount: Int {
        didSet { UserDefaults.standard.set(todayDashboardAIRequestCount, forKey: "todayDashboardAIRequestCount") }
    }
    var lastRefreshTimestamp: Double {
        didSet { UserDefaults.standard.set(lastRefreshTimestamp, forKey: "lastRefreshTimestamp") }
    }
    var statsDayTimestamp: Double {
        didSet { UserDefaults.standard.set(statsDayTimestamp, forKey: "statsDayTimestamp") }
    }

    var updateDevMode: Bool {
        didSet { UserDefaults.standard.set(updateDevMode, forKey: "updateDevMode") }
    }

    var showAllAIModels: Bool {
        didSet { UserDefaults.standard.set(showAllAIModels, forKey: "showAllAIModels") }
    }

    var customAIProviders: [CustomAIProviderConfig] {
        didSet { saveCustomAIProviders() }
    }

    var hourlyPushEnabled: Bool {
        didSet { UserDefaults.standard.set(hourlyPushEnabled, forKey: "hourlyPushEnabled") }
    }
    var dailyPushEnabled: Bool {
        didSet { UserDefaults.standard.set(dailyPushEnabled, forKey: "dailyPushEnabled") }
    }
    var pushCount: Int {
        didSet { UserDefaults.standard.set(pushCount, forKey: "pushCount") }
    }
    var dailyPushHour: Int {
        didSet { UserDefaults.standard.set(dailyPushHour, forKey: "dailyPushHour") }
    }
    var dailyPushMinute: Int {
        didSet { UserDefaults.standard.set(dailyPushMinute, forKey: "dailyPushMinute") }
    }

    /// Master toggle for the Weibo "爆" burst-topic realtime push + research.
    var burstPushEnabled: Bool {
        didSet { UserDefaults.standard.set(burstPushEnabled, forKey: "burstPushEnabled") }
    }
    /// Enables the developer test-mode toggle that fires a fake burst push.
    var burstTestMode: Bool {
        didSet { UserDefaults.standard.set(burstTestMode, forKey: "burstTestMode") }
    }
    /// The user-entered hot-search title used by the burst test push.
    var burstTestTopic: String {
        didSet { UserDefaults.standard.set(burstTestTopic, forKey: "burstTestTopic") }
    }
    /// Developer-only toggle controlling whether the simulated burst push runs
    /// web search. Independent from `webSearchEnabled` so the test pipeline can
    /// be exercised with search even when the realtime burst search is off.
    var burstTestWebSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(burstTestWebSearchEnabled, forKey: "burstTestWebSearchEnabled") }
    }
    /// Optional web search for burst research. Off ⇒ pure-AI fallback.
    var webSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(webSearchEnabled, forKey: "webSearchEnabled") }
    }
    /// Optional Firecrawl API key. Empty ⇒ keyless free tier.
    var firecrawlAPIKey: String {
        didSet { UserDefaults.standard.set(firecrawlAPIKey, forKey: "firecrawlAPIKey") }
    }
    /// Independent daily cap for burst research AI requests.
    var burstDailyCap: Int {
        didSet { UserDefaults.standard.set(burstDailyCap, forKey: "burstDailyCap") }
    }
    var todayBurstResearchCount: Int {
        didSet { UserDefaults.standard.set(todayBurstResearchCount, forKey: "todayBurstResearchCount") }
    }

    /// Master toggle for custom-keyword realtime push + research.
    var keywordTrackingEnabled: Bool {
        didSet { UserDefaults.standard.set(keywordTrackingEnabled, forKey: "keywordTrackingEnabled") }
    }
    /// User-entered keywords; a news item whose title contains any keyword
    /// (case-insensitive) triggers a research push.
    var keywordList: [String] {
        didSet {
            UserDefaults.standard.set(keywordList, forKey: "keywordList")
        }
    }

    var rssUnifiedDisplayCount: Bool {
        didSet { UserDefaults.standard.set(rssUnifiedDisplayCount, forKey: "rssUnifiedDisplayCount") }
    }
    var rssDefaultTextCount: Int {
        didSet { UserDefaults.standard.set(rssDefaultTextCount, forKey: "rssDefaultTextCount") }
    }
    var rssDefaultImageCount: Int {
        didSet { UserDefaults.standard.set(rssDefaultImageCount, forKey: "rssDefaultImageCount") }
    }

    var rssSources: [RSSSourceConfig] {
        didSet { saveRSSSources() }
    }

    @ObservationIgnored var cachedAPIKey: String?
    private var isInitializing = true

    var currentProvider: AIProvider {
        AIProvider(rawValue: aiProvider) ?? .deepseek
    }

    init() {
        let defaults = UserDefaults.standard

        self.autoRefreshEnabled = defaults.boolIfPresent(forKey: "autoRefreshEnabled") ?? false
        self.launchAtLogin = defaults.boolIfPresent(forKey: "launchAtLogin") ?? false
        self.colorScheme = defaults.stringIfPresent(forKey: "colorScheme") ?? "system"
        self.appTheme = AppTheme(rawValue: defaults.stringIfPresent(forKey: "appTheme") ?? "") ?? .modern
        let language = AppLanguage(rawValue: defaults.stringIfPresent(forKey: "appLanguage") ?? "") ?? .zh
        self.appLanguage = language
        L10n.currentLanguage = language
        self.rssTitleTranslationEnabled = defaults.boolIfPresent(forKey: "rssTitleTranslationEnabled") ?? false
        self.aiSummaryEnabled = defaults.boolIfPresent(forKey: "aiSummaryEnabled") ?? false
        self.aiProvider = defaults.stringIfPresent(forKey: "aiProvider") ?? "deepseek"

        let savedModel = defaults.stringIfPresent(forKey: "aiModel")
            ?? "deepseek-v4-flash"
        let deprecatedModels: Set<String> = ["deepseek-chat", "deepseek-reasoner"]
        if deprecatedModels.contains(savedModel) {
            self.aiModel = "deepseek-v4-flash"
        } else {
            self.aiModel = savedModel
        }

        let rawPopupMaxWords = defaults.integerIfPresent(forKey: "aiPopupMaxWords") ?? 120
        self.aiPopupMaxWords = Self.validAIPopupMaxWords.contains(rawPopupMaxWords) ? rawPopupMaxWords : 120
        let rawDashboardMaxWords = defaults.integerIfPresent(forKey: "aiDashboardMaxWords") ?? 360
        self.aiDashboardMaxWords = Self.validAIDashboardMaxWords.contains(rawDashboardMaxWords) ? rawDashboardMaxWords : 360
        self.aiMaxWords = defaults.integerIfPresent(forKey: "aiMaxWords") ?? 150
        let rawCap = defaults.integerIfPresent(forKey: "aiDailyCap") ?? 50
        self.aiDailyCap = Self.validAICaps.contains(rawCap) ? rawCap : 50
        let rawBudgetMode = defaults.stringIfPresent(forKey: "aiBudgetMode") ?? AISummaryBudgetMode.shared.rawValue
        self.aiBudgetMode = AISummaryBudgetMode(rawValue: rawBudgetMode) ?? .shared
        self.aiDisableDeepSeekThinking = defaults.boolIfPresent(forKey: "aiDisableDeepSeekThinking") ?? true
        let rawPopupCap = defaults.integerIfPresent(forKey: "aiPopupDailyCap") ?? 50
        self.aiPopupDailyCap = Self.validAICaps.contains(rawPopupCap) ? rawPopupCap : 50
        let rawDashboardCap = defaults.integerIfPresent(forKey: "aiDashboardDailyCap") ?? 50
        self.aiDashboardDailyCap = Self.validAICaps.contains(rawDashboardCap) ? rawDashboardCap : 50
        if let legacyRef = defaults.stringIfPresent(forKey: "onePasswordRef"),
           !legacyRef.isEmpty {
            defaults.removeObject(forKey: "onePasswordRef")
            self.onePasswordRef = legacyRef
            Task {
                let store = EncryptedKeyStore()
                _ = await store.saveOnePasswordRef(legacyRef)
            }
        } else {
            self.onePasswordRef = ""
        }

        let selectedIDs = defaults.stringArray(forKey: "selectedRSSSourceIDs") ?? []
        self.selectedRSSSourceIDs = Set(selectedIDs.map(SecurityPolicies.canonicalRSSURL))

        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        self.todayRefreshCount = defaults.integerIfPresent(forKey: "todayRefreshCount") ?? 0
        let legacyTotalCount = defaults.integerIfPresent(forKey: "todayAIRequestCount") ?? 0
        self.todayAIRequestCount = legacyTotalCount
        let hasPopupCount = defaults.object(forKey: "todayPopupAIRequestCount") != nil
        let hasDashboardCount = defaults.object(forKey: "todayDashboardAIRequestCount") != nil
        if !hasPopupCount && !hasDashboardCount && legacyTotalCount > 0 {
            self.todayPopupAIRequestCount = legacyTotalCount
            self.todayDashboardAIRequestCount = 0
        } else {
            self.todayPopupAIRequestCount = defaults.integerIfPresent(forKey: "todayPopupAIRequestCount") ?? 0
            self.todayDashboardAIRequestCount = defaults.integerIfPresent(forKey: "todayDashboardAIRequestCount") ?? 0
        }
        self.lastRefreshTimestamp = defaults.doubleIfPresent(forKey: "lastRefreshTimestamp") ?? 0
        self.statsDayTimestamp = defaults.doubleIfPresent(forKey: "statsDayTimestamp") ?? todayStart

        self.rssUnifiedDisplayCount = defaults.boolIfPresent(forKey: "rssUnifiedDisplayCount") ?? true
        let rawTextCount = defaults.integerIfPresent(forKey: "rssDefaultTextCount") ?? 10
        self.rssDefaultTextCount = RSSSourceConfig.validTextCounts.contains(rawTextCount) ? rawTextCount : 10
        let rawImageCount = defaults.integerIfPresent(forKey: "rssDefaultImageCount") ?? 4
        self.rssDefaultImageCount = RSSSourceConfig.validImageCounts.contains(rawImageCount) ? rawImageCount : 4

        if let data = defaults.data(forKey: "rssSources"),
           let decoded = try? JSONDecoder().decode([RSSSourceConfig].self, from: data) {
            self.rssSources = Self.normalizedRSSSources(decoded)
        } else {
            self.rssSources = []
        }

        self.updateDevMode = defaults.bool(forKey: "updateDevMode")
        self.showAllAIModels = defaults.boolIfPresent(forKey: "showAllAIModels") ?? false
        if let data = defaults.data(forKey: "customAIProviders"),
           let decoded = try? JSONDecoder().decode([CustomAIProviderConfig].self, from: data) {
            self.customAIProviders = decoded
        } else {
            self.customAIProviders = []
        }

        self.hourlyPushEnabled = defaults.boolIfPresent(forKey: "hourlyPushEnabled") ?? false
        self.dailyPushEnabled = defaults.boolIfPresent(forKey: "dailyPushEnabled") ?? false
        self.pushCount = defaults.integerIfPresent(forKey: "pushCount") ?? 3
        self.dailyPushHour = defaults.integerIfPresent(forKey: "dailyPushHour") ?? 9
        self.dailyPushMinute = defaults.integerIfPresent(forKey: "dailyPushMinute") ?? 0

        self.burstPushEnabled = defaults.boolIfPresent(forKey: "burstPushEnabled") ?? false
        self.burstTestMode = defaults.boolIfPresent(forKey: "burstTestMode") ?? false
        self.burstTestTopic = defaults.stringIfPresent(forKey: "burstTestTopic") ?? ""
        self.burstTestWebSearchEnabled = defaults.boolIfPresent(forKey: "burstTestWebSearchEnabled") ?? false
        self.webSearchEnabled = defaults.boolIfPresent(forKey: "webSearchEnabled") ?? false
        self.firecrawlAPIKey = defaults.stringIfPresent(forKey: "firecrawlAPIKey") ?? ""
        let rawBurstCap = defaults.integerIfPresent(forKey: "burstDailyCap") ?? 20
        self.burstDailyCap = Self.validBurstCaps.contains(rawBurstCap) ? rawBurstCap : 20
        self.todayBurstResearchCount = defaults.integerIfPresent(forKey: "todayBurstResearchCount") ?? 0

        self.keywordTrackingEnabled = defaults.boolIfPresent(forKey: "keywordTrackingEnabled") ?? false
        self.keywordList = defaults.stringArray(forKey: "keywordList") ?? []

        self.isInitializing = false
        resetDailyStatsIfNeeded()
    }

    func migrateLegacyKeyIfNeeded() {
        Task {
            let store = EncryptedKeyStore()
            let newAccount = AIProvider.deepseek.apiKeyAccount()
            let newFlag = AIProvider.deepseek.keyExistsFlag()
            let accountFlag = "hasAIKey-\(newAccount)"

            guard UserDefaults.standard.bool(forKey: "hasDeepSeekAPIKey") else { return }

            if UserDefaults.standard.bool(forKey: newFlag) || UserDefaults.standard.bool(forKey: accountFlag) {
                UserDefaults.standard.set(true, forKey: newFlag)
                UserDefaults.standard.removeObject(forKey: "hasDeepSeekAPIKey")
                return
            }

            let exists = await store.checkAPIKeyExistence(account: newAccount)
            guard !exists else {
                UserDefaults.standard.removeObject(forKey: "hasDeepSeekAPIKey")
                return
            }

            guard let oldKey = KeychainManager.readLegacyAPIKey(), !oldKey.isEmpty else {
                UserDefaults.standard.removeObject(forKey: "hasDeepSeekAPIKey")
                return
            }

            if await store.saveAPIKey(oldKey, account: newAccount) {
                KeychainManager.deleteLegacyAPIKey()
                UserDefaults.standard.removeObject(forKey: "hasDeepSeekAPIKey")
                UserDefaults.standard.set(true, forKey: newFlag)
            }
        }
    }

    func loadStoredCredentialsIfNeeded() {
        guard onePasswordRef.isEmpty else { return }
        Task {
            let store = EncryptedKeyStore()
            if let ref = await store.readOnePasswordRef(), !ref.isEmpty {
                onePasswordRef = ref
            }
        }
    }

    private func saveRSSSources() {
        if let data = try? JSONEncoder().encode(rssSources) {
            UserDefaults.standard.set(data, forKey: "rssSources")
        }
    }

    static func normalizedRSSSources(_ sources: [RSSSourceConfig]) -> [RSSSourceConfig] {
        var seen = Set<String>()
        return sources.compactMap { source in
            var normalized = source
            normalized.url = SecurityPolicies.canonicalRSSURL(source.url)
            guard seen.insert(normalized.id).inserted else { return nil }
            return normalized
        }
    }

    private func saveCustomAIProviders() {
        if let data = try? JSONEncoder().encode(customAIProviders) {
            UserDefaults.standard.set(data, forKey: "customAIProviders")
        }
    }

    /// Persisted `aiProvider` uses `custom:<uuid>` to reference a custom provider.
    var selectedCustomProvider: CustomAIProviderConfig? {
        guard aiProvider.hasPrefix("custom:"),
              let uuid = aiProvider.split(separator: ":").last.map(String.init) else { return nil }
        return customAIProviders.first { $0.id == uuid }
    }

    var isUsingCustomProvider: Bool {
        selectedCustomProvider != nil
    }

    var resolvedAIConnection: ResolvedAIConnection {
        if let custom = selectedCustomProvider {
            return custom.resolvedConnection()
        }
        return currentProvider.resolvedConnection()
    }

    var currentAIModels: [String] {
        if let custom = selectedCustomProvider {
            return custom.effectiveModels
        }
        return currentProvider.models(showAll: showAllAIModels)
    }

    /// Encrypted-key account for the active provider. Custom providers store
    /// under `custom:<uuid>`, built-ins under `ai-key-<rawValue>`.
    var activeAPIKeyAccount: String {
        isUsingCustomProvider ? aiProvider : currentProvider.apiKeyAccount()
    }

    /// All selectable provider IDs (built-ins + custom), with display names.
    /// Built-in id is the raw `AIProvider` value; custom id is `custom:<uuid>`.
    var providerOptions: [(id: String, name: String)] {
        var options = AIProvider.allCases.map { ($0.rawValue, $0.displayName) }
        for custom in customAIProviders {
            options.append(("custom:\(custom.id)", custom.name))
        }
        return options
    }

    func customProvider(byID id: String) -> CustomAIProviderConfig? {
        guard id.hasPrefix("custom:") else { return nil }
        return customAIProviders.first { "custom:\($0.id)" == id }
    }

    func providerDefaultModel(forID id: String) -> String {
        if let custom = customProvider(byID: id) {
            return custom.effectiveModels.first ?? ""
        }
        return AIProvider(rawValue: id)?.defaultModel ?? ""
    }

    func providerModels(forID id: String) -> [String] {
        if let custom = customProvider(byID: id) {
            return custom.effectiveModels
        }
        return AIProvider(rawValue: id)?.models(showAll: showAllAIModels) ?? []
    }

    func providerDisplayName(forID id: String) -> String {
        if let custom = customProvider(byID: id) {
            return custom.name
        }
        return AIProvider(rawValue: id)?.displayName ?? id
    }

    func providerPricingInfo(forID id: String) -> [(title: String, detail: String)] {
        if let custom = customProvider(byID: id) {
            if let note = custom.pricingNote, !note.isEmpty {
                return [("计费方式", note)]
            }
            return [("计费方式", "定价未内置")]
        }
        return AIProvider(rawValue: id)?.pricingInfo ?? []
    }

    func providerApiKeyPlaceholder(forID id: String) -> String {
        if let custom = customProvider(byID: id) {
            return "输入 \(custom.name) API Key"
        }
        return AIProvider(rawValue: id)?.apiKeyPlaceholder ?? "输入 API Key"
    }

    func providerKeyRetrievalURL(forID id: String) -> String {
        if customProvider(byID: id) != nil {
            return "自定义端点，请在提供商处获取 Key"
        }
        return AIProvider(rawValue: id)?.keyRetrievalURL ?? ""
    }

    func providerOnePasswordHint(forID id: String) -> String {
        if let custom = customProvider(byID: id) {
            return "op://Private/\(custom.name.replacingOccurrences(of: " ", with: ""))/credential"
        }
        return AIProvider(rawValue: id)?.onePasswordHint ?? "op://Private/Provider/credential"
    }

    var activeSources: [NewsSource] {
        var sources: [NewsSource] = [.weibo, .bilibili]
        for rss in rssSources where selectedRSSSourceIDs.contains(rss.id) {
            sources.append(.rss(name: rss.name, url: rss.url))
        }
        return sources
    }

    /// Non-empty trimmed keywords, in a stable order.
    var activeKeywords: [String] {
        keywordList
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Returns true when the given title contains any active keyword.
    /// Matching is case-insensitive and diacritic-insensitive.
    func keywordMatches(_ title: String) -> Bool {
        let active = activeKeywords
        guard !active.isEmpty else { return false }
        let foldedTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        for keyword in active {
            let folded = keyword.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if foldedTitle.range(of: folded, options: [.caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    var estimatedAICostText: String {
        guard !isUsingCustomProvider else {
            return selectedCustomProvider?.pricingNote?.isEmpty == false
                ? (selectedCustomProvider?.pricingNote ?? "定价未内置")
                : "定价未内置"
        }
        return currentProvider.estimatedDailyCostText(model: aiModel, requestCount: todayAIRequestCount)
    }

    var aiUsageText: String {
        "\(todayAIRequestCount) / \(aiDailyCap) 次"
    }

    var aiPopupUsageText: String {
        let cap = effectiveDailyCap(for: .popup)
        return "\(todayPopupAIRequestCount) / \(cap) 次"
    }

    var aiDashboardUsageText: String {
        let cap = effectiveDailyCap(for: .dashboard)
        return "\(todayDashboardAIRequestCount) / \(cap) 次"
    }

    /// Returns the effective daily cap for a target based on the current budget mode.
    func effectiveDailyCap(for target: SummaryTarget) -> Int {
        switch aiBudgetMode {
        case .shared:       return aiDailyCap
        case .independent:
            switch target {
            case .popup:     return aiPopupDailyCap
            case .dashboard: return aiDashboardDailyCap
            }
        }
    }

    /// Returns the persisted daily count for a target.
    func todayAIRequestCount(for target: SummaryTarget) -> Int {
        switch target {
        case .popup:     return todayPopupAIRequestCount
        case .dashboard: return todayDashboardAIRequestCount
        }
    }

    /// Whitelisted daily AI request caps. Any value outside this set is rejected.
    static let validAICaps: Set<Int> = [20, 50, 100]
    /// Whitelisted burst-research daily caps. Any value outside this set is rejected.
    static let validBurstCaps: Set<Int> = [10, 20, 50]
    /// Whitelisted Popup AI summary lengths. Any value outside this set is rejected.
    static let validAIPopupMaxWords: Set<Int> = [80, 120, 160, 200]
    /// Whitelisted Dashboard AI summary lengths. Any value outside this set is rejected.
    static let validAIDashboardMaxWords: Set<Int> = [240, 360, 480, 600]

    func resetDailyStatsIfNeeded() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let savedDay = calendar.startOfDay(for: Date(timeIntervalSince1970: statsDayTimestamp))
        guard !calendar.isDate(savedDay, inSameDayAs: today) else { return }

        todayRefreshCount = 0
        todayAIRequestCount = 0
        todayPopupAIRequestCount = 0
        todayDashboardAIRequestCount = 0
        todayBurstResearchCount = 0
        statsDayTimestamp = today.timeIntervalSince1970
    }

    func recordRefresh() {
        resetDailyStatsIfNeeded()
        todayRefreshCount += 1
        lastRefreshTimestamp = Date().timeIntervalSince1970
    }

    func recordAIRequests(_ count: Int) {
        guard count > 0 else { return }
        resetDailyStatsIfNeeded()
        todayAIRequestCount += count
    }

    /// Target-aware recording: increments both the per-target count and the legacy total.
    func recordAIRequests(_ count: Int, for target: SummaryTarget) {
        guard count > 0 else { return }
        resetDailyStatsIfNeeded()
        todayAIRequestCount += count
        switch target {
        case .popup:     todayPopupAIRequestCount += count
        case .dashboard: todayDashboardAIRequestCount += count
        }
    }

    /// Stores the cumulative burst-research request count from the service's
    /// independent budget (kept separate from the shared AI-summary quota).
    func recordBurstResearchRequests(_ total: Int) {
        resetDailyStatsIfNeeded()
        todayBurstResearchCount = max(todayBurstResearchCount, total)
    }

    // MARK: - RSS display-count resolution

    func effectiveTextDisplayCount(for source: RSSSourceConfig) -> Int {
        if rssUnifiedDisplayCount {
            return RSSSourceConfig.validTextCounts.contains(rssDefaultTextCount) ? rssDefaultTextCount : 10
        }
        return source.effectiveTextCount(global: rssDefaultTextCount)
    }

    func effectiveImageDisplayCount(for source: RSSSourceConfig) -> Int {
        if rssUnifiedDisplayCount {
            return RSSSourceConfig.validImageCounts.contains(rssDefaultImageCount) ? rssDefaultImageCount : 4
        }
        return source.effectiveImageCount(global: rssDefaultImageCount)
    }
}

struct RSSSourceConfig: Identifiable, Hashable, Codable {
    var id: String { url }
    var name: String
    var url: String
    var displayMode: DisplayMode
    var supportsImage: Bool = true
    var textCountOverride: Int?
    var imageCountOverride: Int?

    init(name: String, url: String, displayMode: DisplayMode, supportsImage: Bool = true, textCountOverride: Int? = nil, imageCountOverride: Int? = nil) {
        self.name = name
        self.url = url
        self.displayMode = displayMode
        self.supportsImage = supportsImage
        self.textCountOverride = textCountOverride
        self.imageCountOverride = imageCountOverride
    }

    // CRITICAL: AppSettings decodes [RSSSourceConfig] with `try?` — a single throw
    // wipes the entire array. All fields must use safe decoding.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        displayMode = (try? c.decodeIfPresent(DisplayMode.self, forKey: .displayMode)) ?? .text
        supportsImage = (try? c.decodeIfPresent(Bool.self, forKey: .supportsImage)) ?? true
        textCountOverride = (try? c.decodeIfPresent(Int.self, forKey: .textCountOverride))
        imageCountOverride = (try? c.decodeIfPresent(Int.self, forKey: .imageCountOverride))
    }

    enum CodingKeys: String, CodingKey {
        case name, url, displayMode, supportsImage, textCountOverride, imageCountOverride
    }

    enum DisplayMode: String, CaseIterable, Codable {
        case text
        case image

        // MARK: - Codable migration (single→text, scroll→image, unknown→text)
        // CRITICAL: Never throw on unknown values — AppSettings decodes [RSSSourceConfig]
        // with `try?`, so a single throw wipes the entire array (all RSS sources lost).
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            switch raw {
            case "single", "text":   self = .text
            case "scroll", "image":  self = .image
            default:                 self = .text  // silent fallback
            }
        }
    }

    // MARK: - Display-count whitelist & effective-count helpers

    /// Whitelisted text display counts. Any value outside this set is rejected.
    static let validTextCounts: Set<Int> = [5, 10]
    /// Whitelisted image display counts. Any value outside this set is rejected.
    static let validImageCounts: Set<Int> = [4, 6, 8]

    func effectiveTextCount(global: Int) -> Int {
        if let override = textCountOverride, Self.validTextCounts.contains(override) {
            return override
        }
        if Self.validTextCounts.contains(global) {
            return global
        }
        return 10
    }

    func effectiveImageCount(global: Int) -> Int {
        if let override = imageCountOverride, Self.validImageCounts.contains(override) {
            return override
        }
        if Self.validImageCounts.contains(global) {
            return global
        }
        return 4
    }
}

extension UserDefaults {
    func integerIfPresent(forKey key: String) -> Int? {
        guard object(forKey: key) != nil else { return nil }
        return integer(forKey: key)
    }

    func boolIfPresent(forKey key: String) -> Bool? {
        guard object(forKey: key) != nil else { return nil }
        return bool(forKey: key)
    }

    func stringIfPresent(forKey key: String) -> String? {
        return string(forKey: key)
    }

    func doubleIfPresent(forKey key: String) -> Double? {
        guard object(forKey: key) != nil else { return nil }
        return double(forKey: key)
    }
}
