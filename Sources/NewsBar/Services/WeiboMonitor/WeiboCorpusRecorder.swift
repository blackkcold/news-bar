import Foundation

/// One line in the corpus JSONL. Flat on purpose: the label CLI and any
/// spreadsheet import can read it without a nested model.
struct WeiboCorpusRecord: Codable, Sendable {
    var mid: String
    var uid: String
    var screenName: String
    var text: String
    var createdAt: Date
    var fetchedAt: Date
    var isLongText: Bool
    var isRetweet: Bool
    var imageCount: Int
    var adScore: Double?
    var interestScore: Double?
    var verdict: String?
    var reasons: [String]
    var decider: String?
    var decidedAt: Date?

    init(post: WeiboPost) {
        self.mid = post.mid
        self.uid = post.uid
        self.screenName = post.screenName
        self.text = post.displayText
        self.createdAt = post.createdAt
        self.fetchedAt = post.fetchedAt
        self.isLongText = post.isLongText
        self.isRetweet = post.isRetweet
        self.imageCount = post.imageURLs.count
        self.adScore = post.relevance?.adScore
        self.interestScore = post.relevance?.interestScore
        self.verdict = post.relevance?.verdict.rawValue
        self.reasons = post.relevance?.reasons ?? []
        self.decider = post.relevance?.decider
        self.decidedAt = post.relevance?.decidedAt
    }
}

/// Debug-only corpus sink. It is off unless `WEIBO_CORPUS_DUMP=1`, writes
/// JSONL under Caches, and never throws into the monitor path: a full disk
/// must not stop a poll.
actor WeiboCorpusRecorder {
    private let fileURL: URL
    private let fileManager = FileManager.default

    init(fileURL: URL = WeiboCorpusRecorder.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WeiboCorpusRecorder? {
        guard environment["WEIBO_CORPUS_DUMP"] == "1" else { return nil }
        return WeiboCorpusRecorder()
    }

    static func defaultFileURL() -> URL {
        if TestIsolation.isActive {
            return TestIsolation.directory("WeiboCorpus").appendingPathComponent("posts.jsonl")
        }
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches
            .appendingPathComponent("com.newsbar.app", isDirectory: true)
            .appendingPathComponent("corpus", isDirectory: true)
            .appendingPathComponent("posts.jsonl")
    }

    func append(posts: [WeiboPost], now: Date) {
        guard !posts.isEmpty else { return }
        var payload = Data()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        for post in posts {
            let record = WeiboCorpusRecord(post: post)
            guard let line = try? encoder.encode(record) else { continue }
            payload.append(line)
            payload.append(0x0A)
        }
        guard !payload.isEmpty else { return }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: fileURL.path) {
                try payload.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            }
        } catch {
            // Silent on purpose: a debug sink must never surface as a monitor
            // error or slow a poll down.
        }
    }
}
