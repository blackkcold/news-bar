import Foundation
import Observation

struct ReaderCookieCaptureEpoch: Equatable, Sendable {
    let allSites = UUID()
    var sites: [String: UUID] = [:]
}

/// Shared state for the "浏览器" settings tab and the reader's cookie/history writes.
@MainActor
@Observable
final class BrowserDataController {
    static let shared = BrowserDataController()

    private let vault: ReaderCookieVault
    private let historyStore: ReaderHistoryStore
    private var prepareTask: Task<Void, Never>?
    private var isClearingCookies = false
    private var sitesBeingRemoved: Set<String> = []
    private var cookieDurabilityRevision = UUID()
    private var cookieRecoveryRevision = UUID()

    private(set) var sites: [ReaderSavedSite] = []
    private(set) var history: [ReaderHistoryEntry] = []
    private(set) var isReady = false
    private(set) var storageError: String?
    private(set) var cookieDurabilityPending = false
    private(set) var cookieRecoveryPending = false
    private(set) var cookieCaptureEpoch = ReaderCookieCaptureEpoch()

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
            if await self.vault.requiresReconciliation {
                self.noteCookieStateUnverified()
            } else {
                self.storageError = vaultError ?? historyError
            }
            self.isReady = true
        }
        prepareTask = task
        await task.value
        prepareTask = nil
    }

    func refresh() async {
        await prepare()
        let epoch = cookieCaptureEpoch
        let updatedSites = await vault.siteSummaries()
        if !isClearingCookies, epoch == cookieCaptureEpoch {
            sites = updatedSites
        }
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

    func retryCookieRecovery() async {
        guard cookieRecoveryPending, !isClearingCookies else { return }
        let revision = cookieRecoveryRevision
        do {
            try await vault.reconcileUnverifiedState()
            let updatedSites = await vault.siteSummaries()
            guard cookieRecoveryPending, !isClearingCookies, revision == cookieRecoveryRevision else { return }
            sites = updatedSites
            cookieRecoveryPending = false
            storageError = cookieDurabilityPending ? ReaderCookieVaultError.durabilityUnknown.localizedDescription : nil
        } catch {
            guard cookieRecoveryPending, !isClearingCookies, revision == cookieRecoveryRevision else { return }
            storageError = ReaderCookieVaultError.stateUnverified.localizedDescription
        }
    }

    func retryCookieDurability() async {
        guard cookieDurabilityPending, !cookieRecoveryPending else { return }
        let revision = cookieDurabilityRevision
        let originalError = storageError
        do {
            try await vault.confirmDurability()
            guard cookieDurabilityPending, revision == cookieDurabilityRevision else { return }
            cookieDurabilityPending = false
            if storageError == originalError { storageError = nil }
        } catch {
            guard cookieDurabilityPending, revision == cookieDurabilityRevision else { return }
            storageError = error.localizedDescription
        }
    }

    private func noteCookieDurabilityUnknown() {
        cookieDurabilityRevision = UUID()
        cookieDurabilityPending = true
        storageError = ReaderCookieVaultError.durabilityUnknown.localizedDescription
    }

    private func noteCookieStateUnverified() {
        cookieCaptureEpoch = ReaderCookieCaptureEpoch()
        cookieRecoveryRevision = UUID()
        cookieRecoveryPending = true
        cookieDurabilityRevision = UUID()
        cookieDurabilityPending = true
        sites = []
        storageError = ReaderCookieVaultError.stateUnverified.localizedDescription
    }

    /// Automatic and explicit captures both update in place. Deleting a saved
    /// site is a separate, explicit action (`removeSite`) so a transient empty
    /// page during a login redirect never erases a working sign-in.
    /// - Parameter allowEmptyRemoval: set only for a capture made on the site's
    ///   own log-out landing page, where an empty jar means the user signed out.
    private func isCaptureAllowed(_ epoch: ReaderCookieCaptureEpoch, site: String) -> Bool {
        guard !isClearingCookies, !cookieRecoveryPending, epoch.allSites == cookieCaptureEpoch.allSites,
              !sitesBeingRemoved.contains(where: { ReaderCookieHost.belongsToSite(domain: site, site: $0) }) else {
            return false
        }
        for (scope, revision) in cookieCaptureEpoch.sites
        where ReaderCookieHost.belongsToSite(domain: site, site: scope) {
            if epoch.sites[scope] != revision { return false }
        }
        return true
    }

    @discardableResult
    func capture(
        cookies: [HTTPCookie],
        host: String,
        title: String?,
        allowEmptyRemoval: Bool = false,
        epoch: ReaderCookieCaptureEpoch? = nil
    ) async -> Int {
        guard let site = ReaderCookieSiteScope.site(for: host) else { return 0 }
        let expectedEpoch = epoch ?? cookieCaptureEpoch
        guard isCaptureAllowed(expectedEpoch, site: site) else { return 0 }
        await prepare()
        guard isCaptureAllowed(expectedEpoch, site: site) else { return 0 }
        guard let token = await vault.writeToken(for: host) else { return 0 }
        guard isCaptureAllowed(expectedEpoch, site: site) else { return 0 }
        do {
            let count = try await vault.upsert(
                cookies: cookies,
                host: host,
                title: title,
                allowEmptyRemoval: allowEmptyRemoval,
                writeToken: token
            )
            let summaryEpoch = cookieCaptureEpoch
            let updatedSites = await vault.siteSummaries()
            guard isCaptureAllowed(expectedEpoch, site: site) else { return 0 }
            if summaryEpoch == cookieCaptureEpoch { sites = updatedSites }
            return count
        } catch ReaderCookieVaultError.durabilityUnknown {
            guard isCaptureAllowed(expectedEpoch, site: site) else { return 0 }
            let summaryEpoch = cookieCaptureEpoch
            let updatedSites = await vault.siteSummaries()
            guard isCaptureAllowed(expectedEpoch, site: site) else { return 0 }
            if summaryEpoch == cookieCaptureEpoch { sites = updatedSites }
            noteCookieDurabilityUnknown()
            return 0
        } catch ReaderCookieVaultError.stateUnverified {
            guard isCaptureAllowed(expectedEpoch, site: site) else { return 0 }
            noteCookieStateUnverified()
            return 0
        } catch {
            guard isCaptureAllowed(expectedEpoch, site: site) else { return 0 }
            storageError = error.localizedDescription
            return 0
        }
    }

    func site(for host: String) -> ReaderSavedSite? {
        guard let normalized = ReaderCookieHost.normalize(host),
              let site = ReaderCookieSiteScope.site(for: normalized) else { return nil }
        if let exact = sites.first(where: { $0.host == normalized }) {
            return exact
        }
        guard ReaderCookieSiteScope.isAliasSite(site) else { return nil }
        return sites.first {
            ReaderCookieHost.belongsToSite(domain: $0.host, site: site)
        }
    }

    /// Cookies to replay into a new ephemeral reader session.
    func cookiesForInjection(host: String) async -> [HTTPCookie] {
        await prepare()
        return await vault.cookies(matching: host)
    }

    /// Cookies to replay for a short link and its sign-in site.
    func cookiesForInjection(hosts: [String]) async -> [HTTPCookie] {
        await prepare()
        return await vault.cookies(forInjectionHosts: hosts)
    }

    func hasSite(_ host: String) -> Bool {
        site(for: host) != nil
    }

    @discardableResult
    func removeSite(_ host: String) async -> Bool {
        guard let site = ReaderCookieSiteScope.site(for: host),
              !isClearingCookies, !cookieRecoveryPending, !sitesBeingRemoved.contains(site) else { return false }
        let allSitesEpoch = cookieCaptureEpoch.allSites
        sitesBeingRemoved.insert(site)
        defer { sitesBeingRemoved.remove(site) }
        do {
            try await vault.removeSites(forSite: host)
            guard !isClearingCookies, allSitesEpoch == cookieCaptureEpoch.allSites else { return false }
            cookieCaptureEpoch.sites[site] = UUID()
            let summaryEpoch = cookieCaptureEpoch
            let updatedSites = await vault.siteSummaries()
            guard !isClearingCookies, allSitesEpoch == cookieCaptureEpoch.allSites else { return false }
            if summaryEpoch == cookieCaptureEpoch { sites = updatedSites }
            return true
        } catch ReaderCookieVaultError.durabilityUnknown {
            guard !isClearingCookies, allSitesEpoch == cookieCaptureEpoch.allSites else { return false }
            cookieCaptureEpoch.sites[site] = UUID()
            let summaryEpoch = cookieCaptureEpoch
            let updatedSites = await vault.siteSummaries()
            guard !isClearingCookies, allSitesEpoch == cookieCaptureEpoch.allSites else { return false }
            if summaryEpoch == cookieCaptureEpoch { sites = updatedSites }
            noteCookieDurabilityUnknown()
            return false
        } catch ReaderCookieVaultError.stateUnverified {
            guard !isClearingCookies, allSitesEpoch == cookieCaptureEpoch.allSites else { return false }
            noteCookieStateUnverified()
            return false
        } catch {
            guard !isClearingCookies, allSitesEpoch == cookieCaptureEpoch.allSites else { return false }
            storageError = error.localizedDescription
            return false
        }
    }

    func clearCookies() async {
        guard !isClearingCookies else { return }
        isClearingCookies = true
        defer { isClearingCookies = false }
        await prepare()
        do {
            try await vault.clear()
            cookieCaptureEpoch = ReaderCookieCaptureEpoch()
            sites = []
            cookieRecoveryRevision = UUID()
            cookieRecoveryPending = false
            cookieDurabilityRevision = UUID()
            cookieDurabilityPending = false
            storageError = nil
        } catch ReaderCookieVaultError.durabilityUnknown {
            cookieCaptureEpoch = ReaderCookieCaptureEpoch()
            sites = []
            noteCookieDurabilityUnknown()
        } catch ReaderCookieVaultError.stateUnverified {
            noteCookieStateUnverified()
        } catch {
            if await vault.requiresReconciliation {
                noteCookieStateUnverified()
            } else {
                storageError = error.localizedDescription
            }
        }
    }
}
