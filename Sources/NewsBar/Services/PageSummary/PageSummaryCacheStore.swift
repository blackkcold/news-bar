import Foundation
import os

/// Disk cache for page overviews. It stores the rendered overview plus the
/// minimal citation metadata, never the article body or the prompt.
actor PageSummaryCacheStore {
    static let shared = PageSummaryCacheStore()

    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let maxEntries = 50

    private struct Entry: Codable {
        var summary: PageSummary
        var lastUsedAt: Date
    }

    private let fileURL: URL
    private var entries: [String: Entry] = [:]
    private var isLoaded = false
    private let writeGeneration = CacheWriteGeneration()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if TestIsolation.isActive {
            self.fileURL = TestIsolation.directory("PageSummary")
                .appendingPathComponent("page-summaries.json")
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
            self.fileURL = caches
                .appendingPathComponent(bundleID)
                .appendingPathComponent("page-summaries.json")
        }
    }

    func load(key: String, now: Date = Date()) -> PageSummary? {
        ensureLoaded()
        prune(now: now)
        guard var entry = entries[key] else { return nil }
        entry.lastUsedAt = now
        entries[key] = entry
        return entry.summary
    }

    func save(
        _ summary: PageSummary,
        key: String,
        token: CacheWriteToken? = nil,
        now: Date = Date()
    ) {
        guard token?.isCurrent != false else { return }
        ensureLoaded()
        entries[key] = Entry(summary: summary, lastUsedAt: now)
        prune(now: now)
        persist()
    }

    func clear() {
        writeGeneration.invalidate()
        entries = [:]
        isLoaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    func captureToken() -> CacheWriteToken {
        writeGeneration.capture()
    }

    private func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        _ = PrivateFile.tightenExistingFile(fileURL)
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        entries = entries.filter { $0.value.lastUsedAt >= cutoff }
        guard entries.count > Self.maxEntries else { return }
        let kept = entries
            .sorted { $0.value.lastUsedAt > $1.value.lastUsedAt }
            .prefix(Self.maxEntries)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            try PrivateFile.write(data, to: fileURL, durable: false)
        } catch {
            NSLog("[PageSummaryCacheStore] persist failed: %@", error.localizedDescription)
        }
    }
}
