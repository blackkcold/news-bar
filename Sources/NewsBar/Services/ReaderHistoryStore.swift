import Foundation

protocol ReaderHistoryPersisting: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
    func clear() async throws
}

/// Local JSON file under the app's Application Support directory.
/// 0700 directory, 0600 file, excluded from Time Machine.
struct FileReaderHistoryPersistence: ReaderHistoryPersisting {
    let fileURL: URL

    init(fileURL: URL = FileReaderHistoryPersistence.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("com.newsbar.app", isDirectory: true)
            .appendingPathComponent("Reader", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    func load() async throws -> Data? {
        _ = PrivateFile.tightenExistingFile(fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func save(_ data: Data) async throws {
        // The previous atomic write did not fsync either: keep the same
        // durability while making the file owner-only from creation.
        try PrivateFile.write(data, to: fileURL, durable: false)
        try? (fileURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    func clear() async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// Bounded local reading history. One row per canonical URL, visit count included.
actor ReaderHistoryStore {
    static let maxEntries = 300
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    private let persistence: ReaderHistoryPersisting
    private var snapshot = ReaderHistorySnapshot()
    private var isLoaded = false
    private(set) var loadError: String?

    init(persistence: ReaderHistoryPersisting = FileReaderHistoryPersistence()) {
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
                    snapshot = ReaderHistorySnapshot()
                    loadError = "已保存的阅读历史无法读取"
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
        if prune(now: now) {
            try? await persist()
        }
    }

    @discardableResult
    func record(url: String, title: String, host: String, now: Date = Date()) async throws -> ReaderHistoryEntry {
        await prepare(now: now)
        let canonical = ContentIdentity.canonicalURL(url)
        let normalizedHost = ReaderCookieHost.normalize(host)
            ?? ReaderCookieHost.normalize(URL(string: url)?.host)
            ?? ""
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = snapshot.entries.firstIndex(where: { $0.canonicalURL == canonical }) {
            snapshot.entries[index].lastOpenedAt = now
            snapshot.entries[index].visitCount += 1
            snapshot.entries[index].url = url
            if !cleanTitle.isEmpty { snapshot.entries[index].title = cleanTitle }
            if !normalizedHost.isEmpty { snapshot.entries[index].host = normalizedHost }
            let entry = snapshot.entries[index]
            prune(now: now)
            try await persist()
            return entry
        }

        let entry = ReaderHistoryEntry(
            id: UUID(),
            url: url,
            canonicalURL: canonical,
            title: cleanTitle.isEmpty ? url : cleanTitle,
            host: normalizedHost,
            firstOpenedAt: now,
            lastOpenedAt: now,
            visitCount: 1
        )
        snapshot.entries.append(entry)
        prune(now: now)
        try await persist()
        return entry
    }

    func all() -> [ReaderHistoryEntry] {
        snapshot.entries.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    func remove(id: UUID) async throws {
        let before = snapshot.entries.count
        snapshot.entries.removeAll { $0.id == id }
        guard snapshot.entries.count != before else { return }
        try await persist()
    }

    func clear() async throws {
        snapshot = ReaderHistorySnapshot()
        isLoaded = true
        loadError = nil
        try await persistence.clear()
    }

    // MARK: - Pruning

    @discardableResult
    private func prune(now: Date) -> Bool {
        let before = snapshot.entries.count
        let cutoff = now.addingTimeInterval(-Self.retention)
        snapshot.entries.removeAll { $0.lastOpenedAt < cutoff }
        snapshot.entries.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        if snapshot.entries.count > Self.maxEntries {
            snapshot.entries = Array(snapshot.entries.prefix(Self.maxEntries))
        }
        return snapshot.entries.count != before
    }

    private func persist() async throws {
        try await persistence.save(Self.encode(snapshot))
    }

    private static func encode(_ snapshot: ReaderHistorySnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    private static func decode(_ data: Data) throws -> ReaderHistorySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReaderHistorySnapshot.self, from: data)
    }
}
