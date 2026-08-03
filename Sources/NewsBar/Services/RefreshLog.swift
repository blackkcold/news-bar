import Foundation

/// 环形缓冲日志，记录最近 N 次刷新行为的诊断信息。
/// 线程安全 (actor)，可选落盘到 ~/Library/Caches/<bundleID>/refresh.log。
actor RefreshLog {

    static let shared = RefreshLog()

    private let maxEntries = 10
    private var entries: [Entry] = []

    private let logFileURL: URL? = {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
        return caches
            .appendingPathComponent(bundleID)
            .appendingPathComponent("refresh.log")
    }()

    // MARK: - Data Types

    enum Trigger: String, Codable, CaseIterable {
        case startup      // 启动 2s 自动刷新
        case timer1h      // 旧版每小时定时器触发，保留用于兼容历史日志
        case scheduled    // 分层调度器触发
        case wake         // 系统唤醒后检查刷新
        case manual       // 用户手动点击刷新
        case popoverOpen  // 打开弹窗时 loadCached
    }

    enum SourceResult: Codable {
        case ok(itemCount: Int)
        case failed(reason: String)
        case empty
        case skippedMemoryNotEmpty(itemCount: Int) // loadCached 跳过（内存有数据）
        case cacheStale                            // loadCached 跳过（缓存过期且内存空）
        case noCache                               // loadCached 无缓存
    }

    struct Entry: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let trigger: Trigger
        let sourceResults: [String: String]  // displayName → 结果描述
        let aiBefore: String
        let aiAfter: String
        let errorSummary: String?

        init(
            trigger: Trigger,
            sourceResults: [String: String],
            aiBefore: String,
            aiAfter: String,
            errorSummary: String? = nil
        ) {
            self.id = UUID()
            self.timestamp = Date()
            self.trigger = trigger
            self.sourceResults = sourceResults
            self.aiBefore = aiBefore
            self.aiAfter = aiAfter
            self.errorSummary = errorSummary
        }
    }

    // MARK: - Public API

    func record(
        trigger: Trigger,
        sourceResults: [String: String],
        aiBefore: String,
        aiAfter: String,
        errorSummary: String? = nil
    ) {
        let entry = Entry(
            trigger: trigger,
            sourceResults: sourceResults,
            aiBefore: aiBefore,
            aiAfter: aiAfter,
            errorSummary: errorSummary
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }
        persistToDisk()
    }

    func snapshot() -> [Entry] {
        entries
    }

    func snapshotString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"

        return entries.reversed().enumerated().map { index, entry in
            let sourcesStr = entry.sourceResults
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")

            var line = "#\(index + 1) [\(formatter.string(from: entry.timestamp))] "
            line += "触发:\(entry.trigger.rawValue) "
            line += "源:{\(sourcesStr)} "
            line += "AI:\(entry.aiBefore)→\(entry.aiAfter)"
            if let err = entry.errorSummary {
                line += " 错误:\(err)"
            }
            return line
        }.joined(separator: "\n")
    }

    func clear() {
        entries = []
        if let url = logFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Disk Persistence

    private func persistToDisk() {
        guard let url = logFileURL else { return }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            // 静默失败 — 日志落盘不影响主功能
        }
    }
}
