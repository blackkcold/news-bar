import Foundation

protocol AISearchArchivePersisting: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
    func clear() async throws
}

struct FileAISearchArchivePersistence: AISearchArchivePersisting {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("com.newsbar.app", isDirectory: true)
            .appendingPathComponent("Reader", isDirectory: true)
            .appendingPathComponent("ai-search-history.json")
    }

    func load() async throws -> Data? {
        guard PrivateFile.tightenExistingFile(fileURL) else {
            throw AISearchArchiveStoreError.readOnlyArchive
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func save(_ data: Data) async throws {
        try PrivateFile.write(data, to: fileURL, durable: false)
        try? (fileURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    func clear() async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

enum AISearchArchiveStoreError: Error, Equatable, LocalizedError {
    case readOnlyArchive

    var errorDescription: String? {
        switch self {
        case .readOnlyArchive:
            return "The saved AI search archive is unreadable or was written by a newer version. Clear it to start a new archive."
        }
    }
}

actor AISearchArchiveStore {
    static let maxEntries = 200
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    private let persistence: any AISearchArchivePersisting
    private var snapshot = AISearchArchiveSnapshot()
    private var isLoaded = false
    private var isReadOnly = false
    private(set) var loadError: String?

    init(persistence: any AISearchArchivePersisting = FileAISearchArchivePersistence()) {
        self.persistence = persistence
    }

    func prepare(now: Date = Date()) async {
        guard !isLoaded else { return }
        isLoaded = true

        do {
            guard let data = try await persistence.load() else { return }
            let loaded: AISearchArchiveSnapshot
            do {
                loaded = try Self.decode(data)
            } catch {
                isReadOnly = true
                loadError = error.localizedDescription
                return
            }
            guard loaded.version == 1 else {
                isReadOnly = true
                loadError = AISearchArchiveStoreError.readOnlyArchive.localizedDescription
                return
            }

            let pruned = Self.pruned(loaded, now: now)
            snapshot = pruned
            if pruned != loaded {
                do {
                    try await persist(pruned)
                    loadError = nil
                } catch {
                    loadError = error.localizedDescription
                }
            }
        } catch {
            isReadOnly = true
            loadError = error.localizedDescription
        }
    }

    func record(_ entry: AISearchArchiveEntry, now: Date = Date()) async throws {
        await prepare(now: now)
        guard !isReadOnly else { throw AISearchArchiveStoreError.readOnlyArchive }

        let candidate = Self.pruned(
            AISearchArchiveSnapshot(version: 1, entries: snapshot.entries + [entry]),
            now: now
        )
        do {
            try await persist(candidate)
            snapshot = candidate
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            throw error
        }
    }

    func all() -> [AISearchArchiveEntry] {
        Self.sorted(snapshot.entries)
    }

    func remove(id: UUID) async throws {
        await prepare()
        guard !isReadOnly else { throw AISearchArchiveStoreError.readOnlyArchive }
        let entries = snapshot.entries.filter { $0.id != id }
        guard entries.count != snapshot.entries.count else { return }
        let candidate = AISearchArchiveSnapshot(version: 1, entries: entries)
        do {
            try await persist(candidate)
            snapshot = candidate
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            throw error
        }
    }

    func clear() async throws {
        try await persistence.clear()
        snapshot = AISearchArchiveSnapshot()
        isLoaded = true
        isReadOnly = false
        loadError = nil
    }

    private func persist(_ snapshot: AISearchArchiveSnapshot) async throws {
        try await persistence.save(Self.encode(snapshot))
    }

    private static func pruned(
        _ snapshot: AISearchArchiveSnapshot,
        now: Date
    ) -> AISearchArchiveSnapshot {
        let cutoff = now.addingTimeInterval(-retention)
        let entries = sorted(snapshot.entries.filter { $0.createdAt >= cutoff })
        return AISearchArchiveSnapshot(
            version: 1,
            entries: Array(entries.prefix(maxEntries))
        )
    }

    private static func sorted(_ entries: [AISearchArchiveEntry]) -> [AISearchArchiveEntry] {
        entries.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func encode(_ snapshot: AISearchArchiveSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    private static func decode(_ data: Data) throws -> AISearchArchiveSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AISearchArchiveSnapshot.self, from: data)
    }
}
