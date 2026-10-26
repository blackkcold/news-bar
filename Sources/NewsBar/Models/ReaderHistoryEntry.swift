import Foundation

struct ReaderHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var url: String
    var canonicalURL: String
    var title: String
    var host: String
    var firstOpenedAt: Date
    var lastOpenedAt: Date
    var visitCount: Int
}

struct ReaderHistorySnapshot: Codable, Equatable, Sendable {
    var version: Int
    var entries: [ReaderHistoryEntry]

    init(version: Int = 1, entries: [ReaderHistoryEntry] = []) {
        self.version = version
        self.entries = entries
    }
}
