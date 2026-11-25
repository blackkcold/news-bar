import Darwin
import Foundation
import os

/// The collector invalidates this synchronously. The store only commits a
/// staged batch while its generation still holds the gate.
final class RecommendationDiagnosticPermit: Sendable {
    let generation = OSAllocatedUnfairLock(initialState: UUID())

    func invalidate() { generation.withLock { $0 = UUID() } }
}

struct RecommendationDiagnosticDocument: Codable, Sendable {
    var schemaVersion = 1
    var coverageSince: Date?
    var truncatedThrough: Date?
    var events: [RecommendationDiagnosticEvent] = []
    var shadow: [RecommendationShadowSample]? = nil

    @discardableResult
    mutating func prune(now: Date) -> Bool {
        let start = now.addingTimeInterval(-30 * 86_400)
        let before = events.count
        let shadowBefore = shadow?.count ?? 0
        events.removeAll { $0.occurredAt < start }
        shadow?.removeAll { $0.occurredAt < start }
        // Shadow work is optional; prefer retaining funnel rows at the cap.
        if let samples = shadow {
            let remaining = min(512, max(0, 10_000 - events.count))
            if samples.count > remaining { shadow = Array(samples.suffix(remaining)) }
        }
        if events.count > 10_000 {
            events.sort { $0.occurredAt < $1.occurredAt }
            let removed = events.count - 10_000
            truncatedThrough = max(truncatedThrough ?? .distantPast, events[removed - 1].occurredAt)
            events.removeFirst(removed)
        }
        return before != events.count || shadowBefore != (shadow?.count ?? 0)
    }
}

actor RecommendationDiagnosticStore {
    private let directory: URL?
    private var cached: RecommendationDiagnosticDocument?
    private let fileName = "events-v1.json"

    init(directory: URL? = nil) {
        self.directory = directory ?? (TestIsolation.isActive
            ? TestIsolation.root.appendingPathComponent("RecommendationDiagnostics", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("com.newsbar.app/RecommendationDiagnostics", isDirectory: true))
    }

    private func read() throws -> RecommendationDiagnosticDocument {
        if let cached { return cached }
        guard let url = directory?.appendingPathComponent(fileName), PrivateFile.tightenExistingFile(url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        do {
            let info = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = info.fileSize, size <= 10_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let document = try JSONDecoder().decode(RecommendationDiagnosticDocument.self, from: Data(contentsOf: url))
            guard document.schemaVersion == 1, document.events.allSatisfy({ $0.schemaVersion == 1 }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return document
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return RecommendationDiagnosticDocument()
        }
    }

    func load(now: Date) throws -> RecommendationDiagnosticDocument {
        if let directory {
            PrivateFile.removeStaleTemporaries(in: directory, olderThan: now, now: now)
        }
        var document = try read()
        if document.prune(now: now) { try save(document) }
        return document
    }

    func append(_ events: [RecommendationDiagnosticEvent], now: Date, coverageSince: Date? = nil,
                gate: RecommendationDiagnosticPermit? = nil, generation: UUID? = nil,
                shadow samples: [RecommendationShadowSample] = []) throws {
        if let gate, gate.generation.withLock({ $0 != generation }) { return }
        var document = try read()
        if let coverageSince { document.coverageSince = max(coverageSince, document.coverageSince ?? .distantPast) }
        document.events.append(contentsOf: events)
        if !samples.isEmpty {
            document.shadow = (document.shadow ?? []) + samples
        }
        document.prune(now: now)
        try save(document, gate: gate, generation: generation)
    }

    func clear() throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        PrivateFile.removeStaleTemporaries(in: directory, olderThan: .distantFuture)
        do { try FileManager.default.removeItem(at: directory.appendingPathComponent(fileName)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        cached = nil
    }

    private func save(_ document: RecommendationDiagnosticDocument, gate: RecommendationDiagnosticPermit? = nil,
                      generation: UUID? = nil) throws {
        guard var directory else { throw CocoaError(.fileNoSuchFile) }
        try PrivateFile.ensureDirectory(directory)
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try directory.setResourceValues(properties)
        let destination = directory.appendingPathComponent(fileName)
        let stage = directory.appendingPathComponent(PrivateFile.temporaryPrefix + UUID().uuidString)
        try PrivateFile.write(JSONEncoder().encode(document), to: stage, durable: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        func commit() throws {
            guard Darwin.rename(stage.path, destination.path) == 0 else { throw PrivateFileError.renameFailed(errno) }
            cached = document
        }
        if let gate {
            try gate.generation.withLock { value in
                guard value == generation else { return }
                try commit()
            }
        } else {
            try commit()
        }
    }
}
