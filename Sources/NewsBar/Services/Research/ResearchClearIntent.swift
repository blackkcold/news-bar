import Foundation

/// Durable record of an in-progress "clear research history" operation.
///
/// It is written before anything is deleted, so a crash or relaunch cannot make
/// the app re-import the legacy artifacts it was in the middle of discarding.
struct ResearchClearIntent: Codable, Sendable, Equatable {
    static let currentVersion = 1

    enum Stage: String, Codable, Sendable {
        case prepared
        case cacheCleared
        case recordsDeleted
        case artifactsCleared
        case verified
    }

    var version = ResearchClearIntent.currentVersion
    var operationID: String
    var generation: Int
    var stage: Stage
    var createdAt: Date
    var updatedAt: Date

    static func make(
        operationID: String = UUID().uuidString,
        generation: Int,
        at date: Date
    ) -> ResearchClearIntent {
        ResearchClearIntent(
            operationID: operationID,
            generation: generation,
            stage: .prepared,
            createdAt: date,
            updatedAt: date
        )
    }
}

enum ResearchClearIntentLoad {
    case none
    case pending(ResearchClearIntent)
    /// A newer build wrote this intent. Do not guess what its stages mean.
    case unsupportedVersion
}

struct ResearchClearResult: Sendable, Equatable {
    var recordsRemoved = 0
    var cacheCleared = false
    var artifactsCleared = false
    var isComplete = false
    var error: String?
}

/// Owner-only file under the research directory. The intent outlives the data
/// it is clearing, so it may not live inside `records/`.
final class ResearchClearIntentStore: Sendable {
    private let fileURL: URL

    init(fileURL: URL = ResearchPaths.clearIntentFile) {
        self.fileURL = fileURL
    }

    var url: URL { fileURL }

    func load() -> ResearchClearIntentLoad {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .none }
        _ = PrivateFile.tightenExistingFile(fileURL)
        guard let data = try? Data(contentsOf: fileURL) else { return .none }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["version"] as? Int
        else {
            // A damaged intent is still an intent: replay the idempotent
            // stages instead of re-enabling legacy imports.
            return .pending(
                ResearchClearIntent.make(generation: 0, at: Date())
            )
        }
        guard version <= ResearchClearIntent.currentVersion else {
            return .unsupportedVersion
        }
        guard let intent = try? JSONDecoder().decode(ResearchClearIntent.self, from: data) else {
            return .pending(
                ResearchClearIntent.make(generation: 0, at: Date())
            )
        }
        return .pending(intent)
    }

    func save(_ intent: ResearchClearIntent) throws {
        var copy = intent
        copy.updatedAt = Date()
        let data = try JSONEncoder().encode(copy)
        try PrivateFile.write(data, to: fileURL, durable: true)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
