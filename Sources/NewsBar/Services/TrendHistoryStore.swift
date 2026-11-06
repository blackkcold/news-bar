import CryptoKit
import Foundation

actor TrendHistoryStore {
    static let shared = TrendHistoryStore()

    private static let retention: TimeInterval = 30 * 24 * 60 * 60
    private static let heartbeatInterval: TimeInterval = 30 * 60
    private static let maxSnapshots = 1_500

    private let fileURL: URL
    private var snapshots: [TrendSnapshot] = []
    private var hasLoaded = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if TestIsolation.isActive {
            self.fileURL = TestIsolation.directory("Trend").appendingPathComponent("trend-history.json")
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
            self.fileURL = caches
                .appendingPathComponent(bundleID)
                .appendingPathComponent("trend-history.json")
        }
    }

    func record(
        weibo: [NewsItem],
        bilibili: [NewsItem],
        now: Date = Date(),
        token: CacheWriteToken? = nil
    ) -> TrendChangeSummary {
        guard token?.isCurrent != false else { return .none }
        loadIfNeeded()
        prune(now: now)

        let weiboItems = Array(weibo.prefix(10))
        let bilibiliItems = Array(bilibili.prefix(10))
        let contentHash = CacheEntry.contentIdentifier(for: weiboItems + bilibiliItems)
        let previous = snapshots.last
        let shouldPersist = previous?.contentHash != contentHash
            || now.timeIntervalSince(previous?.timestamp ?? .distantPast) >= Self.heartbeatInterval

        if shouldPersist {
            snapshots.append(
                TrendSnapshot(
                    timestamp: now,
                    weiboItems: weiboItems,
                    bilibiliItems: bilibiliItems,
                    contentHash: contentHash
                )
            )
            prune(now: now)
            persist()
        }

        return buildChangeSummary(
            previous: previous,
            currentWeibo: weiboItems,
            currentBilibili: bilibiliItems,
            now: now
        )
    }

    func recentSnapshots(hours: Int, now: Date = Date()) -> [TrendSnapshot] {
        loadIfNeeded()
        let boundedHours = min(max(hours, 1), 30 * 24)
        let cutoff = now.addingTimeInterval(-TimeInterval(boundedHours) * 60 * 60)
        return snapshots.filter { $0.timestamp >= cutoff }
    }

    /// Seven-day, bucket-deduplicated observations for the local trend
    /// detector. This is a read path only: the existing briefing context keeps
    /// its 12/24-hour shape until the new judgement is validated.
    func observations(days: Int = TrendDetector.analysisDays, now: Date = Date()) -> [TrendObservation] {
        loadIfNeeded()
        return TrendDetector.observations(from: snapshots, now: now, days: days)
    }

    func candidates(days: Int = TrendDetector.analysisDays, now: Date = Date()) -> [TrendCandidate] {
        TrendDetector.candidates(from: observations(days: days, now: now), now: now)
    }

    func clear() {
        snapshots = []
        hasLoaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TrendSnapshot].self, from: data) else {
            return
        }
        snapshots = decoded
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        snapshots = Array(snapshots.filter { $0.timestamp >= cutoff }.suffix(Self.maxSnapshots))
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshots)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[TrendHistoryStore] persist failed: %@", error.localizedDescription)
        }
    }

    private func buildChangeSummary(
        previous: TrendSnapshot?,
        currentWeibo: [NewsItem],
        currentBilibili: [NewsItem],
        now: Date
    ) -> TrendChangeSummary {
        guard let previous else {
            let context = buildContext(now: now, newTopics: currentWeibo + currentBilibili, risingTopics: [])
                + "\n" + ledgerContext(now: now)
            return TrendChangeSummary(score: 6, historyHash: historyHash(), context: context)
        }

        let previousItems = previous.weiboItems + previous.bilibiliItems
        let currentItems = currentWeibo + currentBilibili
        let previousByTopic = Dictionary(
            previousItems.map { (TrendTopicKey.canonical($0.title), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentByTopic = Dictionary(
            currentItems.map { (TrendTopicKey.canonical($0.title), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let newTopics = currentItems.filter { previousByTopic[TrendTopicKey.canonical($0.title)] == nil }
        let risingTopics = currentItems.filter { item in
            guard let previousItem = previousByTopic[TrendTopicKey.canonical(item.title)],
                  let previousRank = previousItem.rank,
                  let currentRank = item.rank else { return false }
            return previousRank - currentRank >= 3
        }

        let newTopThree = newTopics.filter { ($0.rank ?? Int.max) <= 3 }
        let crossPlatformTopics = Set(currentWeibo.map { TrendTopicKey.canonical($0.title) })
            .intersection(Set(currentBilibili.map { TrendTopicKey.canonical($0.title) }))
        let disappearedCount = previousByTopic.keys.filter { currentByTopic[$0] == nil }.count

        let score = newTopThree.count * 4
            + max(0, newTopics.count - newTopThree.count)
            + risingTopics.count * 2
            + crossPlatformTopics.count * 4
            + min(disappearedCount, 2)

        return TrendChangeSummary(
            score: score,
            historyHash: historyHash(),
            context: buildContext(now: now, newTopics: newTopics, risingTopics: risingTopics)
                + "\n" + ledgerContext(now: now)
        )
    }

    /// The local evidence line is intentionally short: the AI prompt already
    /// carries the 12/24-hour summary and is capped downstream. This gives the
    /// model a seven-day, bucket-deduplicated view without turning the prompt
    /// into a data dump.
    private func ledgerContext(now: Date) -> String {
        let observations = TrendDetector.observations(from: snapshots, now: now)
        let candidates = TrendDetector.candidates(from: observations, now: now).prefix(3)
        guard !candidates.isEmpty else {
            return "近7天趋势证据：暂无足够样本。"
        }
        let parts = candidates.map { candidate -> String in
            let label: String
            switch candidate.label {
            case .persistent: label = "持续趋势"
            case .rising: label = "正在上升"
            case .emerging: label = "新兴观察"
            case .insufficient: label = "样本不足"
            }
            return "\(candidate.title)（\(label)，\(candidate.activeDays)天，\(candidate.bucketCount)个时段，\(candidate.sources.count)个来源）"
        }
        return "近7天趋势证据：" + parts.joined(separator: "、") + "。"
    }

    private func buildContext(now: Date, newTopics: [NewsItem], risingTopics: [NewsItem]) -> String {
        let twelveHourCutoff = now.addingTimeInterval(-12 * 60 * 60)
        let twentyFourHourCutoff = now.addingTimeInterval(-24 * 60 * 60)
        let recent12 = snapshots.filter { $0.timestamp >= twelveHourCutoff }
        let recent24 = snapshots.filter { $0.timestamp >= twentyFourHourCutoff }
        var appearances: [String: (title: String, count: Int, bestRank: Int)] = [:]

        for snapshot in recent24 {
            for item in snapshot.weiboItems + snapshot.bilibiliItems {
                let key = TrendTopicKey.canonical(item.title)
                guard !key.isEmpty else { continue }
                let old = appearances[key] ?? (item.title, 0, Int.max)
                appearances[key] = (old.title, old.count + 1, min(old.bestRank, item.rank ?? Int.max))
            }
        }

        let persistent = appearances.values
            .sorted {
                if $0.count == $1.count { return $0.bestRank < $1.bestRank }
                return $0.count > $1.count
            }
            .prefix(5)
            .map { "\($0.title)（出现\($0.count)次，最高第\($0.bestRank == Int.max ? 0 : $0.bestRank)）" }

        let newText = newTopics.prefix(5).map(\.title).joined(separator: "、")
        let risingText = risingTopics.prefix(5).map(\.title).joined(separator: "、")
        let persistentText = persistent.joined(separator: "、")

        return """
        近12小时热搜采样：\(recent12.count)次；近24小时：\(recent24.count)次。
        新晋话题：\(newText.isEmpty ? "无" : newText)。
        快速上升：\(risingText.isEmpty ? "无" : risingText)。
        持续热点：\(persistentText.isEmpty ? "暂无足够历史" : persistentText)。
        """
    }

    private func historyHash() -> String {
        let source = snapshots.suffix(Self.maxSnapshots).map { snapshot in
            "\(snapshot.timestamp.timeIntervalSince1970):\(snapshot.contentHash)"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

}
