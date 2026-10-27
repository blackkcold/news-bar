import Foundation

protocol ReaderCookiePersisting: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
    func clear() async throws
}

enum ReaderCookieVaultError: LocalizedError {
    case encodingFailed
    case persistenceFailed
    case corruptedStore

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Cookie 数据编码失败"
        case .persistenceFailed: return "Cookie 加密写入失败"
        case .corruptedStore: return "已保存的 Cookie 数据无法读取"
        }
    }
}

/// Persists the vault through the existing machine-bound AES-GCM store.
/// The payload is a JSON string inside the encrypted `apikeys.enc` container.
struct EncryptedReaderCookiePersistence: ReaderCookiePersisting {
    static let account = "reader-cookie-vault"

    private let store = EncryptedKeyStore()

    func load() async throws -> Data? {
        guard let value = await store.readAPIKey(account: Self.account) else { return nil }
        return value.data(using: .utf8)
    }

    func save(_ data: Data) async throws {
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw ReaderCookieVaultError.encodingFailed
        }
        guard await store.saveAPIKey(value, account: Self.account) else {
            throw ReaderCookieVaultError.persistenceFailed
        }
    }

    func clear() async throws {
        await store.deleteAPIKey(account: Self.account)
    }
}

/// Per-site first-party cookie memory for the Dashboard reader.
///
/// The reader still uses an ephemeral `WKWebsiteDataStore`; this vault only stores
/// cookies the user visited, filtered to the first-party domain, and replays them
/// into the next ephemeral session. That keeps localStorage/IndexedDB and
/// third-party cookies out of the picture while logins survive relaunches.
actor ReaderCookieVault {
    static let maxCookiesPerSite = 160
    static let maxCookiesTotal = 600
    static let maxPayloadBytes = 512 * 1024

    /// Known sign-in cookie names. They must survive per-site truncation and
    /// are the safest legacy entries to promote to domain scope during v1→v2.
    static let authCookieNames: Set<String> = [
        "sub", "subp", "ssologinstate", "xsrf-token", "x-csrf-token",
        "scf", "alf", "ulv", "login_sid_t", "srt", "sina_mode",
        "wbstorage", "cross_origin_proto", "session", "sessionid",
        "sid", "token", "auth", "remember_token", "csrftoken",
        // Bilibili sign-in and device-ticket cookies
        "sessdata", "bili_jct", "dedeuserid", "dedeuserid__ckmd5",
        "buvid3", "buvid4", "b_nut", "bili_ticket",
        // Weibo sign-in cookie
        "wbpsess",
    ]

    /// Cookies that appear only after a real sign-in.
    ///
    /// Deliberately narrower than `authCookieNames`: `buvid3`/`b_nut` are handed
    /// to anonymous visitors, and generic names (`session`, `token`, `auth`,
    /// `sid`) are set by sites with no sign-in at all. Only this set promotes a
    /// site to the sign-in reservation in the global cookie budget.
    static let signInCookieNames: Set<String> = [
        "sub", "subp", "ssologinstate", "login_sid_t", "remember_token",
        "xsrf-token", "x-csrf-token", "wbpsess",
        "sessdata", "bili_jct", "dedeuserid", "dedeuserid__ckmd5",
    ]

    private let persistence: ReaderCookiePersisting
    private var snapshot = ReaderCookieSnapshot()
    private var isLoaded = false
    private(set) var loadError: String?

    init(persistence: ReaderCookiePersisting = EncryptedReaderCookiePersistence()) {
        self.persistence = persistence
    }

    func prepare(now: Date = Date()) async {
        guard !isLoaded else { return }
        isLoaded = true
        do {
            if let data = try await persistence.load(), !data.isEmpty {
                do {
                    snapshot = try Self.decode(data)
                } catch {
                    snapshot = ReaderCookieSnapshot()
                    loadError = ReaderCookieVaultError.corruptedStore.localizedDescription
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
        var changed = migrateIfNeeded()
        if consolidateSites() { changed = true }
        if prune(now: now) { changed = true }
        if changed { try? await persist() }
    }

    /// Replays every unexpired cookie whose domain covers `host`.
    func cookies(matching rawHost: String, now: Date = Date()) -> [HTTPCookie] {
        guard let host = ReaderCookieHost.normalize(rawHost) else { return [] }
        var seen = Set<String>()
        return snapshot.sites
            .flatMap(\.cookies)
            .filter { !$0.isExpired(now: now) && ReaderCookieHost.matches(host: host, domain: $0.domain) }
            .sorted { $0.storedAt > $1.storedAt }
            .filter { seen.insert($0.identity).inserted }
            .compactMap { $0.makeCookie() }
    }

    /// Replays the union of cookies for a set of hosts.
    ///
    /// When a short link (`b23.tv`) is the initial URL, its sign-in cookies
    /// live under a different domain (`.bilibili.com`). The alias-aware site
    /// membership selects that jar; WebKit will still only send each cookie to
    /// the host its own domain covers.
    func cookies(forInjectionHosts rawHosts: [String], now: Date = Date()) -> [HTTPCookie] {
        let hosts = rawHosts.compactMap(ReaderCookieHost.normalize)
        guard !hosts.isEmpty else { return [] }
        let sites = Set(hosts.compactMap(ReaderCookieSiteScope.site(for:)))
        var seen = Set<String>()
        return snapshot.sites
            .flatMap(\.cookies)
            .filter { !$0.isExpired(now: now) }
            .filter { cookie in
                if hosts.contains(where: { ReaderCookieHost.matches(host: $0, domain: cookie.domain) }) {
                    return true
                }
                return sites.contains {
                    ReaderCookieHost.belongsToSite(domain: cookie.domain, site: $0)
                }
            }
            .sorted { $0.storedAt > $1.storedAt }
            .filter { seen.insert($0.identity).inserted }
            .compactMap { $0.makeCookie() }
    }

    /// Snapshots the current site's first-party cookies.
    /// - Parameter allowEmptyRemoval: automatic capture removes a site after a
    ///   deliberate logout; an explicit save with nothing to store is a no-op.
    @discardableResult
    func upsert(
        cookies: [HTTPCookie],
        host rawHost: String,
        title: String? = nil,
        allowEmptyRemoval: Bool,
        now: Date = Date()
    ) async throws -> Int {
        await prepare(now: now)
        guard let host = ReaderCookieHost.normalize(rawHost) else { return 0 }
        let site = ReaderCookieSiteScope.site(for: host) ?? host
        let isAliasSite = ReaderCookieSiteScope.isAliasSite(site)

        var seen = Set<String>()
        let stored = cookies
            .filter { cookie in
                if ReaderCookieHost.matches(host: host, domain: cookie.domain) {
                    return true
                }
                // Known short-link/SSO sites share one jar. A capture on
                // b23.tv must not discard the .bilibili.com sign-in cookies
                // that the store still contains; WebKit still scopes each
                // cookie to its own domain when sending it.
                return isAliasSite && ReaderCookieHost.belongsToSite(domain: cookie.domain, site: site)
            }
            .compactMap { ReaderStoredCookie(cookie: $0, now: now) }
            .filter { !$0.isExpired(now: now) }
            .filter { seen.insert($0.identity).inserted }
        let limited = Array(Self.prioritized(stored).prefix(Self.maxCookiesPerSite))

        if limited.isEmpty {
            guard allowEmptyRemoval,
                  let index = siteIndex(for: host, site: site) else { return 0 }
            snapshot.sites.remove(at: index)
            pruneGlobal(now: now)
            try await persist()
            return 0
        }

        let targetHost = siteIndex(for: host, site: site).map { snapshot.sites[$0].host }
        // Remove duplicate identities from other site entries (for example a
        // login captured on both weibo.com and passport.weibo.com) so one
        // cookie does not consume two slots in the global budget. Never strip
        // the entry we are about to update.
        let identities = Set(limited.map(\.identity))
        var didDedup = false
        for index in snapshot.sites.indices {
            if snapshot.sites[index].host == host { continue }
            if let targetHost, snapshot.sites[index].host == targetHost { continue }
            let before = snapshot.sites[index].cookies.count
            snapshot.sites[index].cookies.removeAll { identities.contains($0.identity) }
            if snapshot.sites[index].cookies.count != before { didDedup = true }
        }
        if didDedup {
            snapshot.sites.removeAll { $0.cookies.isEmpty }
        }

        let targetIndex = siteIndex(for: host, site: site)
        if let targetIndex,
           Self.signature(snapshot.sites[targetIndex].cookies) == Self.signature(limited) {
            if didDedup { try await persist() }
            return limited.count
        }

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let targetIndex {
            snapshot.sites[targetIndex].host = site
            snapshot.sites[targetIndex].cookies = limited
            snapshot.sites[targetIndex].updatedAt = now
            if let cleanTitle, !cleanTitle.isEmpty {
                snapshot.sites[targetIndex].title = cleanTitle
            }
        } else {
            snapshot.sites.append(
                ReaderSavedSite(
                    host: site,
                    title: (cleanTitle?.isEmpty == false) ? cleanTitle : nil,
                    savedAt: now,
                    updatedAt: now,
                    cookies: limited
                )
            )
        }
        pruneGlobal(now: now)
        try await persist()
        // Report what survived the global budget, not what was offered: a
        // sign-in jar can be trimmed once the other sites were kept.
        return snapshot.sites.first { $0.host == site }?.cookies.count ?? 0
    }

    /// Finds the stored entry for a page host, including a known alias site
    /// recorded under a sibling host (`www.bilibili.com` for a `b23.tv` page).
    private func siteIndex(for host: String, site: String) -> Int? {
        if let exact = snapshot.sites.firstIndex(where: { $0.host == host }) {
            return exact
        }
        guard ReaderCookieSiteScope.isAliasSite(site) else { return nil }
        return snapshot.sites.firstIndex {
            ReaderCookieHost.belongsToSite(domain: $0.host, site: site)
        }
    }

    func siteSummaries(now: Date = Date()) -> [ReaderSavedSite] {
        snapshot.sites
            .map { site in
                var copy = site
                copy.cookies = site.validCookies(now: now)
                return copy
            }
            .filter { !$0.cookies.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func hasSite(_ rawHost: String) -> Bool {
        guard let host = ReaderCookieHost.normalize(rawHost),
              let site = ReaderCookieSiteScope.site(for: host) else { return false }
        if snapshot.sites.contains(where: { $0.host == host }) { return true }
        guard ReaderCookieSiteScope.isAliasSite(site) else { return false }
        return snapshot.sites.contains {
            ReaderCookieHost.belongsToSite(domain: $0.host, site: site)
        }
    }

    func totalCookieCount(now: Date = Date()) -> Int {
        snapshot.sites.reduce(0) { partial, site in
            partial + site.validCookies(now: now).count
        }
    }

    func removeSite(_ rawHost: String) async throws {
        guard let host = ReaderCookieHost.normalize(rawHost) else { return }
        let before = snapshot.sites.count
        snapshot.sites.removeAll { $0.host == host }
        guard snapshot.sites.count != before else { return }
        try await persist()
    }

    /// Removes every entry that belongs to the same alias site.
    func removeSites(forSite rawHost: String) async throws {
        guard let host = ReaderCookieHost.normalize(rawHost),
              let site = ReaderCookieSiteScope.site(for: host) else { return }
        let before = snapshot.sites.count
        snapshot.sites.removeAll { ReaderCookieHost.belongsToSite(domain: $0.host, site: site) }
        guard snapshot.sites.count != before else { return }
        try await persist()
    }

    func clear() async throws {
        snapshot = ReaderCookieSnapshot()
        isLoaded = true
        loadError = nil
        try await persistence.clear()
    }

    // MARK: - Pruning

    @discardableResult
    private func prune(now: Date) -> Bool {
        var changed = false
        for index in snapshot.sites.indices {
            let valid = snapshot.sites[index].validCookies(now: now)
            if valid.count != snapshot.sites[index].cookies.count {
                snapshot.sites[index].cookies = valid
                changed = true
            }
        }
        let before = snapshot.sites.count
        snapshot.sites.removeAll { $0.cookies.isEmpty }
        if snapshot.sites.count != before { changed = true }
        let totalBefore = totalCount
        pruneGlobal(now: now)
        if totalCount != totalBefore { changed = true }
        return changed
    }

    private var totalCount: Int {
        snapshot.sites.reduce(0) { $0 + $1.cookies.count }
    }

    /// Fits the store into the global budget without losing a sign-in.
    ///
    /// Sign-in cookies are reserved first, so a second (or third) signed-in
    /// site survives even when the first one filled the budget with filler
    /// cookies. Ordinary sites then fill what is left, whole jar at a time.
    private func pruneGlobal(now: Date) {
        snapshot.sites.sort(by: Self.signInFirst)
        var total = 0

        // 1. Reserve every sign-in cookie in the store.
        var signInSites: [(site: ReaderSavedSite, reserved: [ReaderStoredCookie])] = []
        for site in snapshot.sites where Self.isSignInSite(site) {
            let room = Self.maxCookiesTotal - total
            guard room > 0 else { break }
            let signIn = site.validCookies(now: now)
                .filter { Self.signInCookieNames.contains($0.name.lowercased()) }
            let taken = Array(Self.prioritized(signIn).prefix(room))
            guard !taken.isEmpty else { continue }
            signInSites.append((site, taken))
            total += taken.count
        }

        // 2. Ordinary sites fill what is left, newest first.
        var ordinary: [ReaderSavedSite] = []
        for var site in snapshot.sites where !Self.isSignInSite(site) {
            site.cookies = site.validCookies(now: now)
            guard !site.cookies.isEmpty else { continue }
            if total + site.cookies.count <= Self.maxCookiesTotal {
                ordinary.append(site)
                total += site.cookies.count
            } else if ordinary.isEmpty, signInSites.isEmpty {
                // A single site may exceed the whole budget on its own.
                site.cookies = Array(Self.prioritized(site.cookies).prefix(Self.maxCookiesTotal))
                if !site.cookies.isEmpty {
                    ordinary.append(site)
                    total += site.cookies.count
                }
            }
        }

        // 3. Give each signed-in site back the filler cookies that still fit.
        for index in signInSites.indices {
            var cookies = signInSites[index].reserved
            let identities = Set(cookies.map(\.identity))
            let rest = signInSites[index].site.validCookies(now: now)
                .filter { !identities.contains($0.identity) }
            for cookie in Self.prioritized(rest) {
                guard total < Self.maxCookiesTotal else { break }
                cookies.append(cookie)
                total += 1
            }
            signInSites[index].site.cookies = cookies
        }

        snapshot.sites = signInSites.map(\.site) + ordinary
    }

    // MARK: - Ordering & legacy migration

    private static func authPriority(_ name: String) -> Int {
        let lower = name.lowercased()
        if authCookieNames.contains(lower) { return 0 }
        if lower.contains("token") || lower.contains("session") || lower.contains("auth")
            || lower.contains("login") || lower.contains("remember") {
            return 1
        }
        return 2
    }

    private static func isSignInSite(_ site: ReaderSavedSite) -> Bool {
        site.cookies.contains { signInCookieNames.contains($0.name.lowercased()) }
    }

    /// Sign-in sites first, then newest updated site.
    private static func signInFirst(_ lhs: ReaderSavedSite, _ rhs: ReaderSavedSite) -> Bool {
        let left = isSignInSite(lhs)
        let right = isSignInSite(rhs)
        if left != right { return left }
        return lhs.updatedAt > rhs.updatedAt
    }

    /// Stable sort: sign-in cookies first, then the order WebKit reported.
    private static func prioritized(_ cookies: [ReaderStoredCookie]) -> [ReaderStoredCookie] {
        cookies.enumerated()
            .sorted { lhs, rhs in
                let left = authPriority(lhs.element.name)
                let right = authPriority(rhs.element.name)
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Runs each migration step exactly once. Version 2 already fixed the
    /// leading-dot bug; version 3 groups page hosts under their sign-in site.
    private func migrateIfNeeded() -> Bool {
        guard snapshot.version < ReaderCookieSnapshot.currentVersion else { return false }
        var changed = false
        if snapshot.version < 2 {
            changed = migrateLegacyDomains() || changed
            snapshot.version = 2
            changed = true
        }
        if snapshot.version < 3 {
            changed = consolidateSites() || changed
            snapshot.version = 3
            changed = true
        }
        return changed
    }

    /// v1 stored domains without their leading dot, so a `.weibo.com` cookie
    /// became host-only on replay. Promote only entries we can identify as
    /// domain cookies; do not broaden arbitrary host-only cookies.
    private func migrateLegacyDomains() -> Bool {
        var changed = false
        for siteIndex in snapshot.sites.indices {
            let siteHost = snapshot.sites[siteIndex].host
            for cookieIndex in snapshot.sites[siteIndex].cookies.indices {
                let cookie = snapshot.sites[siteIndex].cookies[cookieIndex]
                guard !cookie.domain.hasPrefix("."),
                      Self.shouldPromoteLegacyDomain(cookie, siteHost: siteHost) else { continue }
                snapshot.sites[siteIndex].cookies[cookieIndex].domain = "." + cookie.domain
                changed = true
            }
        }
        return changed
    }

    /// Stores one entry per sign-in site (`bilibili.com`) instead of one per
    /// page host (`www.bilibili.com`, `passport.bilibili.com`). Merge duplicates
    /// by cookie identity, keeping the newest stored value.
    ///
    /// Runs on every load, not only during the v3 migration: widening the alias
    /// table (for example adding `bili2233.cn`) lets a store written by an older
    /// build hold two entries for one site, and renaming one of them later would
    /// leave duplicate host ids behind.
    private func consolidateSites() -> Bool {
        guard !snapshot.sites.isEmpty else { return false }
        var grouped: [String: ReaderSavedSite] = [:]
        for site in snapshot.sites {
            let key = ReaderCookieSiteScope.site(for: site.host) ?? site.host
            var copy = site
            copy.host = key
            guard var existing = grouped[key] else {
                grouped[key] = copy
                continue
            }

            var byIdentity: [String: ReaderStoredCookie] = [:]
            for cookie in existing.cookies {
                byIdentity[cookie.identity] = cookie
            }
            for cookie in copy.cookies {
                if let old = byIdentity[cookie.identity], old.storedAt > cookie.storedAt {
                    continue
                }
                byIdentity[cookie.identity] = cookie
            }
            existing.cookies = byIdentity.values.sorted { $0.storedAt > $1.storedAt }
            existing.savedAt = min(existing.savedAt, copy.savedAt)
            existing.updatedAt = max(existing.updatedAt, copy.updatedAt)
            if existing.title?.isEmpty != false,
               let title = copy.title,
               !title.isEmpty {
                existing.title = title
            }
            grouped[key] = existing
        }

        let migrated = grouped.values.sorted { $0.updatedAt > $1.updatedAt }
        guard migrated != snapshot.sites else { return false }
        snapshot.sites = migrated
        return true
    }

    private static func shouldPromoteLegacyDomain(_ cookie: ReaderStoredCookie, siteHost: String) -> Bool {
        guard cookie.domain.contains(".") else { return false }
        if let host = ReaderCookieHost.normalize(siteHost),
           host != cookie.domain,
           host.hasSuffix("." + cookie.domain) {
            return true
        }
        return authCookieNames.contains(cookie.name.lowercased())
    }

    // MARK: - Persistence

    private static func signature(_ cookies: [ReaderStoredCookie]) -> String {
        cookies.map { cookie in
            "\(cookie.name)|\(cookie.domain)|\(cookie.path)|\(cookie.value)|\(cookie.expiresAt?.timeIntervalSince1970 ?? -1)"
        }
        .sorted()
        .joined(separator: "\n")
    }

    private func persist() async throws {
        snapshot.sites.sort(by: Self.signInFirst)
        var data = try Self.encode(snapshot)
        while data.count > Self.maxPayloadBytes, !snapshot.sites.isEmpty {
            snapshot.sites.removeLast()
            data = try Self.encode(snapshot)
        }
        try await persistence.save(data)
    }

    private static func encode(_ snapshot: ReaderCookieSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    private static func decode(_ data: Data) throws -> ReaderCookieSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReaderCookieSnapshot.self, from: data)
    }
}
