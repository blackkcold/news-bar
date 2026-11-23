import Foundation

/// Reads a monitor store without touching the original.
///
/// The store is copied first: `load()` archives corrupt files and rebuilds the
/// account list, and an agent check must never do that to the live data. The
/// report is counts only; credentials and post bodies stay out of it.
enum AgentStoreSummary {
    static func run(
        _ arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) async -> Int32 {
        let rootPath = value("--root", in: arguments) ?? WeiboMonitorStore.defaultRoot().path
        let source = URL(fileURLWithPath: rootPath)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            && isDirectory.boolValue

        guard exists else {
            return AgentHeadless.emit(
                Report(
                    exists: false,
                    storeRoot: source.path,
                    users: 0,
                    posts: 0,
                    unread: 0,
                    comments: 0,
                    latestMid: nil,
                    latestAt: nil,
                    issues: [],
                    unloadedUIDs: [],
                    monitorWriteBlocked: false
                ),
                stdout: stdout,
                stderr: stderr
            )
        }

        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarAgentStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: copy) }

        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            stderr("Cannot copy store: \(error.localizedDescription)")
            return 2
        }

        let store = WeiboMonitorStore(root: copy)
        let result = await store.load()
        let posts = result.postsByUID.values.flatMap { $0 }
        let latest = posts.max { $0.createdAt < $1.createdAt }
        let commentsDirectory = copy.appendingPathComponent("comments", isDirectory: true)
        let commentFiles = (try? FileManager.default.contentsOfDirectory(
            at: commentsDirectory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "json" }.count ?? 0

        return AgentHeadless.emit(
            Report(
                exists: true,
                storeRoot: source.path,
                users: result.users.count,
                posts: posts.count,
                unread: posts.filter { !$0.read }.count,
                comments: commentFiles,
                latestMid: latest?.mid,
                latestAt: latest?.createdAt,
                issues: result.issues,
                unloadedUIDs: result.unloadedUIDs.sorted(),
                monitorWriteBlocked: result.monitorWriteBlocked
            ),
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func value(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private struct Report: Encodable {
        let exists: Bool
        let storeRoot: String
        let users: Int
        let posts: Int
        let unread: Int
        let comments: Int
        let latestMid: String?
        let latestAt: Date?
        let issues: [String]
        let unloadedUIDs: [String]
        let monitorWriteBlocked: Bool
    }
}
