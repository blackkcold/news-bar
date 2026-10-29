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
    var readerCookieMemoryEnabled: Bool {
        didSet { UserDefaults.standard.set(readerCookieMemoryEnabled, forKey: "readerCookieMemoryEnabled") }
    }
    var readerHistoryEnabled: Bool {
        didSet { UserDefaults.standard.set(readerHistoryEnabled, forKey: "readerHistoryEnabled") }
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
    /// Daily AI call cap for the whole app. `-1` means unlimited. The gate
    /// always works through `aiQuotaPolicy`, never through this raw value.
    var aiDailyCap: Int {
        didSet { UserDefaults.standard.set(aiDailyCap, forKey: "aiDailyCap") }
    }
    /// Active limit style: call count or money budget. Exactly one applies.
    var aiLimitMode: AILimitMode {
        didSet { UserDefaults.standard.set(aiLimitMode.rawValue, forKey: "aiLimitMode") }
    }
    /// Money budget in micros of the display currency. Read only in `.cost` mode.
    var aiCostCapMicros: Int64 {
        didSet { UserDefaults.standard.set(aiCostCapMicros, forKey: "aiCostCapMicros") }
    }
    /// Transient: false when today's quota record cannot be read. The UI says
    /// so instead of painting a fake zero.
    var aiUsageAvailable = true
    /// Transient mirrors of today's quota ledger. They exist so SwiftUI can
    /// re-render; the ledger stays the single authority.
    var todayAICostMicros: Int64 = 0
    var todayAIUnpricedCalls = 0
    var todayAIInputTokens = 0
    var todayAIOutputTokens = 0
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
            invalidateModelCatalog(clearSelection: true)
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
        didSet {
            saveCustomAIProviders()
            guard !isInitializing else { return }
            let old = oldValue.first { "custom:\($0.id)" == aiProvider }
            if old != selectedCustomProvider { invalidateModelCatalog(clearSelection: true) }
        }
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
    /// Master toggle for automatic research records (burst detection). Manual
    /// verification from a news item always remains available.
    var researchAutoEnabled: Bool {
        didSet { UserDefaults.standard.set(researchAutoEnabled, forKey: "researchAutoEnabled") }
    }
    /// Maximum new burst topics enqueued per refresh round.
    var researchDetectionLimit: Int {
        didSet { UserDefaults.standard.set(researchDetectionLimit, forKey: "researchDetectionLimit") }
    }
    /// Shows the compact research entry above the popover feed.
    var researchShowPopoverChip: Bool {
        didSet { UserDefaults.standard.set(researchShowPopoverChip, forKey: "researchShowPopoverChip") }
    }
    /// Opening a finished research record clears its unread marker. Active runs
    /// never do. Turning this off keeps the unread badge until a manual mark.
    var researchMarkReadOnOpen: Bool {
        didSet { UserDefaults.standard.set(researchMarkReadOnOpen, forKey: "researchMarkReadOnOpen") }
    }
    /// Lets the local interest profile add non-burst topics to automatic
    /// research. Effective only while local learning is enabled.
    var researchUsePersonalization: Bool {
        didSet { UserDefaults.standard.set(researchUsePersonalization, forKey: "researchUsePersonalization") }
    }
    /// Read-only mirror of the last automatic selection result. Written by the
    /// orchestrator so settings can explain a skipped hour; never persisted as
    /// a preference.
    private(set) var researchLastAutomaticDecision: String?

    func updateResearchLastAutomaticDecision(_ text: String?) {
        researchLastAutomaticDecision = text
        if let text {
            UserDefaults.standard.set(text, forKey: "researchLastAutomaticDecision")
        } else {
            UserDefaults.standard.removeObject(forKey: "researchLastAutomaticDecision")
        }
    }
    /// Shows the one-sentence summary in the completion notification. Turning
    /// it off keeps the report title but hides the conclusion from the lock
    /// screen.
    var researchNotificationShowsSummary: Bool {
        didSet {
            UserDefaults.standard.set(
                researchNotificationShowsSummary,
                forKey: "researchNotificationShowsSummary"
            )
        }
    }
    /// Research depth preset (quick / standard / deep).
    var researchDepth: ResearchDepth {
        didSet { UserDefaults.standard.set(researchDepth.rawValue, forKey: "researchDepth") }
    }
    /// Shared daily task cap, counted across origins.
    var researchDailyTaskCap: Int {
        didSet { UserDefaults.standard.set(researchDailyTaskCap, forKey: "researchDailyTaskCap") }
    }
    /// Maximum research tasks running at once.
    var researchMaxConcurrent: Int {
        didSet { UserDefaults.standard.set(researchMaxConcurrent, forKey: "researchMaxConcurrent") }
    }
    /// Default time window; `auto` derives it from the seed's publish date.
    var researchDefaultRecency: ResearchDefaultRecency {
        didSet { UserDefaults.standard.set(researchDefaultRecency.rawValue, forKey: "researchDefaultRecency") }
    }
    /// Enabled search providers, stored as raw values (Tavily → Firecrawl → Brave).
    var researchSearchProviders: [String] {
        didSet {
            UserDefaults.standard.set(researchSearchProviders, forKey: "researchSearchProviders")
        }
    }
    var researchHistoryLimit: Int {
        didSet { UserDefaults.standard.set(researchHistoryLimit, forKey: "researchHistoryLimit") }
    }
    var researchRetentionDays: Int {
        didSet { UserDefaults.standard.set(researchRetentionDays, forKey: "researchRetentionDays") }
    }
    var researchTempCacheMB: Int {
        didSet { UserDefaults.standard.set(researchTempCacheMB, forKey: "researchTempCacheMB") }
    }
    var researchTempCacheTTLHours: Int {
        didSet { UserDefaults.standard.set(researchTempCacheTTLHours, forKey: "researchTempCacheTTLHours") }
    }
    var researchConsentVersion: Int {
        didSet { UserDefaults.standard.set(researchConsentVersion, forKey: "researchConsentVersion") }
    }
    /// Enables the developer test-mode toggle that fires a fake burst push.
    var burstTestMode: Bool {
        didSet { UserDefaults.standard.set(burstTestMode, forKey: "burstTestMode") }
    }
    /// The user-entered hot-search title used by the burst test push.
    var burstTestTopic: String {
        didSet { UserDefaults.standard.set(burstTestTopic, forKey: "burstTestTopic") }
    }
    /// Legacy Firecrawl key, kept only for the one-time migration into the
    /// encrypted store. New values are never written back as plaintext;
    /// clearing the property removes any leftover legacy value.
    var firecrawlAPIKey: String {
        didSet {
            guard firecrawlAPIKey.isEmpty else { return }
            UserDefaults.standard.removeObject(forKey: "firecrawlAPIKey")
        }
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

    @ObservationIgnored var cachedAPIKey: String? {
        didSet {
            if !isInitializing, cachedAPIKey != oldValue { invalidateModelCatalog(clearSelection: false) }
        }
    }
    private let modelService: ProviderModelService
    private(set) var availableProviderModels: [ProviderModel] = []
    private(set) var modelCatalogProviderID: String?
    private(set) var modelCatalogUpdatedAt: Date?
    private(set) var modelCatalogError: ProviderModelError?
    private(set) var isLoadingModelCatalog = false
    private(set) var modelCatalogIsStale = false
    private(set) var modelCatalogRevision = UUID()
    private var modelCatalogIdentity: String?
    private var isInitializing = true
    /// A personal-data reset removes every derived artifact, including the
    /// last automatic topic shown in settings. The notification is posted on
    /// the main actor by InterestController.
    @ObservationIgnored private var interestDataClearedObserver: NSObjectProtocol?

    var currentProvider: AIProvider {
        AIProvider(rawValue: aiProvider) ?? .deepseek
    }

    init(modelService: ProviderModelService = .shared) {
        self.modelService = modelService
        let defaults = UserDefaults.standard

        self.autoRefreshEnabled = defaults.boolIfPresent(forKey: "autoRefreshEnabled") ?? false
        self.launchAtLogin = defaults.boolIfPresent(forKey: "launchAtLogin") ?? false
        self.colorScheme = defaults.stringIfPresent(forKey: "colorScheme") ?? "system"
        self.appTheme = AppTheme(rawValue: defaults.stringIfPresent(forKey: "appTheme") ?? "") ?? .modern
        let language = AppLanguage(rawValue: defaults.stringIfPresent(forKey: "appLanguage") ?? "") ?? .zh
        self.appLanguage = language
        L10n.currentLanguage = language
        self.rssTitleTranslationEnabled = defaults.boolIfPresent(forKey: "rssTitleTranslationEnabled") ?? false
        self.readerCookieMemoryEnabled = defaults.boolIfPresent(forKey: "readerCookieMemoryEnabled") ?? true
        self.readerHistoryEnabled = defaults.boolIfPresent(forKey: "readerHistoryEnabled") ?? true
        self.aiSummaryEnabled = defaults.boolIfPresent(forKey: "aiSummaryEnabled") ?? false
        self.aiProvider = defaults.stringIfPresent(forKey: "aiProvider") ?? "deepseek"

        // Persisted selections are historical until the provider's real catalog
        // validates them. Never migrate to another hard-coded model ID.
        self.aiModel = defaults.stringIfPresent(forKey: "aiModel") ?? ""

        let rawPopupMaxWords = defaults.integerIfPresent(forKey: "aiPopupMaxWords") ?? 120
        self.aiPopupMaxWords = Self.validAIPopupMaxWords.contains(rawPopupMaxWords) ? rawPopupMaxWords : 120
        let rawDashboardMaxWords = defaults.integerIfPresent(forKey: "aiDashboardMaxWords") ?? 360
        self.aiDashboardMaxWords = Self.validAIDashboardMaxWords.contains(rawDashboardMaxWords) ? rawDashboardMaxWords : 360
        self.aiMaxWords = defaults.integerIfPresent(forKey: "aiMaxWords") ?? 150
        let rawCap = defaults.integerIfPresent(forKey: "aiDailyCap") ?? 200
        self.aiDailyCap = Self.migratedAICap(rawCap)
        let rawLimitMode = defaults.stringIfPresent(forKey: "aiLimitMode") ?? AILimitMode.count.rawValue
        self.aiLimitMode = AILimitMode(rawValue: rawLimitMode) ?? .count
        self.aiCostCapMicros = defaults.int64IfPresent(forKey: "aiCostCapMicros")
            ?? Self.defaultAICostCapMicros
        let rawBudgetMode = defaults.stringIfPresent(forKey: "aiBudgetMode") ?? AISummaryBudgetMode.shared.rawValue
        self.aiBudgetMode = AISummaryBudgetMode(rawValue: rawBudgetMode) ?? .shared
        self.aiDisableDeepSeekThinking = defaults.boolIfPresent(forKey: "aiDisableDeepSeekThinking") ?? true
        let rawPopupCap = defaults.integerIfPresent(forKey: "aiPopupDailyCap") ?? 200
        self.aiPopupDailyCap = Self.validAICaps.contains(rawPopupCap) ? rawPopupCap : 200
        let rawDashboardCap = defaults.integerIfPresent(forKey: "aiDashboardDailyCap") ?? 200
        self.aiDashboardDailyCap = Self.validAICaps.contains(rawDashboardCap) ? rawDashboardCap : 200
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
        self.pushCount = min(max(defaults.integerIfPresent(forKey: "pushCount") ?? 3, 1), 3)
        self.dailyPushHour = defaults.integerIfPresent(forKey: "dailyPushHour") ?? 9
        self.dailyPushMinute = defaults.integerIfPresent(forKey: "dailyPushMinute") ?? 0

        self.burstPushEnabled = defaults.boolIfPresent(forKey: "burstPushEnabled") ?? false
        self.researchAutoEnabled = defaults.boolIfPresent(forKey: "researchAutoEnabled") ?? true
        let rawDetectionLimit = defaults.integerIfPresent(forKey: "researchDetectionLimit") ?? 3
        self.researchDetectionLimit = Self.validResearchDetectionLimits.contains(rawDetectionLimit) ? rawDetectionLimit : 3
        self.researchShowPopoverChip = defaults.boolIfPresent(forKey: "researchShowPopoverChip") ?? true
        self.researchMarkReadOnOpen = defaults.boolIfPresent(forKey: "researchMarkReadOnOpen") ?? true
        self.researchUsePersonalization = defaults.boolIfPresent(forKey: "researchUsePersonalization") ?? true
        self.researchLastAutomaticDecision = defaults.stringIfPresent(forKey: "researchLastAutomaticDecision")
        self.researchNotificationShowsSummary = defaults.boolIfPresent(forKey: "researchNotificationShowsSummary") ?? true
        let rawDepth = defaults.stringIfPresent(forKey: "researchDepth") ?? ResearchDepth.standard.rawValue
        self.researchDepth = ResearchDepth(rawValue: rawDepth) ?? .standard
        let rawResearchTaskCap = defaults.integerIfPresent(forKey: "researchDailyTaskCap") ?? 3
        self.researchDailyTaskCap = Self.validResearchDailyTaskCaps.contains(rawResearchTaskCap) ? rawResearchTaskCap : 3
        let rawResearchConcurrency = defaults.integerIfPresent(forKey: "researchMaxConcurrent") ?? 1
        self.researchMaxConcurrent = Self.validResearchConcurrency.contains(rawResearchConcurrency) ? rawResearchConcurrency : 1
        let rawRecency = defaults.stringIfPresent(forKey: "researchDefaultRecency") ?? ResearchDefaultRecency.auto.rawValue
        self.researchDefaultRecency = ResearchDefaultRecency(rawValue: rawRecency) ?? .auto
        let rawProviders = defaults.stringArray(forKey: "researchSearchProviders")
            ?? SearchProviderID.failoverOrder
                .filter { $0.authMode != .requiredKey }
                .map(\.rawValue)
        self.researchSearchProviders = Self.normalizedSearchProviders(rawProviders)
        let rawHistoryLimit = defaults.integerIfPresent(forKey: "researchHistoryLimit") ?? 200
        self.researchHistoryLimit = Self.validResearchHistoryLimits.contains(rawHistoryLimit) ? rawHistoryLimit : 200
        let rawRetention = defaults.integerIfPresent(forKey: "researchRetentionDays") ?? 90
        self.researchRetentionDays = Self.validResearchRetentionDays.contains(rawRetention) ? rawRetention : 90
        let rawCacheMB = defaults.integerIfPresent(forKey: "researchTempCacheMB") ?? 300
        self.researchTempCacheMB = Self.validResearchTempCacheMB.contains(rawCacheMB) ? rawCacheMB : 300
        let rawCacheTTL = defaults.integerIfPresent(forKey: "researchTempCacheTTLHours") ?? 72
        self.researchTempCacheTTLHours = Self.validResearchTempCacheTTL.contains(rawCacheTTL) ? rawCacheTTL : 72
        self.researchConsentVersion = defaults.integerIfPresent(forKey: "researchConsentVersion") ?? 0
        self.burstTestMode = defaults.boolIfPresent(forKey: "burstTestMode") ?? false
        self.burstTestTopic = defaults.stringIfPresent(forKey: "burstTestTopic") ?? ""
        self.firecrawlAPIKey = defaults.stringIfPresent(forKey: "firecrawlAPIKey") ?? ""
        let rawBurstCap = defaults.integerIfPresent(forKey: "burstDailyCap") ?? 20
        self.burstDailyCap = Self.validBurstCaps.contains(rawBurstCap) ? rawBurstCap : 20
        self.todayBurstResearchCount = defaults.integerIfPresent(forKey: "todayBurstResearchCount") ?? 0

        self.keywordTrackingEnabled = defaults.boolIfPresent(forKey: "keywordTrackingEnabled") ?? false
        self.keywordList = defaults.stringArray(forKey: "keywordList") ?? []

        self.isInitializing = false
        resetDailyStatsIfNeeded()
        interestDataClearedObserver = NotificationCenter.default.addObserver(
            forName: .interestDataCleared,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.updateResearchLastAutomaticDecision(nil)
        }
    }

    deinit {
        if let interestDataClearedObserver {
            NotificationCenter.default.removeObserver(interestDataClearedObserver)
        }
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
        providerModels(forID: aiProvider)
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
        guard modelCatalogProviderID == id else { return "" }
        return ProviderModelSelection.preferred(in: availableProviderModels, current: nil) ?? ""
    }

    func providerModels(forID id: String) -> [String] {
        guard modelCatalogProviderID == id else { return [] }
        let ordered = ProviderModelSelection.ordered(availableProviderModels)
        let deepseek = ordered.filter { ProviderModelSelection.isDeepSeek($0.id) }
        let visible = !showAllAIModels && !deepseek.isEmpty ? deepseek : ordered
        var ids = visible.map(\.id)
        if ordered.contains(where: { $0.id == aiModel }), !ids.contains(aiModel) { ids.append(aiModel) }
        return ids
    }

    var canUseCurrentAIModel: Bool {
        guard modelCatalogProviderID == aiProvider,
              let updated = modelCatalogUpdatedAt, Date().timeIntervalSince(updated) <= 24 * 3600,
              modelCatalogIdentity == ProviderModelService.identity(providerID: aiProvider, connection: resolvedAIConnection, apiKey: cachedAPIKey ?? "") else { return false }
        return availableProviderModels.contains { $0.id == aiModel }
    }

    @discardableResult
    func activateAPIKey(_ key: String, providerID: String, revision: UUID) -> Bool {
        guard providerID == aiProvider, revision == modelCatalogRevision else { return false }
        cachedAPIKey = key
        return true
    }

    @MainActor
    func validatedAIConfiguration(apiKey: String) async -> ValidatedAIConfiguration? {
        guard await refreshModelCatalog(apiKey: apiKey), canUseCurrentAIModel else { return nil }
        return ValidatedAIConfiguration(providerID: aiProvider, connection: resolvedAIConnection,
                                        model: aiModel, apiKey: apiKey, revision: modelCatalogRevision)
    }

    func isCurrentAIConfiguration(_ configuration: ValidatedAIConfiguration) -> Bool {
        canUseCurrentAIModel && configuration.revision == modelCatalogRevision
            && configuration.providerID == aiProvider && configuration.model == aiModel
            && configuration.apiKey == cachedAPIKey
    }

    /// A connection test must not activate an unsaved credential or make a
    /// billable generation request. Stale results are returned as stale.
    @MainActor
    func checkModelConnection(apiKey: String) async throws -> ProviderModelResult {
        let revision = modelCatalogRevision
        let result = try await modelService.catalog(providerID: aiProvider, connection: resolvedAIConnection, apiKey: apiKey, force: true)
        guard revision == modelCatalogRevision else { throw CancellationError() }
        return result
    }

    private func invalidateModelCatalog(clearSelection: Bool) {
        modelCatalogRevision = UUID()
        modelCatalogIdentity = nil
        modelCatalogProviderID = nil
        availableProviderModels = []
        modelCatalogUpdatedAt = nil
        modelCatalogError = nil
        modelCatalogIsStale = false
        isLoadingModelCatalog = false
        if clearSelection { aiModel = "" }
    }

    /// Called on provider/key changes and before paid generation. Listing is
    /// metadata-only and never triggers a summary or research request itself.
    @MainActor
    @discardableResult
    func refreshModelCatalog(apiKey providedKey: String? = nil, force: Bool = false) async -> Bool {
        let provider = aiProvider
        let startingRevision = modelCatalogRevision
        let connection = resolvedAIConnection
        var key = providedKey ?? cachedAPIKey ?? ""
        if key.isEmpty, provider != AIProvider.ollamaCloud.rawValue {
            let account = activeAPIKeyAccount
            key = await EncryptedKeyStore().readAPIKey(account: account) ?? ""
            guard provider == aiProvider, startingRevision == modelCatalogRevision else { return false }
        }
        guard provider == AIProvider.ollamaCloud.rawValue || !key.isEmpty else {
            modelCatalogError = .unauthorized
            return false
        }
        if !key.isEmpty, cachedAPIKey != key { cachedAPIKey = key }
        let revision = modelCatalogRevision
        let identity = ProviderModelService.identity(providerID: provider, connection: connection, apiKey: key)
        isLoadingModelCatalog = true
        modelCatalogError = nil
        do {
            let result = try await modelService.catalog(providerID: provider, connection: connection, apiKey: key, force: force)
            guard revision == modelCatalogRevision, provider == aiProvider,
                  identity == ProviderModelService.identity(providerID: aiProvider, connection: resolvedAIConnection, apiKey: cachedAPIKey ?? "") else { return false }
            modelCatalogProviderID = provider
            modelCatalogIdentity = identity
            availableProviderModels = result.snapshot.models
            modelCatalogUpdatedAt = result.snapshot.fetchedAt
            modelCatalogIsStale = result.source == .stale
            modelCatalogError = result.refreshError
            isLoadingModelCatalog = false
            aiModel = ProviderModelSelection.preferred(in: result.snapshot.models, current: aiModel) ?? ""
            return canUseCurrentAIModel
        } catch {
            guard revision == modelCatalogRevision, provider == aiProvider else { return false }
            let failure = error as? ProviderModelError ?? .network
            availableProviderModels = []
            modelCatalogIdentity = nil
            modelCatalogProviderID = nil
            modelCatalogUpdatedAt = nil
            modelCatalogError = failure
            modelCatalogIsStale = false
            isLoadingModelCatalog = false
            if failure.invalidatesCache { aiModel = "" }
            return false
        }
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
        return active.contains { TitleFeatures.matches($0, in: title) }
    }

    /// Today's estimated spend. A dash means the ledger is unreadable; a
    /// suffix marks the value when some calls could not be priced.
    var estimatedAICostText: String {
        guard aiUsageAvailable else { return "—" }
        let value = AICostFormat.yuan(todayAICostMicros)
        return todayAIUnpricedCalls > 0
            ? L10n.string("general.estimatedAICostPartial", value)
            : value
    }

    var aiUsageText: String {
        if let cap = aiCountLimit {
            return L10n.string("ai.usage.value", todayAIRequestCount, cap)
        }
        return L10n.string("ai.usage.unlimitedValue", todayAIRequestCount)
    }
    /// `nil` means unlimited.
    var aiCountLimit: Int? {
        aiDailyCap < 0 ? nil : aiDailyCap
    }

    /// Immutable limit handed to the service layer. Exactly one cap is active.
    var aiQuotaPolicy: AIQuotaPolicy {
        let mode = effectiveAILimitMode
        return AIQuotaPolicy(
            mode: mode,
            countCap: mode == .count ? aiCountLimit : nil,
            costCapMicros: mode == .cost ? max(0, aiCostCapMicros) : nil
        )
    }

    /// Unit price for the active provider and model, if one is known.
    var currentModelPrice: ModelPrice? {
        if let custom = selectedCustomProvider {
            return custom.unitPrice
        }
        guard !aiModel.isEmpty else { return nil }
        return AIPriceCatalog.price(for: currentProvider.rawValue, model: aiModel)
    }

    /// Money mode is only meaningful when the active model can be priced.
    var aiCostEstimateAvailable: Bool {
        currentModelPrice != nil
    }

    /// The mode actually enforced. A stale `.cost` choice with no price falls
    /// back to the count limit instead of silently never blocking.
    var effectiveAILimitMode: AILimitMode {
        aiLimitMode == .cost && aiCostEstimateAvailable ? .cost : .count
    }

    /// Typical summary call: 1500 input / 1000 output tokens.
    var estimatedAICostPerCallMicros: Int64? {
        guard let price = currentModelPrice else { return nil }
        return AICostEstimator.reserveMicros(
            inputTokens: 1_500,
            maxOutputTokens: 1_000,
            price: price
        )
    }

    var aiCostUsageText: String {
        "\(AICostFormat.yuan(todayAICostMicros)) / \(AICostFormat.yuan(aiCostCapMicros))"
    }

    /// Mirrors the quota ledger into observable settings. The ledger is the
    /// authority; this value exists only so SwiftUI re-renders.
    func refreshAIUsageMirror(at date: Date = Date()) {
        let snapshot = AIQuotaStore.shared.snapshot(at: date)
        aiUsageAvailable = snapshot.isUsable
        guard snapshot.isUsable else { return }
        todayAIRequestCount = snapshot.count
        todayAICostMicros = snapshot.costMicros
        todayAIUnpricedCalls = snapshot.unpricedCalls
        todayAIInputTokens = snapshot.inputTokens
        todayAIOutputTokens = snapshot.outputTokens
    }

    var aiPopupUsageText: String {
        let cap = effectiveDailyCap(for: .popup)
        guard cap >= 0 else {
            return L10n.string("ai.usage.unlimitedValue", todayPopupAIRequestCount)
        }
        return "\(todayPopupAIRequestCount) / \(cap) 次"
    }

    var aiDashboardUsageText: String {
        let cap = effectiveDailyCap(for: .dashboard)
        guard cap >= 0 else {
            return L10n.string("ai.usage.unlimitedValue", todayDashboardAIRequestCount)
        }
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

    /// Whitelisted daily AI call caps. `-1` means unlimited. Any value outside
    /// this set is migrated to the entry tier.
    static let validAICaps: Set<Int> = [-1, 200, 500]
    /// Default money budget: ¥5.00/day.
    static let defaultAICostCapMicros: Int64 = 5_000_000
    /// v2.8 and earlier offered 20 / 50 / 100. Those values map to the new
    /// entry tier; a value already in the new set is preserved.
    static func migratedAICap(_ raw: Int) -> Int {
        validAICaps.contains(raw) ? raw : 200
    }
    /// Whitelisted burst-research daily caps. Any value outside this set is rejected.
    static let validBurstCaps: Set<Int> = [10, 20, 50]
    /// Whitelisted automatic-detection limits.
    static let validResearchDetectionLimits: Set<Int> = [1, 2, 3, 5]
    /// Whitelisted research execution limits.
    static let validResearchDailyTaskCaps: Set<Int> = [1, 2, 3, 5, 10]
    static let validResearchConcurrency: Set<Int> = [1, 2, 3]
    static let validResearchHistoryLimits: Set<Int> = [50, 100, 200, 500, 1000]
    static let validResearchRetentionDays: Set<Int> = [7, 30, 90, 180, 0]
    static let validResearchTempCacheMB: Set<Int> = [100, 250, 300, 500, 1000]
    static let validResearchTempCacheTTL: Set<Int> = [24, 72, 168]

    /// Keeps only known providers in canonical order. An empty list is a valid
    /// choice: research degrades to AI-only and is labelled "offline".
    static func normalizedSearchProviders(_ raw: [String]) -> [String] {
        let enabled = Set(raw)
        return SearchProviderID.allCases
            .map(\.rawValue)
            .filter { enabled.contains($0) }
    }

    var enabledSearchProviders: Set<SearchProviderID> {
        Set(researchSearchProviders.compactMap(SearchProviderID.init(rawValue:)))
    }
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

    func int64IfPresent(forKey key: String) -> Int64? {
        guard let value = object(forKey: key) as? NSNumber else { return nil }
        return value.int64Value
    }
}
