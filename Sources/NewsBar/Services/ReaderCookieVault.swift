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
        var changed = migrateLegacyDomainsIfNeeded()
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

        var seen = Set<String>()
        let stored = cookies
            .filter { ReaderCookieHost.matches(host: host, domain: $0.domain) }
            .compactMap { ReaderStoredCookie(cookie: $0, now: now) }
            .filter { !$0.isExpired(now: now) }
            .filter { seen.insert($0.identity).inserted }
        let limited = Array(Self.prioritized(stored).prefix(Self.maxCookiesPerSite))

        if limited.isEmpty {
            guard allowEmptyRemoval,
                  let index = snapshot.sites.firstIndex(where: { $0.host == host }) else { return 0 }
            snapshot.sites.remove(at: index)
            pruneGlobal(now: now)
            try await persist()
            return 0
        }

        // Remove duplicate identities from other site entries (for example a
        // login captured on both weibo.com and passport.weibo.com) so one
        // cookie does not consume two slots in the global budget.
        let identities = Set(limited.map(\.identity))
        var didDedup = false
        for index in snapshot.sites.indices where snapshot.sites[index].host != host {
            let before = snapshot.sites[index].cookies.count
            snapshot.sites[index].cookies.removeAll { identities.contains($0.identity) }
            if snapshot.sites[index].cookies.count != before { didDedup = true }
        }
        if didDedup {
            snapshot.sites.removeAll { $0.cookies.isEmpty }
        }

        if let index = snapshot.sites.firstIndex(where: { $0.host == host }),
           Self.signature(snapshot.sites[index].cookies) == Self.signature(limited) {
            if didDedup { try await persist() }
            return limited.count
        }

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = snapshot.sites.firstIndex(where: { $0.host == host }) {
            snapshot.sites[index].cookies = limited
            snapshot.sites[index].updatedAt = now
            if let cleanTitle, !cleanTitle.isEmpty {
                snapshot.sites[index].title = cleanTitle
            }
        } else {
            snapshot.sites.append(
                ReaderSavedSite(
                    host: host,
                    title: (cleanTitle?.isEmpty == false) ? cleanTitle : nil,
                    savedAt: now,
                    updatedAt: now,
                    cookies: limited
                )
            )
        }
        pruneGlobal(now: now)
        try await persist()
        return limited.count
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
        guard let host = ReaderCookieHost.normalize(rawHost) else { return false }
        return snapshot.sites.contains { $0.host == host }
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

    private func pruneGlobal(now: Date) {
        snapshot.sites.sort { $0.updatedAt > $1.updatedAt }
        var kept: [ReaderSavedSite] = []
        var total = 0
        for var site in snapshot.sites {
            site.cookies = site.validCookies(now: now)
            guard !site.cookies.isEmpty else { continue }

            if total + site.cookies.count <= Self.maxCookiesTotal {
                kept.append(site)
                total += site.cookies.count
                continue
            }

            // Never partially truncate an older site: a partial cookie jar is
            // worse than evicting it whole because the missing cookie is often
            // the auth one. The newest site is the sole exception, since it may
            // itself exceed the total budget.
            if kept.isEmpty {
                site.cookies = Array(Self.prioritized(site.cookies).prefix(Self.maxCookiesTotal))
                if !site.cookies.isEmpty {
                    kept.append(site)
                    total += site.cookies.count
                }
            }
        }
        snapshot.sites = kept
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

    /// v1 stored domains without their leading dot, so a `.weibo.com` cookie
    /// became host-only on replay. Promote only entries we can identify as
    /// domain cookies; do not broaden arbitrary host-only cookies.
    private func migrateLegacyDomainsIfNeeded() -> Bool {
        guard snapshot.version < ReaderCookieSnapshot.currentVersion else { return false }
        for siteIndex in snapshot.sites.indices {
            let siteHost = snapshot.sites[siteIndex].host
            for cookieIndex in snapshot.sites[siteIndex].cookies.indices {
                let cookie = snapshot.sites[siteIndex].cookies[cookieIndex]
                guard !cookie.domain.hasPrefix("."),
                      Self.shouldPromoteLegacyDomain(cookie, siteHost: siteHost) else { continue }
                snapshot.sites[siteIndex].cookies[cookieIndex].domain = "." + cookie.domain
            }
        }
        snapshot.version = ReaderCookieSnapshot.currentVersion
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
        snapshot.sites.sort { $0.updatedAt > $1.updatedAt }
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
