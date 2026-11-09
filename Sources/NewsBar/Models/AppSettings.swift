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

struct AISummaryEnablementRevision {
    private(set) var value = UUID()

    mutating func noteChange(from oldValue: Bool, to newValue: Bool) {
        if oldValue != newValue { value = UUID() }
    }

    func isCurrent(_ started: UUID, enabled: Bool) -> Bool {
        enabled && started == value
    }
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

/// How selected-text explanations reach the web.
///
/// Offline is the default: a selection is often private, and a look-up turns
/// one call into a search plus page reads. Auto lets the model decide, and
/// always is an explicit opt-in.
enum SelectionWebMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case offline
    case auto
    case always

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        L10n.string("settings.selectionWeb.\(rawValue)", language: language)
    }

    func detail(_ language: AppLanguage) -> String {
        L10n.string("settings.selectionWeb.\(rawValue).detail", language: language)
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

struct AIKeyContext: Equatable {
    let providerID: String
    let account: String
    let revision: UUID
    let endpointIdentity: String?

    var inputContext: AICredentialInputContext {
        AICredentialInputContext(providerID: providerID, endpointIdentity: endpointIdentity)
    }

    init(providerID: String, account: String, revision: UUID, endpointIdentity: String? = nil) {
        self.providerID = providerID
        self.account = account
        self.revision = revision
        self.endpointIdentity = endpointIdentity
    }
}

struct AICredentialInputContext: Equatable {
    let providerID: String
    let endpointIdentity: String?
}

struct AICredentialUIContext: Equatable {
    let keyContext: AIKeyContext
    let intent: UUID
}

struct ProviderBoundKey: Equatable {
    let key: String
    let context: AIKeyContext
}

/// Prevents a pending credential write or deletion from racing a fresh read.
struct AIKeyMutationGate {
    private var pending: [String: Set<UUID>] = [:]

    mutating func begin(account: String, token: UUID) {
        pending[account, default: []].insert(token)
    }

    mutating func finish(account: String, token: UUID) {
        pending[account]?.remove(token)
        if pending[account]?.isEmpty == true { pending[account] = nil }
    }

    func isPending(account: String) -> Bool {
        !(pending[account]?.isEmpty ?? true)
    }
}

@MainActor
enum AIKeyAccess {
    nonisolated static func mayUseCachedKey(context: AIKeyContext, cachedEndpointIdentity: String?) -> Bool {
        guard context.providerID.hasPrefix("custom:") else { return true }
        guard let identity = context.endpointIdentity else { return false }
        return cachedEndpointIdentity == identity
    }

    /// A result captured before a provider change or credential mutation must
    /// not be published into the settings UI after that change completes.
    static func readForPresentation<Value>(
        isCurrent: () -> Bool,
        read: () async -> Value
    ) async -> Value? {
        guard !Task.isCancelled, isCurrent() else { return nil }
        let result = await read()
        guard !Task.isCancelled, isCurrent() else { return nil }
        return result
    }

    static func read(
        started: AIKeyContext,
        current: () -> AIKeyContext,
        read: (String) async -> EncryptedKeyStore.ReadResult,
        activate: (String) -> Bool
    ) async throws -> ProviderBoundKey {
        let result = await read(started.account)
        try Task.checkCancellation()
        guard current() == started else { throw AISearchError.configurationChanged }
        let key: String
        switch result {
        case let .found(value): key = value
        case .missing: key = ""
        case .failed: throw AISearchError.keyReadFailed
        }
        guard !key.isEmpty else { return ProviderBoundKey(key: "", context: started) }
        guard activate(key) else { throw AISearchError.configurationChanged }
        let activatedContext = current()
        guard activatedContext.providerID == started.providerID,
              activatedContext.account == started.account,
              activatedContext.endpointIdentity == started.endpointIdentity else { throw AISearchError.configurationChanged }
        return ProviderBoundKey(key: key, context: activatedContext)
    }

    static func isCurrent(_ bound: ProviderBoundKey, context: AIKeyContext, cachedKey: String?) -> Bool {
        bound.context == context && bound.key == (cachedKey ?? "")
    }
}

@Observable
final class AppSettings {
    var autoRefreshEnabled: Bool {
        didSet { TestIsolation.defaults.set(autoRefreshEnabled, forKey: "autoRefreshEnabled") }
    }
    var launchAtLogin: Bool {
        didSet { TestIsolation.defaults.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    // MARK: - Weibo monitor
    // The account list itself lives in WeiboMonitor/monitor.json; these are
    // only the global preferences. `launchAtLogin` is shared with the general
    // tab so there is never a second, conflicting "start at login" switch.
    var weiboMonitorEnabled: Bool {
        didSet { TestIsolation.defaults.set(weiboMonitorEnabled, forKey: "weiboMonitorEnabled") }
    }
    var weiboMonitorNotifyEnabled: Bool {
        didSet { TestIsolation.defaults.set(weiboMonitorNotifyEnabled, forKey: "weiboMonitorNotifyEnabled") }
    }
    var weiboMonitorP0Seconds: Int {
        didSet { TestIsolation.defaults.set(weiboMonitorP0Seconds, forKey: "weiboMonitorP0Seconds") }
    }
    var weiboMonitorP1Seconds: Int {
        didSet { TestIsolation.defaults.set(weiboMonitorP1Seconds, forKey: "weiboMonitorP1Seconds") }
    }
    var weiboMonitorP2Seconds: Int {
        didSet { TestIsolation.defaults.set(weiboMonitorP2Seconds, forKey: "weiboMonitorP2Seconds") }
    }
    var weiboMonitorNightEnabled: Bool {
        didSet { TestIsolation.defaults.set(weiboMonitorNightEnabled, forKey: "weiboMonitorNightEnabled") }
    }
    var weiboMonitorNightStartMinute: Int {
        didSet { TestIsolation.defaults.set(weiboMonitorNightStartMinute, forKey: "weiboMonitorNightStartMinute") }
    }
    var weiboMonitorNightEndMinute: Int {
        didSet { TestIsolation.defaults.set(weiboMonitorNightEndMinute, forKey: "weiboMonitorNightEndMinute") }
    }
    var weiboMonitorPerAccountHourlyCap: Int {
        didSet { TestIsolation.defaults.set(weiboMonitorPerAccountHourlyCap, forKey: "weiboMonitorPerAccountHourlyCap") }
    }
    var weiboMonitorGlobalHourlyCap: Int {
        didSet { TestIsolation.defaults.set(weiboMonitorGlobalHourlyCap, forKey: "weiboMonitorGlobalHourlyCap") }
    }
    var weiboMonitorKeywordNotifyEnabled: Bool {
        didSet { TestIsolation.defaults.set(weiboMonitorKeywordNotifyEnabled, forKey: "weiboMonitorKeywordNotifyEnabled") }
    }
    var weiboMonitorKeywordList: [String] {
        didSet { TestIsolation.defaults.set(weiboMonitorKeywordList, forKey: "weiboMonitorKeywordList") }
    }
    var weiboMonitorBackfillHours: Int {
        didSet { TestIsolation.defaults.set(weiboMonitorBackfillHours, forKey: "weiboMonitorBackfillHours") }
    }
    /// Last time the one-shot "login expired" alert was delivered. Stored so a
    /// relaunch does not repeat the same alert within 24 hours.
    var weiboMonitorAuthAlertAt: Date? {
        didSet { TestIsolation.defaults.set(weiboMonitorAuthAlertAt, forKey: "weiboMonitorAuthAlertAt") }
    }
    var weiboMonitorShowPopoverChip: Bool {
        didSet { TestIsolation.defaults.set(weiboMonitorShowPopoverChip, forKey: "weiboMonitorShowPopoverChip") }
    }
    /// Red unread count on the menu-bar status item. Separate from the
    /// Dashboard badge so a user can keep one and hide the other.
    var weiboMonitorMenuBarBadgeEnabled: Bool {
        didSet {
            TestIsolation.defaults.set(
                weiboMonitorMenuBarBadgeEnabled,
                forKey: "weiboMonitorMenuBarBadgeEnabled"
            )
        }
    }
    /// Red unread count on the Dashboard "关注" segment. The following page
    /// and the sidebar card keep their unread text either way.
    var weiboMonitorDashboardBadgeEnabled: Bool {
        didSet {
            TestIsolation.defaults.set(
                weiboMonitorDashboardBadgeEnabled,
                forKey: "weiboMonitorDashboardBadgeEnabled"
            )
        }
    }
    // MARK: - Relevance filtering

    /// Collapse off-topic and commercial posts, and stop them from notifying.
    /// On by default because "too much noise" is the problem the feature
    /// exists to solve; the feed always keeps an expandable section.
    var weiboMonitorRelevanceEnabled: Bool {
        didSet { TestIsolation.defaults.set(weiboMonitorRelevanceEnabled, forKey: "weiboMonitorRelevanceEnabled") }
    }
    /// Stored as the enum's raw value so an unknown future value degrades to
    /// balanced instead of corrupting the whole settings page.
    var weiboMonitorRelevanceModeRaw: String {
        didSet { TestIsolation.defaults.set(weiboMonitorRelevanceModeRaw, forKey: "weiboMonitorRelevanceMode") }
    }
    /// Opt-in cloud correction. Off by default: the post body leaves the
    /// machine only after the user explicitly asks for it.
    var weiboMonitorRelevanceAICorrection: Bool {
        didSet { TestIsolation.defaults.set(weiboMonitorRelevanceAICorrection, forKey: "weiboMonitorRelevanceAICorrection") }
    }
    /// Prefer a local Ollama instance over the free cloud endpoint.
    var weiboMonitorRelevancePreferLocal: Bool {
        didSet { TestIsolation.defaults.set(weiboMonitorRelevancePreferLocal, forKey: "weiboMonitorRelevancePreferLocal") }
    }
    /// When the user last confirmed that enabling AI correction sends post
    /// text off the machine.
    var weiboMonitorRelevancePrivacyAckAt: Date? {
        didSet { TestIsolation.defaults.set(weiboMonitorRelevancePrivacyAckAt, forKey: "weiboMonitorRelevancePrivacyAckAt") }
    }

    var weiboMonitorRelevanceMode: WeiboRelevanceMode {
        get { WeiboRelevanceMode(rawValue: weiboMonitorRelevanceModeRaw) ?? .balanced }
        set { weiboMonitorRelevanceModeRaw = newValue.rawValue }
    }

    var colorScheme: String {
        didSet { TestIsolation.defaults.set(colorScheme, forKey: "colorScheme") }
    }
    var appTheme: AppTheme {
        didSet { TestIsolation.defaults.set(appTheme.rawValue, forKey: "appTheme") }
    }
    var appLanguage: AppLanguage {
        didSet {
            TestIsolation.defaults.set(appLanguage.rawValue, forKey: "appLanguage")
            L10n.currentLanguage = appLanguage
        }
    }
    var rssTitleTranslationEnabled: Bool {
        didSet { TestIsolation.defaults.set(rssTitleTranslationEnabled, forKey: "rssTitleTranslationEnabled") }
    }
    var readerCookieMemoryEnabled: Bool {
        didSet { TestIsolation.defaults.set(readerCookieMemoryEnabled, forKey: "readerCookieMemoryEnabled") }
    }
    var readerHistoryEnabled: Bool {
        didSet { TestIsolation.defaults.set(readerHistoryEnabled, forKey: "readerHistoryEnabled") }
    }
    var aiSearchHistoryEnabled: Bool {
        didSet { TestIsolation.defaults.set(aiSearchHistoryEnabled, forKey: "aiSearchHistoryEnabled") }
    }
    /// Reader-mode typography. Values are relative multipliers, never pixels:
    /// the native reader multiplies a base point size by `readerModeFontScale`.
    var readerModeFontScale: Double {
        didSet { TestIsolation.defaults.set(readerModeFontScale, forKey: "readerModeFontScale") }
    }
    var readerModeLineSpacing: Double {
        didSet { TestIsolation.defaults.set(readerModeLineSpacing, forKey: "readerModeLineSpacing") }
    }
    /// Maximum text column width in points (620…760).
    var readerModeWidth: Double {
        didSet { TestIsolation.defaults.set(readerModeWidth, forKey: "readerModeWidth") }
    }
    /// `auto` follows the app theme, `paper` is a warm light page, `dark` is a
    /// low-light page.
    var readerModeTheme: String {
        didSet { TestIsolation.defaults.set(readerModeTheme, forKey: "readerModeTheme") }
    }
    /// Reader web-page zoom: `fit` shrinks desktop pages to the panel width,
    /// `actual` always shows 100%, `large` shows 125%.
    var readerPageZoomMode: String {
        didSet { TestIsolation.defaults.set(readerPageZoomMode, forKey: "readerPageZoomMode") }
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
        didSet {
            aiSummaryEnablementRevision.noteChange(from: oldValue, to: aiSummaryEnabled)
            TestIsolation.defaults.set(aiSummaryEnabled, forKey: "aiSummaryEnabled")
        }
    }
    @ObservationIgnored private var aiSummaryEnablementRevision = AISummaryEnablementRevision()

    var aiSummaryRunRevision: UUID { aiSummaryEnablementRevision.value }

    func isCurrentAISummaryRun(_ revision: UUID) -> Bool {
        aiSummaryEnablementRevision.isCurrent(revision, enabled: aiSummaryEnabled)
    }
    var aiModel: String {
        didSet { TestIsolation.defaults.set(aiModel, forKey: "aiModel") }
    }
    /// True only when the user typed the model id by hand. A manual id may be
    /// used when the provider exposes no model catalog; the UI marks it as
    /// unverified, and API-key and quota checks still apply.
    var aiModelManuallyEntered: Bool {
        didSet { TestIsolation.defaults.set(aiModelManuallyEntered, forKey: "aiModelManuallyEntered") }
    }
    var aiPopupMaxWords: Int {
        didSet { TestIsolation.defaults.set(aiPopupMaxWords, forKey: "aiPopupMaxWords") }
    }
    var aiDashboardMaxWords: Int {
        didSet { TestIsolation.defaults.set(aiDashboardMaxWords, forKey: "aiDashboardMaxWords") }
    }
    var aiMaxWords: Int {
        didSet { TestIsolation.defaults.set(aiMaxWords, forKey: "aiMaxWords") }
    }
    /// Daily AI call cap for the whole app. `-1` means unlimited. The gate
    /// always works through `aiQuotaPolicy`, never through this raw value.
    var aiDailyCap: Int {
        didSet { TestIsolation.defaults.set(aiDailyCap, forKey: "aiDailyCap") }
    }
    /// Active limit style: call count or money budget. Exactly one applies.
    var aiLimitMode: AILimitMode {
        didSet { TestIsolation.defaults.set(aiLimitMode.rawValue, forKey: "aiLimitMode") }
    }
    /// Money budget in micros of the display currency. Read only in `.cost` mode.
    var aiCostCapMicros: Int64 {
        didSet { TestIsolation.defaults.set(aiCostCapMicros, forKey: "aiCostCapMicros") }
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
        didSet { TestIsolation.defaults.set(aiBudgetMode.rawValue, forKey: "aiBudgetMode") }
    }
    /// When true, DeepSeek V4's thinking mode is disabled for faster,
    /// non-truncated summaries. Exposed in Settings → AI.
    var aiDisableDeepSeekThinking: Bool {
        didSet { TestIsolation.defaults.set(aiDisableDeepSeekThinking, forKey: "aiDisableDeepSeekThinking") }
    }
    var aiPopupDailyCap: Int {
        didSet { TestIsolation.defaults.set(aiPopupDailyCap, forKey: "aiPopupDailyCap") }
    }
    /// Reader AI search is a first-class feature, but it is independent from the
    /// RSS summary settings: its own model, thinking level and page budget.
    var aiSearchEnabled: Bool {
        didSet { TestIsolation.defaults.set(aiSearchEnabled, forKey: "aiSearchEnabled") }
    }
    /// Allows the web-search scope. When off, only the current page can be used
    /// as context, and no search provider is contacted.
    var aiSearchUseWeb: Bool {
        didSet { TestIsolation.defaults.set(aiSearchUseWeb, forKey: "aiSearchUseWeb") }
    }

    /// Selected-text look-up mode. Offline by default; see SelectionWebMode.
    var selectionWebMode: SelectionWebMode {
        didSet { TestIsolation.defaults.set(selectionWebMode.rawValue, forKey: "selectionWebMode") }
    }
    /// Empty means "inherit `aiModel`". Never written implicitly.
    var aiSearchModel: String {
        didSet { TestIsolation.defaults.set(aiSearchModel, forKey: "aiSearchModel") }
    }
    var aiSearchThinking: AIThinkingLevel {
        didSet { TestIsolation.defaults.set(aiSearchThinking.rawValue, forKey: "aiSearchThinking") }
    }
    /// 3 / 5 / 8 pages per web search.
    var aiSearchPageCount: Int {
        didSet { TestIsolation.defaults.set(aiSearchPageCount, forKey: "aiSearchPageCount") }
    }
    var aiDashboardDailyCap: Int {
        didSet { TestIsolation.defaults.set(aiDashboardDailyCap, forKey: "aiDashboardDailyCap") }
    }
    var aiProvider: String {
        didSet {
            guard !isInitializing else { return }
            TestIsolation.defaults.set(aiProvider, forKey: "aiProvider")
            cachedAPIKey = nil
            invalidateModelCatalog(clearSelection: true)
        }
    }
    var onePasswordRef: String {
        didSet {
            guard !isInitializing else { return }
            noteAICredentialIntent()
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
            TestIsolation.defaults.set(Array(selectedRSSSourceIDs), forKey: "selectedRSSSourceIDs")
        }
    }
    var todayRefreshCount: Int {
        didSet { TestIsolation.defaults.set(todayRefreshCount, forKey: "todayRefreshCount") }
    }
    var todayAIRequestCount: Int {
        didSet { TestIsolation.defaults.set(todayAIRequestCount, forKey: "todayAIRequestCount") }
    }
    var todayPopupAIRequestCount: Int {
        didSet { TestIsolation.defaults.set(todayPopupAIRequestCount, forKey: "todayPopupAIRequestCount") }
    }
    var todayDashboardAIRequestCount: Int {
        didSet { TestIsolation.defaults.set(todayDashboardAIRequestCount, forKey: "todayDashboardAIRequestCount") }
    }
    var lastRefreshTimestamp: Double {
        didSet { TestIsolation.defaults.set(lastRefreshTimestamp, forKey: "lastRefreshTimestamp") }
    }
    var statsDayTimestamp: Double {
        didSet { TestIsolation.defaults.set(statsDayTimestamp, forKey: "statsDayTimestamp") }
    }

    var updateDevMode: Bool {
        didSet { TestIsolation.defaults.set(updateDevMode, forKey: "updateDevMode") }
    }

    var showAllAIModels: Bool {
        didSet { TestIsolation.defaults.set(showAllAIModels, forKey: "showAllAIModels") }
    }

    var customAIProviders: [CustomAIProviderConfig] {
        didSet {
            saveCustomAIProviders()
            guard !isInitializing else { return }
            let old = oldValue.first { "custom:\($0.id)" == aiProvider }
            if old?.resolvedConnection().credentialEndpointIdentity
                != selectedCustomProvider?.resolvedConnection().credentialEndpointIdentity {
                cachedAPIKey = nil
            }
            if old != selectedCustomProvider { invalidateModelCatalog(clearSelection: true) }
        }
    }

    var hourlyPushEnabled: Bool {
        didSet { TestIsolation.defaults.set(hourlyPushEnabled, forKey: "hourlyPushEnabled") }
    }
    var dailyPushEnabled: Bool {
        didSet { TestIsolation.defaults.set(dailyPushEnabled, forKey: "dailyPushEnabled") }
    }
    var pushCount: Int {
        didSet { TestIsolation.defaults.set(pushCount, forKey: "pushCount") }
    }
    var dailyPushHour: Int {
        didSet { TestIsolation.defaults.set(dailyPushHour, forKey: "dailyPushHour") }
    }
    var dailyPushMinute: Int {
        didSet { TestIsolation.defaults.set(dailyPushMinute, forKey: "dailyPushMinute") }
    }

    /// Master toggle for the Weibo "爆" burst-topic realtime push + research.
    var burstPushEnabled: Bool {
        didSet { TestIsolation.defaults.set(burstPushEnabled, forKey: "burstPushEnabled") }
    }
    /// Master toggle for automatic research records (burst detection). Manual
    /// verification from a news item always remains available.
    var researchAutoEnabled: Bool {
        didSet { TestIsolation.defaults.set(researchAutoEnabled, forKey: "researchAutoEnabled") }
    }
    /// Maximum new burst topics enqueued per refresh round.
    var researchDetectionLimit: Int {
        didSet { TestIsolation.defaults.set(researchDetectionLimit, forKey: "researchDetectionLimit") }
    }
    /// Shows the compact research entry above the popover feed.
    var researchShowPopoverChip: Bool {
        didSet { TestIsolation.defaults.set(researchShowPopoverChip, forKey: "researchShowPopoverChip") }
    }
    /// Opening a finished research record clears its unread marker. Active runs
    /// never do. Turning this off keeps the unread badge until a manual mark.
    var researchMarkReadOnOpen: Bool {
        didSet { TestIsolation.defaults.set(researchMarkReadOnOpen, forKey: "researchMarkReadOnOpen") }
    }
    /// Lets the local interest profile add non-burst topics to automatic
    /// research. Effective only while local learning is enabled.
    var researchUsePersonalization: Bool {
        didSet { TestIsolation.defaults.set(researchUsePersonalization, forKey: "researchUsePersonalization") }
    }
    /// Read-only mirror of the last automatic selection result. Written by the
    /// orchestrator so settings can explain a skipped hour; never persisted as
    /// a preference.
    private(set) var researchLastAutomaticDecision: String?

    func updateResearchLastAutomaticDecision(_ text: String?) {
        researchLastAutomaticDecision = text
        if let text {
            TestIsolation.defaults.set(text, forKey: "researchLastAutomaticDecision")
        } else {
            TestIsolation.defaults.removeObject(forKey: "researchLastAutomaticDecision")
        }
    }
    /// Shows the one-sentence summary in the completion notification. Turning
    /// it off keeps the report title but hides the conclusion from the lock
    /// screen.
    var researchNotificationShowsSummary: Bool {
        didSet {
            TestIsolation.defaults.set(
                researchNotificationShowsSummary,
                forKey: "researchNotificationShowsSummary"
            )
        }
    }
    /// Research depth preset (quick / standard / deep).
    var researchDepth: ResearchDepth {
        didSet { TestIsolation.defaults.set(researchDepth.rawValue, forKey: "researchDepth") }
    }
    /// Shared daily task cap, counted across origins.
    var researchDailyTaskCap: Int {
        didSet { TestIsolation.defaults.set(researchDailyTaskCap, forKey: "researchDailyTaskCap") }
    }
    /// Maximum research tasks running at once.
    var researchMaxConcurrent: Int {
        didSet { TestIsolation.defaults.set(researchMaxConcurrent, forKey: "researchMaxConcurrent") }
    }
    /// Default time window; `auto` derives it from the seed's publish date.
    var researchDefaultRecency: ResearchDefaultRecency {
        didSet { TestIsolation.defaults.set(researchDefaultRecency.rawValue, forKey: "researchDefaultRecency") }
    }
    /// Enabled search providers, stored as raw values (Tavily → Firecrawl → Brave).
    var researchSearchProviders: [String] {
        didSet {
            TestIsolation.defaults.set(researchSearchProviders, forKey: "researchSearchProviders")
        }
    }
    var researchHistoryLimit: Int {
        didSet { TestIsolation.defaults.set(researchHistoryLimit, forKey: "researchHistoryLimit") }
    }
    var researchRetentionDays: Int {
        didSet { TestIsolation.defaults.set(researchRetentionDays, forKey: "researchRetentionDays") }
    }
    var researchTempCacheMB: Int {
        didSet { TestIsolation.defaults.set(researchTempCacheMB, forKey: "researchTempCacheMB") }
    }
    var researchTempCacheTTLHours: Int {
        didSet { TestIsolation.defaults.set(researchTempCacheTTLHours, forKey: "researchTempCacheTTLHours") }
    }
    var researchConsentVersion: Int {
        didSet { TestIsolation.defaults.set(researchConsentVersion, forKey: "researchConsentVersion") }
    }
    /// Enables the developer test-mode toggle that fires a fake burst push.
    var burstTestMode: Bool {
        didSet { TestIsolation.defaults.set(burstTestMode, forKey: "burstTestMode") }
    }
    /// The user-entered hot-search title used by the burst test push.
    var burstTestTopic: String {
        didSet { TestIsolation.defaults.set(burstTestTopic, forKey: "burstTestTopic") }
    }
    /// Legacy Firecrawl key, kept only for the one-time migration into the
    /// encrypted store. New values are never written back as plaintext;
    /// clearing the property removes any leftover legacy value.
    var firecrawlAPIKey: String {
        didSet {
            guard firecrawlAPIKey.isEmpty else { return }
            TestIsolation.defaults.removeObject(forKey: "firecrawlAPIKey")
        }
    }
    /// Independent daily cap for burst research AI requests.
    var burstDailyCap: Int {
        didSet { TestIsolation.defaults.set(burstDailyCap, forKey: "burstDailyCap") }
    }
    var todayBurstResearchCount: Int {
        didSet { TestIsolation.defaults.set(todayBurstResearchCount, forKey: "todayBurstResearchCount") }
    }

    /// Master toggle for custom-keyword realtime push + research.
    var keywordTrackingEnabled: Bool {
        didSet { TestIsolation.defaults.set(keywordTrackingEnabled, forKey: "keywordTrackingEnabled") }
    }
    /// User-entered keywords; a news item whose title contains any keyword
    /// (case-insensitive) triggers a research push.
    var keywordList: [String] {
        didSet {
            TestIsolation.defaults.set(keywordList, forKey: "keywordList")
        }
    }

    var rssUnifiedDisplayCount: Bool {
        didSet { TestIsolation.defaults.set(rssUnifiedDisplayCount, forKey: "rssUnifiedDisplayCount") }
    }
    var rssDefaultTextCount: Int {
        didSet { TestIsolation.defaults.set(rssDefaultTextCount, forKey: "rssDefaultTextCount") }
    }
    var rssDefaultImageCount: Int {
        didSet { TestIsolation.defaults.set(rssDefaultImageCount, forKey: "rssDefaultImageCount") }
    }

    var rssSources: [RSSSourceConfig] {
        didSet { saveRSSSources() }
    }

    @ObservationIgnored var cachedAPIKey: String? {
        didSet {
            if cachedAPIKey == nil || cachedAPIKey != oldValue { cachedKeyEndpointIdentity = nil }
            if !isInitializing, cachedAPIKey != oldValue { invalidateModelCatalog(clearSelection: false) }
        }
    }
    @ObservationIgnored private var cachedKeyEndpointIdentity: String?
    @ObservationIgnored private(set) var aiCredentialIntentRevision = UUID()
    @ObservationIgnored private var aiKeyMutationGate = AIKeyMutationGate()

    func noteAICredentialIntent() {
        aiCredentialIntentRevision = UUID()
    }

    @MainActor
    func beginAICredentialMutation(account: String) -> UUID {
        noteAICredentialIntent()
        let token = aiCredentialIntentRevision
        aiKeyMutationGate.begin(account: account, token: token)
        // Invalidate reads that started before the user's mutation intent.
        invalidateModelCatalog(clearSelection: false)
        return token
    }

    @MainActor
    func finishAICredentialMutation(account: String, token: UUID) -> Bool {
        aiKeyMutationGate.finish(account: account, token: token)
        let settled = !aiKeyMutationGate.isPending(account: account)
        if settled, account == activeAPIKeyAccount {
            // A model refresh may have stopped while the gate was closed.
            invalidateModelCatalog(clearSelection: false)
        }
        return token == aiCredentialIntentRevision && settled
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
        let defaults = TestIsolation.defaults

        self.autoRefreshEnabled = defaults.boolIfPresent(forKey: "autoRefreshEnabled") ?? false
        self.launchAtLogin = defaults.boolIfPresent(forKey: "launchAtLogin") ?? false
        self.weiboMonitorEnabled = defaults.boolIfPresent(forKey: "weiboMonitorEnabled") ?? false
        self.weiboMonitorNotifyEnabled = defaults.boolIfPresent(forKey: "weiboMonitorNotifyEnabled") ?? true
        self.weiboMonitorP0Seconds = Self.clampedInterval(
            defaults.integerIfPresent(forKey: "weiboMonitorP0Seconds") ?? 120,
            minimum: 90,
            maximum: 900
        )
        self.weiboMonitorP1Seconds = Self.clampedInterval(
            defaults.integerIfPresent(forKey: "weiboMonitorP1Seconds") ?? 300,
            minimum: 180,
            maximum: 1800
        )
        self.weiboMonitorP2Seconds = Self.clampedInterval(
            defaults.integerIfPresent(forKey: "weiboMonitorP2Seconds") ?? 900,
            minimum: 600,
            maximum: 3600
        )
        self.weiboMonitorNightEnabled = defaults.boolIfPresent(forKey: "weiboMonitorNightEnabled") ?? true
        self.weiboMonitorNightStartMinute = min(
            1439,
            max(0, defaults.integerIfPresent(forKey: "weiboMonitorNightStartMinute") ?? 30)
        )
        self.weiboMonitorNightEndMinute = min(
            1439,
            max(0, defaults.integerIfPresent(forKey: "weiboMonitorNightEndMinute") ?? 450)
        )
        self.weiboMonitorPerAccountHourlyCap = min(
            50,
            max(1, defaults.integerIfPresent(forKey: "weiboMonitorPerAccountHourlyCap") ?? 6)
        )
        self.weiboMonitorGlobalHourlyCap = min(
            100,
            max(1, defaults.integerIfPresent(forKey: "weiboMonitorGlobalHourlyCap") ?? 20)
        )
        self.weiboMonitorKeywordNotifyEnabled = defaults.boolIfPresent(forKey: "weiboMonitorKeywordNotifyEnabled") ?? true
        self.weiboMonitorKeywordList = Self.normalizedKeywords(
            defaults.stringArray(forKey: "weiboMonitorKeywordList") ?? []
        )
        self.weiboMonitorBackfillHours = min(
            2,
            max(0, defaults.integerIfPresent(forKey: "weiboMonitorBackfillHours") ?? 0)
        )
        self.weiboMonitorAuthAlertAt = defaults.object(forKey: "weiboMonitorAuthAlertAt") as? Date
        self.weiboMonitorShowPopoverChip = defaults.boolIfPresent(forKey: "weiboMonitorShowPopoverChip") ?? true
        self.weiboMonitorMenuBarBadgeEnabled =
            defaults.boolIfPresent(forKey: "weiboMonitorMenuBarBadgeEnabled") ?? true
        self.weiboMonitorDashboardBadgeEnabled =
            defaults.boolIfPresent(forKey: "weiboMonitorDashboardBadgeEnabled") ?? true
        self.weiboMonitorRelevanceEnabled = defaults.boolIfPresent(forKey: "weiboMonitorRelevanceEnabled") ?? true
        let storedRelevanceMode = defaults.stringIfPresent(forKey: "weiboMonitorRelevanceMode") ?? ""
        self.weiboMonitorRelevanceModeRaw =
            WeiboRelevanceMode(rawValue: storedRelevanceMode)?.rawValue
            ?? WeiboRelevanceMode.balanced.rawValue
        self.weiboMonitorRelevanceAICorrection =
            defaults.boolIfPresent(forKey: "weiboMonitorRelevanceAICorrection") ?? false
        self.weiboMonitorRelevancePreferLocal =
            defaults.boolIfPresent(forKey: "weiboMonitorRelevancePreferLocal") ?? false
        self.weiboMonitorRelevancePrivacyAckAt =
            defaults.object(forKey: "weiboMonitorRelevancePrivacyAckAt") as? Date
        self.colorScheme = defaults.stringIfPresent(forKey: "colorScheme") ?? "system"
        self.appTheme = AppTheme(rawValue: defaults.stringIfPresent(forKey: "appTheme") ?? "") ?? .modern
        let language = AppLanguage(rawValue: defaults.stringIfPresent(forKey: "appLanguage") ?? "") ?? .zh
        self.appLanguage = language
        L10n.currentLanguage = language
        self.rssTitleTranslationEnabled = defaults.boolIfPresent(forKey: "rssTitleTranslationEnabled") ?? false
        self.readerCookieMemoryEnabled = defaults.boolIfPresent(forKey: "readerCookieMemoryEnabled") ?? true
        self.readerHistoryEnabled = defaults.boolIfPresent(forKey: "readerHistoryEnabled") ?? true
        self.aiSearchHistoryEnabled = defaults.boolIfPresent(forKey: "aiSearchHistoryEnabled") ?? true
        let storedFontScale = defaults.doubleIfPresent(forKey: "readerModeFontScale") ?? 1.0
        self.readerModeFontScale = [0.9, 1.0, 1.15, 1.35].contains(storedFontScale) ? storedFontScale : 1.0
        let storedLineSpacing = defaults.doubleIfPresent(forKey: "readerModeLineSpacing") ?? 1.55
        self.readerModeLineSpacing = [1.35, 1.55, 1.75].contains(storedLineSpacing) ? storedLineSpacing : 1.55
        let storedWidth = defaults.doubleIfPresent(forKey: "readerModeWidth") ?? 680
        self.readerModeWidth = (620...760).contains(storedWidth) ? storedWidth : 680
        let storedReaderTheme = defaults.stringIfPresent(forKey: "readerModeTheme") ?? "auto"
        self.readerModeTheme = ["auto", "paper", "dark"].contains(storedReaderTheme) ? storedReaderTheme : "auto"
        let storedPageZoom = defaults.stringIfPresent(forKey: "readerPageZoomMode") ?? ReaderZoomMode.fit.rawValue
        self.readerPageZoomMode = ReaderZoomMode(rawValue: storedPageZoom)?.rawValue ?? ReaderZoomMode.fit.rawValue
        self.aiSummaryEnabled = defaults.boolIfPresent(forKey: "aiSummaryEnabled") ?? false
        self.aiProvider = defaults.stringIfPresent(forKey: "aiProvider") ?? "deepseek"

        // Persisted selections are historical until the provider's real catalog
        // validates them. Never migrate to another hard-coded model ID.
        self.aiModel = defaults.stringIfPresent(forKey: "aiModel") ?? ""
        self.aiModelManuallyEntered = defaults.boolIfPresent(forKey: "aiModelManuallyEntered") ?? false

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
        self.aiSearchEnabled = defaults.boolIfPresent(forKey: "aiSearchEnabled") ?? true
        self.aiSearchUseWeb = defaults.boolIfPresent(forKey: "aiSearchUseWeb") ?? true
        self.selectionWebMode = SelectionWebMode(
            rawValue: defaults.stringIfPresent(forKey: "selectionWebMode") ?? ""
        ) ?? .offline
        self.aiSearchModel = defaults.stringIfPresent(forKey: "aiSearchModel") ?? ""
        let rawSearchThinking = defaults.stringIfPresent(forKey: "aiSearchThinking") ?? AIThinkingLevel.medium.rawValue
        self.aiSearchThinking = AIThinkingLevel(rawValue: rawSearchThinking) ?? .medium
        let rawSearchPages = defaults.integerIfPresent(forKey: "aiSearchPageCount") ?? 3
        self.aiSearchPageCount = Self.validAISearchPageCounts.contains(rawSearchPages) ? rawSearchPages : 3
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

            guard TestIsolation.defaults.bool(forKey: "hasDeepSeekAPIKey") else { return }

            if TestIsolation.defaults.bool(forKey: newFlag) || TestIsolation.defaults.bool(forKey: accountFlag) {
                TestIsolation.defaults.set(true, forKey: newFlag)
                TestIsolation.defaults.removeObject(forKey: "hasDeepSeekAPIKey")
                return
            }

            let exists = await store.checkAPIKeyExistence(account: newAccount)
            guard !exists else {
                TestIsolation.defaults.removeObject(forKey: "hasDeepSeekAPIKey")
                return
            }

            guard let oldKey = KeychainManager.readLegacyAPIKey(), !oldKey.isEmpty else {
                TestIsolation.defaults.removeObject(forKey: "hasDeepSeekAPIKey")
                return
            }

            if await store.saveAPIKey(oldKey, account: newAccount) {
                KeychainManager.deleteLegacyAPIKey()
                TestIsolation.defaults.removeObject(forKey: "hasDeepSeekAPIKey")
                TestIsolation.defaults.set(true, forKey: newFlag)
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
            TestIsolation.defaults.set(data, forKey: "rssSources")
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
            TestIsolation.defaults.set(data, forKey: "customAIProviders")
        }
    }

    /// Persisted `aiProvider` uses `custom:<uuid>` to reference a custom provider.
    var selectedCustomProvider: CustomAIProviderConfig? {
        customProvider(byID: aiProvider)
    }

    var isUsingCustomProvider: Bool {
        selectedCustomProvider != nil
    }

    var hasUsableProviderSelection: Bool {
        AIProviderAccountPolicy.canUseConnection(
            providerID: aiProvider, customProviderExists: selectedCustomProvider != nil
        )
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
        AIProviderAccountPolicy.account(for: aiProvider)
    }

    /// Credential actions require an existing custom provider or a known
    /// built-in; an invalid persisted selection must not create an orphan key.
    var usableAPIKeyAccount: String? {
        AIProviderAccountPolicy.credentialAccount(
            for: aiProvider, customProviderExists: selectedCustomProvider != nil
        )
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

    /// Whether a model id has been validated. A catalog hit is validated; a
    /// hand-entered id is accepted without a catalog but is never presented as
    /// verified. Key presence and the quota ledger are checked separately, so
    /// this escape hatch cannot bypass them.
    var isAIModelCatalogValidated: Bool {
        guard modelCatalogProviderID == aiProvider,
              let updated = modelCatalogUpdatedAt, Date().timeIntervalSince(updated) <= 24 * 3600,
              modelCatalogIdentity == ProviderModelService.identity(providerID: aiProvider, connection: resolvedAIConnection, apiKey: usableCachedAPIKey ?? "") else { return false }
        return availableProviderModels.contains { $0.id == aiModel }
    }

    var canUseCurrentAIModel: Bool {
        if isAIModelCatalogValidated { return true }
        let manual = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return aiModelManuallyEntered && !manual.isEmpty
    }

    @discardableResult
    func activateAPIKey(_ key: String, providerID: String, revision: UUID) -> Bool {
        guard hasUsableProviderSelection, providerID == aiProvider, revision == modelCatalogRevision,
              !aiKeyMutationGate.isPending(account: activeAPIKeyAccount) else { return false }
        cachedAPIKey = key
        cachedKeyEndpointIdentity = selectedCustomProvider?.resolvedConnection().credentialEndpointIdentity
        return true
    }

    var usableCachedAPIKey: String? {
        guard let cachedAPIKey else { return nil }
        let context = AIKeyContext(
            providerID: aiProvider, account: activeAPIKeyAccount, revision: modelCatalogRevision,
            endpointIdentity: selectedCustomProvider?.resolvedConnection().credentialEndpointIdentity
        )
        return AIKeyAccess.mayUseCachedKey(context: context, cachedEndpointIdentity: cachedKeyEndpointIdentity)
            ? cachedAPIKey : nil
    }

    @MainActor
    var aiKeyContext: AIKeyContext {
        AIKeyContext(
            providerID: aiProvider, account: activeAPIKeyAccount, revision: modelCatalogRevision,
            endpointIdentity: selectedCustomProvider?.resolvedConnection().credentialEndpointIdentity
        )
    }

    @MainActor
    var aiCredentialUIContext: AICredentialUIContext {
        AICredentialUIContext(keyContext: aiKeyContext, intent: aiCredentialIntentRevision)
    }

    @MainActor
    func isCurrentAICredentialUIContext(_ started: AICredentialUIContext) -> Bool {
        hasUsableProviderSelection && started == aiCredentialUIContext
            && !aiKeyMutationGate.isPending(account: started.keyContext.account)
    }

    @MainActor
    func resolveBoundAPIKey(expected: AIKeyContext) async throws -> ProviderBoundKey {
        guard hasUsableProviderSelection, expected == aiKeyContext,
              !aiKeyMutationGate.isPending(account: expected.account) else {
            throw AISearchError.configurationChanged
        }
        if let cachedAPIKey = usableCachedAPIKey, !cachedAPIKey.isEmpty {
            return ProviderBoundKey(key: cachedAPIKey, context: expected)
        }
        return try await AIKeyAccess.read(
            started: expected,
            current: { self.aiKeyContext },
            read: { account in
                let store = EncryptedKeyStore()
                guard expected.providerID.hasPrefix("custom:") else {
                    return await store.readAPIKeyResult(account: account)
                }
                guard let identity = expected.endpointIdentity else { return .missing }
                switch await store.readBoundCustomKeyResult(account: account, endpointIdentity: identity) {
                case let .found(key): return .found(key)
                case .missing, .unbound, .endpointMismatch: return .missing
                case .failed: return .failed
                }
            },
            activate: { key in
                self.activateAPIKey(key, providerID: expected.providerID, revision: expected.revision)
            }
        )
    }

    @MainActor
    func isCurrentAIKey(_ bound: ProviderBoundKey) -> Bool {
        hasUsableProviderSelection && !aiKeyMutationGate.isPending(account: bound.context.account)
            && AIKeyAccess.isCurrent(bound, context: aiKeyContext, cachedKey: usableCachedAPIKey)
    }

    @MainActor
    func validatedAIConfiguration(boundKey bound: ProviderBoundKey) async -> ValidatedAIConfiguration? {
        // A key is mandatory for every provider except Ollama Cloud, which also
        // accepts a local/account-less call. A manual model id never skips this.
        let apiKey = bound.key
        guard !apiKey.isEmpty || aiProvider == AIProvider.ollamaCloud.rawValue else { return nil }
        guard isCurrentAIKey(bound) else { return nil }
        let catalogValidated = await refreshModelCatalog(boundKey: bound)
        guard isCurrentAIKey(bound) else { return nil }
        guard canUseCurrentAIModel else { return nil }
        if !catalogValidated, !(aiModelManuallyEntered && !aiModel.isEmpty) { return nil }
        return ValidatedAIConfiguration(providerID: aiProvider, connection: resolvedAIConnection,
                                        model: aiModel, apiKey: apiKey, revision: modelCatalogRevision)
    }

    func isCurrentAIConfiguration(_ configuration: ValidatedAIConfiguration) -> Bool {
        hasUsableProviderSelection && canUseCurrentAIModel && configuration.revision == modelCatalogRevision
            && configuration.providerID == aiProvider && configuration.model == aiModel
            && configuration.apiKey == (usableCachedAPIKey ?? "")
            && (!configuration.apiKey.isEmpty || configuration.providerID == AIProvider.ollamaCloud.rawValue)
    }

    /// A connection test must not activate an unsaved credential or make a
    /// billable generation request. The key is tied to its captured context
    /// before a request can be sent, not only when its result returns.
    @MainActor
    func checkModelConnection(apiKey: String, expected: AIKeyContext) async throws -> ProviderModelResult {
        guard hasUsableProviderSelection else { throw ProviderModelError.invalidEndpoint }
        guard expected == aiKeyContext, !aiKeyMutationGate.isPending(account: expected.account) else {
            throw AISearchError.configurationChanged
        }
        try Task.checkCancellation()
        let connection = resolvedAIConnection
        let result = try await modelService.catalog(
            providerID: expected.providerID, connection: connection, apiKey: apiKey, force: true
        )
        try Task.checkCancellation()
        guard hasUsableProviderSelection, expected == aiKeyContext,
              !aiKeyMutationGate.isPending(account: expected.account) else {
            throw AISearchError.configurationChanged
        }
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
        if clearSelection {
            aiModel = ""
            aiModelManuallyEntered = false
        }
    }

    /// Called on provider/key changes and before paid generation. Listing is
    /// metadata-only and never triggers a summary or research request itself.
    @MainActor
    @discardableResult
    func refreshModelCatalog(boundKey providedKey: ProviderBoundKey? = nil, force: Bool = false) async -> Bool {
        guard hasUsableProviderSelection else {
            modelCatalogError = .invalidEndpoint
            return false
        }
        let provider = aiProvider
        let connection = resolvedAIConnection
        let key: String
        if let providedKey {
            // The caller may have suspended since capturing its key. Validate
            // the full provider/account/revision/endpoint before dispatch, for
            // built-in providers as well as custom endpoints.
            guard isCurrentAIKey(providedKey) else { return false }
            key = providedKey.key
        } else {
            let expected = aiKeyContext
            do {
                let bound = try await resolveBoundAPIKey(expected: expected)
                guard isCurrentAIKey(bound) else { return false }
                key = bound.key
            } catch AISearchError.keyReadFailed {
                if expected == aiKeyContext { modelCatalogError = .keyReadFailed }
                return false
            } catch {
                return false
            }
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
                  identity == ProviderModelService.identity(providerID: aiProvider, connection: resolvedAIConnection, apiKey: usableCachedAPIKey ?? "") else { return false }
            modelCatalogProviderID = provider
            modelCatalogIdentity = identity
            availableProviderModels = result.snapshot.models
            modelCatalogUpdatedAt = result.snapshot.fetchedAt
            modelCatalogIsStale = result.source == .stale
            modelCatalogError = result.refreshError
            isLoadingModelCatalog = false
            let preferred = ProviderModelSelection.preferred(in: result.snapshot.models, current: aiModel) ?? ""
            aiModel = preferred
            if result.snapshot.models.contains(where: { $0.id == preferred }) {
                aiModelManuallyEntered = false
            }
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
    /// Page budgets offered for reader AI search.
    static let validAISearchPageCounts: Set<Int> = [3, 5, 8]

    /// The model AI search actually uses. Empty `aiSearchModel` inherits the
    /// summary model; it is never silently rewritten.
    var effectiveAISearchModel: String {
        let manual = aiSearchModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return manual.isEmpty ? aiModel : manual
    }
    /// Default money budget: ¥5.00/day.
    static let defaultAICostCapMicros: Int64 = 5_000_000
    /// v2.8 and earlier offered 20 / 50 / 100. Those values map to the new
    /// entry tier; a value already in the new set is preserved.
    static func migratedAICap(_ raw: Int) -> Int {
        validAICaps.contains(raw) ? raw : 200
    }

    static func clampedInterval(_ raw: Int, minimum: Int, maximum: Int) -> Int {
        min(maximum, max(minimum, raw))
    }

    /// Keywords are case-insensitively unique, trimmed, and bounded. The UI
    /// uses the same helper before saving, so the stored list and the live list
    /// never disagree.
    static func normalizedKeywords(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in raw {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 40 else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count >= 30 { break }
        }
        return result
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
