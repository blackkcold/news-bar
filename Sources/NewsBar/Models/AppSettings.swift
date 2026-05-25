import Foundation
import Observation

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
    var aiSummaryEnabled: Bool {
        didSet { UserDefaults.standard.set(aiSummaryEnabled, forKey: "aiSummaryEnabled") }
    }
    var aiModel: String {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel") }
    }
    var aiMaxWords: Int {
        didSet { UserDefaults.standard.set(aiMaxWords, forKey: "aiMaxWords") }
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
            if onePasswordRef.isEmpty {
                KeychainManager.deleteOnePasswordRef()
            } else {
                _ = KeychainManager.saveOnePasswordRef(onePasswordRef)
            }
        }
    }
    var selectedRSSSourceIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(selectedRSSSourceIDs), forKey: "selectedRSSSourceIDs")
        }
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

        self.aiMaxWords = defaults.integerIfPresent(forKey: "aiMaxWords") ?? 150
        let savedOnePasswordRef = KeychainManager.readOnePasswordRef()
        self.onePasswordRef = savedOnePasswordRef
            ?? defaults.stringIfPresent(forKey: "onePasswordRef")
            ?? ""

        if savedOnePasswordRef == nil,
           let legacyRef = defaults.stringIfPresent(forKey: "onePasswordRef"),
           !legacyRef.isEmpty {
            _ = KeychainManager.saveOnePasswordRef(legacyRef)
            defaults.removeObject(forKey: "onePasswordRef")
        }

        let selectedIDs = defaults.stringArray(forKey: "selectedRSSSourceIDs") ?? []
        self.selectedRSSSourceIDs = Set(selectedIDs)

        if let data = defaults.data(forKey: "rssSources"),
           let decoded = try? JSONDecoder().decode([RSSSourceConfig].self, from: data) {
            self.rssSources = decoded
        } else {
            self.rssSources = []
        }

        self.isInitializing = false
    }

    func migrateLegacyKeyIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "hasDeepSeekAPIKey") else { return }

        let newAccount = AIProvider.deepseek.apiKeyAccount()
        let newFlag = AIProvider.deepseek.keyExistsFlag()
        let accountFlag = "hasAIKey-\(newAccount)"
        if UserDefaults.standard.bool(forKey: newFlag) || UserDefaults.standard.bool(forKey: accountFlag) {
            UserDefaults.standard.set(true, forKey: newFlag)
            UserDefaults.standard.removeObject(forKey: "hasDeepSeekAPIKey")
            return
        }

        guard KeychainManager.checkAPIKeyExistence(account: newAccount) == .notFound else {
            UserDefaults.standard.removeObject(forKey: "hasDeepSeekAPIKey")
            return
        }

        guard let oldKey = KeychainManager.readLegacyAPIKey(), !oldKey.isEmpty else {
            UserDefaults.standard.removeObject(forKey: "hasDeepSeekAPIKey")
            return
        }

        if KeychainManager.saveAPIKey(oldKey, account: newAccount) {
            KeychainManager.deleteLegacyAPIKey()
            UserDefaults.standard.removeObject(forKey: "hasDeepSeekAPIKey")
            UserDefaults.standard.set(true, forKey: newFlag)
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
}

struct RSSSourceConfig: Identifiable, Hashable, Codable {
    var id: String { url }
    var name: String
    var url: String
    var displayMode: DisplayMode

    enum DisplayMode: String, CaseIterable, Codable {
        case single
        case scroll
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
}
