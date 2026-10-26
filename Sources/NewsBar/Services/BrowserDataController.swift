import Foundation
import Observation

/// Shared state for the "浏览器" settings tab and the reader's cookie/history writes.
@MainActor
@Observable
final class BrowserDataController {
    static let shared = BrowserDataController()

    private let vault: ReaderCookieVault
    private let historyStore: ReaderHistoryStore
    private var prepareTask: Task<Void, Never>?

    private(set) var sites: [ReaderSavedSite] = []
    private(set) var history: [ReaderHistoryEntry] = []
    private(set) var isReady = false
    private(set) var storageError: String?

    init(
        vault: ReaderCookieVault = ReaderCookieVault(),
        historyStore: ReaderHistoryStore = ReaderHistoryStore()
    ) {
        self.vault = vault
        self.historyStore = historyStore
    }

    var totalCookieCount: Int {
        sites.reduce(0) { $0 + $1.cookies.count }
    }

    func prepare() async {
        if isReady { return }
        if let prepareTask {
            await prepareTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.vault.prepare()
            await self.historyStore.prepare()
            self.sites = await self.vault.siteSummaries()
            self.history = await self.historyStore.all()
            let vaultError = await self.vault.loadError
            let historyError = await self.historyStore.loadError
            self.storageError = vaultError ?? historyError
            self.isReady = true
        }
        prepareTask = task
        await task.value
        prepareTask = nil
    }

    func refresh() async {
        await prepare()
        sites = await vault.siteSummaries()
        history = await historyStore.all()
    }

    // MARK: - History

    @discardableResult
    func recordOpen(url: String, title: String, host: String) async -> Bool {
        await prepare()
        do {
            _ = try await historyStore.record(url: url, title: title, host: host)
            history = await historyStore.all()
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    func removeHistory(_ id: UUID) async {
        do {
            try await historyStore.remove(id: id)
            history = await historyStore.all()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func clearHistory() async {
        do {
            try await historyStore.clear()
            history = []
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: - Cookies

    /// Automatic and explicit captures both update in place. Deleting a saved
    /// site is a separate, explicit action (`removeSite`) so a transient empty
    /// page during a login redirect never erases a working sign-in.
    @discardableResult
    func capture(cookies: [HTTPCookie], host: String, title: String?) async -> Int {
        await prepare()
        do {
            let count = try await vault.upsert(
                cookies: cookies,
                host: host,
                title: title,
                allowEmptyRemoval: false
            )
            sites = await vault.siteSummaries()
            return count
        } catch {
            storageError = error.localizedDescription
            return 0
        }
    }

    func site(for host: String) -> ReaderSavedSite? {
        guard let normalized = ReaderCookieHost.normalize(host) else { return nil }
        return sites.first { $0.host == normalized }
    }

    /// Cookies to replay into a new ephemeral reader session.
    func cookiesForInjection(host: String) async -> [HTTPCookie] {
        await prepare()
        return await vault.cookies(matching: host)
    }

    func hasSite(_ host: String) -> Bool {
        site(for: host) != nil
    }

    func removeSite(_ host: String) async {
        do {
            try await vault.removeSite(host)
            sites = await vault.siteSummaries()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func clearCookies() async {
        do {
            try await vault.clear()
            sites = []
        } catch {
            storageError = error.localizedDescription
        }
    }
}
