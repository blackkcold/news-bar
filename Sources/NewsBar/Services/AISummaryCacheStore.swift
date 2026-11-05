import Foundation

struct AISummaryCacheEntry: Codable, Sendable {
    let summary: String
    let items: [NewsItem]
    let contentHash: String
    let trendHistoryHash: String
    let generatedAt: Date
    let trendItemCount: Int
    let language: AppLanguage
    let manifest: SummaryManifest?
    let wasTruncated: Bool

    var presentationState: AISummaryState {
        .content(summary, wasTruncated: wasTruncated)
    }

    var completedContentHash: String? { wasTruncated ? nil : contentHash }
    var truncatedContentHash: String? { wasTruncated ? contentHash : nil }

    init(
        summary: String,
        items: [NewsItem],
        contentHash: String,
        trendHistoryHash: String,
        generatedAt: Date,
        trendItemCount: Int,
        language: AppLanguage = .zh,
        manifest: SummaryManifest? = nil,
        wasTruncated: Bool = false
    ) {
        self.summary = summary
        self.items = items
        self.contentHash = contentHash
        self.trendHistoryHash = trendHistoryHash
        self.generatedAt = generatedAt
        self.trendItemCount = trendItemCount
        self.language = language
        self.manifest = manifest
        self.wasTruncated = wasTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case summary, items, contentHash, trendHistoryHash, generatedAt, trendItemCount, language, manifest, wasTruncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        items = try c.decode([NewsItem].self, forKey: .items)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        trendHistoryHash = try c.decode(String.self, forKey: .trendHistoryHash)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        trendItemCount = try c.decode(Int.self, forKey: .trendItemCount)
        language = (try? c.decodeIfPresent(AppLanguage.self, forKey: .language)) ?? .zh
        manifest = try c.decodeIfPresent(SummaryManifest.self, forKey: .manifest)
        wasTruncated = try c.decodeIfPresent(Bool.self, forKey: .wasTruncated) ?? false
    }
}

@MainActor
enum AISummaryCacheRestore {
    /// Re-check after the asynchronous read so an older disk snapshot cannot
    /// replace a newer in-memory result or an active generation.
    static func loadIfEligible(
        isEligible: () -> Bool,
        load: () async -> AISummaryCacheEntry?
    ) async -> AISummaryCacheEntry? {
        guard !Task.isCancelled, isEligible() else { return nil }
        let cached = await load()
        guard !Task.isCancelled, isEligible() else { return nil }
        return cached
    }
}

actor AISummaryCacheStore {
    private let fileURL: URL

    init(fileURL: URL? = nil, language: AppLanguage = .zh) {
        if let fileURL {
            self.fileURL = fileURL
        } else if TestIsolation.isActive {
            self.fileURL = TestIsolation.directory("Summary")
                .appendingPathComponent("ai-summary-\(language.rawValue).json")
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
            self.fileURL = caches
                .appendingPathComponent(bundleID)
                .appendingPathComponent("ai-summary-\(language.rawValue).json")
        }
    }

    func load() -> AISummaryCacheEntry? {
        _ = PrivateFile.tightenExistingFile(fileURL)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AISummaryCacheEntry.self, from: data)
    }

    func save(_ entry: AISummaryCacheEntry, token: CacheWriteToken? = nil) {
        guard token?.isCurrent != false else { return }
        do {
            let data = try JSONEncoder().encode(entry)
            try PrivateFile.write(data, to: fileURL, durable: false)
        } catch {
            NSLog("[AISummaryCacheStore] persist failed: %@", error.localizedDescription)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
