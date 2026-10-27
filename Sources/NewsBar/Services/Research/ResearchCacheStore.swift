import Foundation

enum ResearchCacheKind: String, Codable, Sendable, CaseIterable {
    case search
    case pages
}

struct ResearchCacheStats: Sendable, Equatable {
    var removedFiles = 0
    var removedBytes: Int64 = 0
    var totalBytes: Int64 = 0
}

/// Disposable research cache. Search snapshots live 12 hours; fetched pages 72.
/// Cache misses are always safe: the report and its evidence summaries remain
/// readable after the cache is cleared.
actor ResearchCacheStore {
    static let shared = ResearchCacheStore()
    static let searchTTL: TimeInterval = 12 * 3600
    static let pagesTTL: TimeInterval = 72 * 3600

    private struct Entry: Codable {
        /// Only the digest is persisted; the query/page key itself never lands
        /// on disk in cleartext.
        let keyHash: String
        let createdAt: Date
        let payload: Data
    }

    private struct FileRecord {
        let url: URL
        let kind: ResearchCacheKind
        let fileKey: String
        let size: Int64
        let modifiedAt: Date
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    /// Page-cache lifetime. Defaults to 72 hours; the settings page may widen or
    /// narrow it. Search snapshots keep their fixed 12-hour window.
    private var pageTTL: TimeInterval = ResearchCacheStore.pagesTTL

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL ?? ResearchPaths.researchCacheDirectory
        self.fileManager = fileManager
    }

    func prepare() {
        try? ensureDirectories()
    }

    /// Applies the user's page-cache TTL setting. Search snapshots keep the
    /// fixed 12-hour product window.
    func setPagesTTL(hours: Int) {
        pageTTL = TimeInterval(max(1, hours)) * 3600
    }

    func store(
        _ payload: Data,
        kind: ResearchCacheKind,
        key: String,
        now: Date = Date()
    ) {
        guard let url = try? ensureDirectories()
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(fileKey(kind: kind, key: key) + ".json") else {
            return
        }
        let entry = Entry(keyHash: ContentIdentity.digest(key), createdAt: now, payload: payload)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try data.write(to: url, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Eviction uses the file timestamp; stamping it here keeps tests and
            // long-running sessions on the same clock.
            try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        } catch {
            // Cache writes are best effort.
        }
    }

    func load(kind: ResearchCacheKind, key: String, now: Date = Date()) -> Data? {
        let url = directoryURL
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(fileKey(kind: kind, key: key) + ".json")
        guard let record = fileRecord(at: url, kind: kind) else { return nil }
        guard now.timeIntervalSince(record.modifiedAt) <= ttl(for: kind) else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return entry.payload
    }

    func remove(kind: ResearchCacheKind, key: String) {
        let url = directoryURL
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(fileKey(kind: kind, key: key) + ".json")
        try? fileManager.removeItem(at: url)
    }

    func clear(kind: ResearchCacheKind) {
        let urls = (try? fileManager.contentsOfDirectory(
            at: kindDirectory(kind), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls { try? fileManager.removeItem(at: url) }
    }

    func clearAll() {
        for kind in ResearchCacheKind.allCases { clear(kind: kind) }
    }

    func totalBytes() -> Int64 {
        allFiles().reduce(Int64(0)) { $0 + $1.size }
    }

    /// Removes expired files first, then trims the remaining cache to 90% of
    /// `maxBytes` by oldest modification time. Files whose hashed key is in
    /// `protecting` (a running research still reading them) are skipped.
    @discardableResult
    func enforceLimits(
        now: Date = Date(),
        maxBytes: Int64,
        protecting: Set<String> = [],
        protectingSince: Date? = nil
    ) -> ResearchCacheStats {
        var stats = ResearchCacheStats()
        var files = allFiles()

        func isProtected(_ file: FileRecord) -> Bool {
            if protecting.contains(file.fileKey) { return true }
            if let protectingSince, file.modifiedAt >= protectingSince { return true }
            return false
        }

        for file in files where !isProtected(file) {
            guard now.timeIntervalSince(file.modifiedAt) > ttl(for: file.kind) else { continue }
            if remove(file) {
                stats.removedFiles += 1
                stats.removedBytes += file.size
            }
        }

        files = allFiles()
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        let target = maxBytes > 0 ? maxBytes * 9 / 10 : 0
        if total > maxBytes {
            let candidates = files
                .filter { !isProtected($0) }
                .sorted { $0.modifiedAt < $1.modifiedAt }
            for file in candidates {
                guard total > target else { break }
                if remove(file) {
                    total -= file.size
                    stats.removedFiles += 1
                    stats.removedBytes += file.size
                }
            }
        }

        stats.totalBytes = files
            .filter { fileManager.fileExists(atPath: $0.url.path) }
            .reduce(Int64(0)) { $0 + $1.size }
        return stats
    }

    /// Dry run for the settings confirmation: how many files (and bytes) would
    /// `enforceLimits` remove at the proposed ceiling? Nothing is deleted.
    func previewEnforcement(now: Date = Date(), maxBytes: Int64) -> ResearchCacheStats {
        var stats = ResearchCacheStats()
        var files = allFiles()

        for file in files where now.timeIntervalSince(file.modifiedAt) > ttl(for: file.kind) {
            stats.removedFiles += 1
            stats.removedBytes += file.size
        }

        var total = files.reduce(Int64(0)) { $0 + $1.size }
        let target = maxBytes > 0 ? maxBytes * 9 / 10 : 0
        if total > maxBytes {
            let candidates = files
                .filter { now.timeIntervalSince($0.modifiedAt) <= ttl(for: $0.kind) }
                .sorted { $0.modifiedAt < $1.modifiedAt }
            for file in candidates {
                guard total > target else { break }
                total -= file.size
                stats.removedFiles += 1
                stats.removedBytes += file.size
            }
        }
        stats.totalBytes = max(0, total)
        return stats
    }

    func fileKey(kind: ResearchCacheKind, key: String) -> String {
        ContentIdentity.digest("\(kind.rawValue)\n\(key)")
    }

    func hasFile(kind: ResearchCacheKind, key: String) -> Bool {
        let url = directoryURL
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(fileKey(kind: kind, key: key) + ".json")
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Files

    private func ttl(for kind: ResearchCacheKind) -> TimeInterval {
        switch kind {
        case .search: return Self.searchTTL
        case .pages: return pageTTL
        }
    }

    private func kindDirectory(_ kind: ResearchCacheKind) -> URL {
        directoryURL.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    @discardableResult
    private func ensureDirectories() throws -> URL {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for kind in ResearchCacheKind.allCases {
            try fileManager.createDirectory(
                at: kindDirectory(kind),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: kindDirectory(kind).path
            )
        }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        var directory = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directoryURL
    }

    private func allFiles() -> [FileRecord] {
        ResearchCacheKind.allCases.flatMap { kind -> [FileRecord] in
            let urls = (try? fileManager.contentsOfDirectory(
                at: kindDirectory(kind),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls.compactMap { fileRecord(at: $0, kind: kind) }
        }
    }

    private func fileRecord(at url: URL, kind: ResearchCacheKind) -> FileRecord? {
        guard url.pathExtension.lowercased() == "json" else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileRecord(
            url: url,
            kind: kind,
            fileKey: url.deletingPathExtension().lastPathComponent,
            size: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate ?? .distantPast
        )
    }

    private func remove(_ file: FileRecord) -> Bool {
        do {
            try fileManager.removeItem(at: file.url)
            return true
        } catch {
            return false
        }
    }
}
