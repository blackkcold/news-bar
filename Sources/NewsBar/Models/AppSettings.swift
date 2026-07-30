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
        self.selectedRSSSourceIDs = Set(selectedIDs)

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
            self.rssSources = decoded
        } else {
            self.rssSources = []
        }

        self.updateDevMode = defaults.bool(forKey: "updateDevMode")

        self.hourlyPushEnabled = defaults.boolIfPresent(forKey: "hourlyPushEnabled") ?? false
        self.dailyPushEnabled = defaults.boolIfPresent(forKey: "dailyPushEnabled") ?? false
        self.pushCount = defaults.integerIfPresent(forKey: "pushCount") ?? 3
        self.dailyPushHour = defaults.integerIfPresent(forKey: "dailyPushHour") ?? 9
        self.dailyPushMinute = defaults.integerIfPresent(forKey: "dailyPushMinute") ?? 0

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

    var activeSources: [NewsSource] {
        var sources: [NewsSource] = [.weibo, .bilibili]
        for rss in rssSources where selectedRSSSourceIDs.contains(rss.id) {
            sources.append(.rss(name: rss.name, url: rss.url))
        }
        return sources
    }

    var estimatedAICostText: String {
        currentProvider.estimatedDailyCostText(model: aiModel, requestCount: todayAIRequestCount)
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
