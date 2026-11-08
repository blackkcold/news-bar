import Foundation

struct WeiboMonitorLoadResult: Sendable {
    var users: [WeiboMonitorUser]
    var postsByUID: [String: [WeiboPost]]
    var issues: [String]
    /// Accounts whose posts file exists but could not be read. The service must
    /// not overwrite these files with a partial in-memory array.
    var unloadedUIDs: Set<String>

    static let empty = WeiboMonitorLoadResult(
        users: [],
        postsByUID: [:],
        issues: [],
        unloadedUIDs: []
    )
}

private struct WeiboMonitorSnapshotFile: Codable {
    var version: Int
    var updatedAt: Date
    var users: [WeiboMonitorUser]
}

private struct WeiboMonitorPostsFile: Codable {
    var version: Int
    var uid: String
    var posts: [WeiboPost]
}

/// Owns every byte the monitor writes. Reads use `Data(contentsOf:)` because
/// `PrivateFile` is a write-only helper; writes always go through it so the
/// directory stays 0700 and every file is created 0600 and renamed atomically.
///
/// The critical rule here: a failed read is not an empty database. Deleting
/// posts because monitor.json was transiently unreadable would destroy the
/// user's entire history, so only a fully loaded monitor file may trigger
/// orphan cleanup, and unreadable posts files are quarantined instead of being
/// overwritten.
actor WeiboMonitorStore {
    static let currentVersion = 1
    static let maxPostsPerAccount = 200
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    private let root: URL
    private let monitorURL: URL
    private let postsDirectory: URL
    private var didPrepare = false
    private(set) var loadIssues: [String] = []

    init(root: URL = WeiboMonitorStore.defaultRoot()) {
        self.root = root
        self.monitorURL = root.appendingPathComponent("monitor.json")
        self.postsDirectory = root.appendingPathComponent("posts", isDirectory: true)
    }

    static func defaultRoot() -> URL {
        if TestIsolation.isActive {
            return TestIsolation.directory("WeiboMonitor")
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("com.newsbar.app", isDirectory: true)
            .appendingPathComponent("WeiboMonitor", isDirectory: true)
    }

    func load(now: Date = Date()) async -> WeiboMonitorLoadResult {
        await prepareDirectories()
        var issues: [String] = []
        var unloaded: Set<String> = []
        var users: [WeiboMonitorUser] = []
        var monitorIsAuthoritative = false
        var canCleanOrphans = false

        switch readFile(monitorURL) {
        case .missing:
            // No monitor file: posts may still exist from a previous install or
            // a manual reset. Rebuild from them rather than deleting them.
            canCleanOrphans = true
        case .failed:
            issues.append("monitor.unreadable")
        case .data(let data):
            do {
                let snapshot = try Self.decodeSnapshot(data)
                if snapshot.version == Self.currentVersion {
                    users = snapshot.users
                    monitorIsAuthoritative = true
                    canCleanOrphans = true
                } else {
                    try? archiveCorrupt(monitorURL)
                    issues.append("monitor.version")
                }
            } catch {
                try? archiveCorrupt(monitorURL)
                issues.append("monitor.corrupt")
            }
        }

        if !monitorIsAuthoritative {
            let rebuilt = rebuildUsersFromPosts(
                now: now,
                issues: &issues,
                unloaded: &unloaded
            )
            if !rebuilt.isEmpty {
                users = rebuilt
                issues.append("monitor.rebuilt")
            }
            // Never clean orphan files when the account list came from a
            // fallback; the list is not authoritative enough to delete data.
            canCleanOrphans = false
        }

        var postsByUID: [String: [WeiboPost]] = [:]
        for user in users {
            let url = postsURL(uid: user.uid)
            switch readFile(url) {
            case .missing:
                continue
            case .failed:
                issues.append("posts.unreadable.\(user.uid)")
                unloaded.insert(user.uid)
            case .data(let data):
                do {
                    let page = try Self.decodePosts(data)
                    if page.version == Self.currentVersion, page.uid == user.uid {
                        postsByUID[user.uid] = trim(posts: page.posts, now: now)
                    } else {
                        try? archiveCorrupt(url)
                        issues.append("posts.version.\(user.uid)")
                        unloaded.insert(user.uid)
                    }
                } catch {
                    try? archiveCorrupt(url)
                    issues.append("posts.corrupt.\(user.uid)")
                    unloaded.insert(user.uid)
                }
            }
        }

        if canCleanOrphans {
            let knownUIDs = Set(users.map(\.uid))
            if let files = try? FileManager.default.contentsOfDirectory(
                at: postsDirectory,
                includingPropertiesForKeys: nil
            ) {
                for file in files where file.pathExtension == "json" {
                    let uid = file.deletingPathExtension().lastPathComponent
                    if !knownUIDs.contains(uid) {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
        }

        loadIssues = issues
        return WeiboMonitorLoadResult(
            users: users,
            postsByUID: postsByUID,
            issues: issues,
            unloadedUIDs: unloaded
        )
    }

    func save(users: [WeiboMonitorUser], now: Date = Date()) throws {
        try PrivateFile.ensureDirectory(root)
        let snapshot = WeiboMonitorSnapshotFile(
            version: Self.currentVersion,
            updatedAt: now,
            users: users
        )
        let data = try Self.encode(snapshot)
        try PrivateFile.write(data, to: monitorURL, durable: true)
        try? (root as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    func savePosts(uid: String, posts: [WeiboPost], now: Date = Date()) throws {
        try PrivateFile.ensureDirectory(postsDirectory)
        let trimmed = trim(posts: posts, now: now)
        let page = WeiboMonitorPostsFile(version: Self.currentVersion, uid: uid, posts: trimmed)
        let data = try Self.encode(page)
        try PrivateFile.write(data, to: postsURL(uid: uid), durable: true)
        try? (postsDirectory as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    func deletePosts(uid: String) {
        let url = postsURL(uid: uid)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func reset() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
        didPrepare = false
        loadIssues = []
    }

    func trim(posts: [WeiboPost], now: Date) -> [WeiboPost] {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let filtered = posts
            .filter { $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
        return Array(filtered.prefix(Self.maxPostsPerAccount))
    }

    // MARK: - Files

    private enum FileRead {
        case missing
        case data(Data)
        case failed
    }

    private func readFile(_ url: URL) -> FileRead {
        _ = PrivateFile.tightenExistingFile(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .data(try Data(contentsOf: url))
        } catch {
            return .failed
        }
    }

    private func postsURL(uid: String) -> URL {
        postsDirectory.appendingPathComponent("\(uid).json")
    }

    private func prepareDirectories() async {
        guard !didPrepare else { return }
        didPrepare = true
        try? PrivateFile.ensureDirectory(root)
        try? PrivateFile.ensureDirectory(postsDirectory)
        let staleCutoff = Date().addingTimeInterval(-3600)
        PrivateFile.removeStaleTemporaries(in: root, olderThan: staleCutoff)
        PrivateFile.removeStaleTemporaries(in: postsDirectory, olderThan: staleCutoff)
    }

    /// §10.5: a corrupt monitor file is a baseline loss, not a reason to delete
    /// the posts. Reconstruct the accounts from the posts files; the first
    /// fetch after this is treated as a fresh baseline and never notifies.
    private func rebuildUsersFromPosts(
        now: Date,
        issues: inout [String],
        unloaded: inout Set<String>
    ) -> [WeiboMonitorUser] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: postsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var rebuilt: [WeiboMonitorUser] = []
        for file in files where file.pathExtension == "json" {
            let uid = file.deletingPathExtension().lastPathComponent
            switch readFile(file) {
            case .missing:
                continue
            case .failed:
                issues.append("posts.unreadable.\(uid)")
                unloaded.insert(uid)
                rebuilt.append(placeholderUser(uid: uid, now: now))
            case .data(let data):
                do {
                    let page = try Self.decodePosts(data)
                    guard page.version == Self.currentVersion,
                          page.uid == uid,
                          !page.posts.isEmpty else { continue }
                    let posts = trim(posts: page.posts, now: now)
                    guard let newest = posts.max(by: { $0.createdAt < $1.createdAt }) else {
                        continue
                    }
                    var stats = WeiboMonitorStats()
                    stats.posts7d = posts.filter {
                        $0.createdAt >= now.addingTimeInterval(-7 * 24 * 60 * 60)
                    }.count
                    stats.lastPostAt = newest.createdAt
                    rebuilt.append(
                        WeiboMonitorUser(
                            uid: uid,
                            screenName: newest.screenName.isEmpty ? "UID \(uid)" : newest.screenName,
                            avatarURL: nil,
                            priority: .p1,
                            notifyMode: .keywords,
                            enabled: true,
                            addedAt: now,
                            lastSeenMid: newest.mid,
                            lastSeenAt: newest.createdAt,
                            seenMids: Array(posts.map(\.mid).prefix(100)),
                            nextDueAt: now,
                            lastSuccessAt: nil,
                            stats: stats
                        )
                    )
                } catch {
                    try? archiveCorrupt(file)
                    issues.append("posts.corrupt.\(uid)")
                    unloaded.insert(uid)
                    rebuilt.append(placeholderUser(uid: uid, now: now))
                }
            }
        }
        return rebuilt
    }

    private func placeholderUser(uid: String, now: Date) -> WeiboMonitorUser {
        WeiboMonitorUser(
            uid: uid,
            screenName: "UID \(uid)",
            priority: .p1,
            notifyMode: .keywords,
            addedAt: now,
            nextDueAt: now,
            needsManualResume: true,
            stats: WeiboMonitorStats()
        )
    }

    private func archiveCorrupt(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8)
        let destination = url.appendingPathExtension("corrupt-\(stamp)-\(suffix)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: url, to: destination)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decodeSnapshot(_ data: Data) throws -> WeiboMonitorSnapshotFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WeiboMonitorSnapshotFile.self, from: data)
    }

    private static func decodePosts(_ data: Data) throws -> WeiboMonitorPostsFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WeiboMonitorPostsFile.self, from: data)
    }
}
