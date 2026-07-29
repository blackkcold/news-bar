import Foundation

enum OnePasswordError: LocalizedError {
    case notInstalled
    case timeout
    case readFailed
    case invalidReference

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "1Password CLI 未安装"
        case .timeout: return "1Password 认证超时"
        case .readFailed: return "1Password 读取失败"
        case .invalidReference: return "1Password 引用格式无效"
        }
    }
}

enum OnePasswordService {

    private static let cliPath: String = {
        let silicon = "/opt/homebrew/bin/op"
        if FileManager.default.isExecutableFile(atPath: silicon) { return silicon }
        return "/usr/local/bin/op"
    }()
    private static let timeoutSeconds: TimeInterval = 30

    static func isInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: cliPath)
    }

    /// Validates a 1Password item reference format.
    /// Pure function — safe to call from any thread, no I/O.
    static func isValidReference(_ reference: String) -> Bool {
        guard reference.hasPrefix("op://") else { return false }
        // op://Vault/Item/Field — at least 3 path components after the scheme
        let remainder = String(reference.dropFirst("op://".count))
        let components = remainder.split(separator: "/", omittingEmptySubsequences: true)
        return components.count >= 3  // op://Vault/Item/Field
    }

    /// Synchronous read — retained for compatibility.
    /// WARNING: Blocks the calling thread via DispatchSemaphore.
    /// Prefer `readSecretAsync(reference:)` from UI/async contexts.
    static func readSecret(reference: String) throws -> String {
        guard isInstalled() else {
            throw OnePasswordError.notInstalled
        }

        guard isValidReference(reference) else {
            throw OnePasswordError.invalidReference
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["read", reference]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw OnePasswordError.notInstalled
        }

        let deadline = DispatchTime.now() + .seconds(Int(timeoutSeconds))
        let semaphore = DispatchSemaphore(value: 0)

        var outputData: Data?
        var timedOut = false

        DispatchQueue.global().async {
            process.waitUntilExit()
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            semaphore.signal()
        }

        if semaphore.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
        }

        if timedOut {
            throw OnePasswordError.timeout
        }

        guard process.terminationStatus == 0,
              let data = outputData,
              let secret = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            throw OnePasswordError.readFailed
        }

        return secret
    }

    /// Async read — does NOT block the calling thread.
    static func readSecretAsync(reference: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try Self.readSecret(reference: reference)
        }.value
    }
}
