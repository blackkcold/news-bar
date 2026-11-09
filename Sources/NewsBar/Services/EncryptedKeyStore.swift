import Foundation
import CryptoKit
import Darwin
import IOKit

/// 应用内加密文件存储 — 替代 Keychain，避免系统弹窗
///
/// 安全级别: LOW-MEDIUM（同用户进程可派生密钥）
/// 适用场景: AI API Key 等经济性资产，非隐私性凭证
///
/// 威胁模型:
///   - 阻止: 文件浏览器查看、跨机器 Time Machine 恢复、其他 UID 访问
///   - 不阻止: 同 UID 有代码执行能力的攻击者 (通过相同派生流程可得密钥)
///   - 补偿: 0600 权限、UUID 机器绑定、原子写入、GCM 认证加密
actor EncryptedKeyStore {
    /// Actors serialize one instance, not other instances of the same store.
    private static let mutationLock = NSLock()
    private static let legacyFirecrawlAccount = "search-key-firecrawl"
    private static let legacyFirecrawlClearMarker = "search-legacy-cleared.firecrawl"

    // MARK: - Debug Gate

    /// 当启用时，所有操作被跳过 — 读取返回 nil，写入返回失败。
    /// 开发期间避免反复操作加密文件。
    ///
    /// 迁移代码依赖这个返回值：若这里假装成功，调用方会清掉唯一一份明文
    /// 凭据，而加密文件里什么也没有，等于静默丢 Key。
    ///
    /// 启用: `defaults write com.newsbar.app debugDisableEncryptedStore -bool YES`
    /// 禁用: `defaults delete com.newsbar.app debugDisableEncryptedStore`
    static var isDisabled: Bool {
        isDisabled(using: .standard)
    }

    private static func isDisabled(using defaults: UserDefaults) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: "debugDisableEncryptedStore")
        #else
        return false
        #endif
    }

    // MARK: - 存储路径

    private static let defaultStoreDirectory: URL = {
        if TestIsolation.isActive { return TestIsolation.directory("Keys") }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
        let dir = appSupport.appendingPathComponent(bundleID)
        // 0700，且先于任何文件创建
        try? PrivateFile.ensureDirectory(dir)
        // 排除 Time Machine 备份
        var mutableDir = dir
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableDir.setResourceValues(resourceValues)
        return dir
    }()

    /// Injected only by tests, so a test never reads or writes the real store.
    private let storeDirectory: URL
    private let metadataDefaults: UserDefaults
    private let testMachineIdentifier: (@Sendable () throws -> String)?
    private var storeDisabled: Bool { Self.isDisabled(using: metadataDefaults) }

    private var storeFile: URL { storeDirectory.appendingPathComponent("apikeys.enc") }
    private var uuidSnapshotFile: URL { storeDirectory.appendingPathComponent(".machine-uuid") }
    private var lockFile: URL { storeDirectory.appendingPathComponent(".apikeys.lock") }

    init(
        directory: URL? = nil,
        metadataDefaults: UserDefaults = TestIsolation.defaults,
        testMachineIdentifier: (@Sendable () throws -> String)? = TestIsolation.machineIdentifier
    ) {
        precondition(testMachineIdentifier == nil || directory != nil || TestIsolation.isActive)
        storeDirectory = directory ?? Self.defaultStoreDirectory
        self.metadataDefaults = metadataDefaults
        self.testMachineIdentifier = testMachineIdentifier
        if let directory {
            try? PrivateFile.ensureDirectory(directory)
        }
        // Create the test snapshot eagerly so a fault injected into the first
        // credential write cannot be consumed by the snapshot write path.
        if let testMachineIdentifier, let uuid = try? testMachineIdentifier() {
            try? Self.writeMachineSnapshotIfNeeded(uuid, in: storeDirectory)
        }
    }

    // MARK: - 密钥派生

    /// App 固定 salt — 编译时随机生成，提供混淆层（非安全层）
    private static let appSalt: [UInt8] = [
        0xA3, 0xF1, 0x7E, 0x2C, 0x91, 0x4B, 0xD8, 0x66,
        0x0F, 0x3A, 0x55, 0xE9, 0x1D, 0xC7, 0x82, 0x34,
        0x6B, 0x9E, 0xF0, 0x12, 0x48, 0xAD, 0x7F, 0xC3,
        0x19, 0x5D, 0xE2, 0x8B, 0x37, 0xFA, 0x06, 0xDC
    ]

    /// 从机器标识 + app salt 派生 AES-256 密钥
    private func deriveKey() throws -> SymmetricKey {
        let machineUUID = try resolveMachineIdentifier()
        var keyMaterial = Data(Self.appSalt)
        keyMaterial.append(Data(machineUUID.utf8))
        let info = (Bundle.main.bundleIdentifier ?? "com.newsbar").data(using: .utf8)!
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyMaterial),
            info: info,
            outputByteCount: 32
        )
    }

    // MARK: - UUID 快照

    /// 获取当前机器的 IOPlatformUUID
    private static func currentPlatformUUID() throws -> String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }
        guard platformExpert != 0 else {
            throw EncryptedKeyStoreError.platformUUIDUnavailable
        }
        guard let uuid = IORegistryEntryCreateCFProperty(
            platformExpert, "IOPlatformUUID" as CFString,
            kCFAllocatorDefault, 0
        ).takeRetainedValue() as? String, !uuid.isEmpty else {
            throw EncryptedKeyStoreError.platformUUIDUnavailable
        }
        return uuid
    }

    /// 解析机器标识 — 优先使用已保存的 UUID 快照
    /// 如果 UUID 发生变更（硬件更换/系统升级），使用旧 UUID 解密已有数据
    private func resolveMachineIdentifier() throws -> String {
        if let testMachineIdentifier {
            let uuid = try testMachineIdentifier()
            // Keep the snapshot path exercised in tests without ever reading
            // the real IOPlatformUUID.
            try Self.writeMachineSnapshotIfNeeded(uuid, in: storeDirectory)
            return uuid
        }
        return try Self.resolveMachineIdentifier(in: storeDirectory)
    }

    private static func writeMachineSnapshotIfNeeded(_ uuid: String, in directory: URL) throws {
        let snapshotFile = directory.appendingPathComponent(".machine-uuid")
        _ = PrivateFile.tightenExistingFile(snapshotFile)
        if let saved = try? String(contentsOf: snapshotFile, encoding: .utf8), saved == uuid {
            return
        }
        try PrivateFile.write(Data(uuid.utf8), to: snapshotFile, durable: true)
        try? (snapshotFile as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    private static func resolveMachineIdentifier(in directory: URL) throws -> String {
        let snapshotFile = directory.appendingPathComponent(".machine-uuid")
        // 读取已保存的 UUID 快照
        _ = PrivateFile.tightenExistingFile(snapshotFile)
        if let savedUUID = try? String(contentsOf: snapshotFile, encoding: .utf8),
           !savedUUID.isEmpty {
            let currentUUID = (try? currentPlatformUUID()) ?? savedUUID
            if savedUUID != currentUUID {
                NSLog("[EncryptedKeyStore] IOPlatformUUID changed; using saved UUID for backward compatibility.")
            }
            return savedUUID
        }
        // 首次启动：保存当前 UUID 快照
        let uuid = try currentPlatformUUID()
        try PrivateFile.write(Data(uuid.utf8), to: snapshotFile, durable: true)
        try? (snapshotFile as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        return uuid
    }

    // MARK: - 文件格式

    static let currentVersion = 1

    struct EncryptedPayload: Codable {
        let version: Int
        var entries: [Entry]
        /// Persisted alongside the entries so another store instance cannot
        /// restore a provider that was removed while its write was in flight.
        var customProviderCredentials: [String: CustomProviderCredentialState]? = nil
    }

    struct CustomProviderCredentialState: Codable, Equatable {
        let generation: String
        let revoked: Bool
        /// Legacy payloads omit these fields and remain unbound until the user
        /// explicitly saves a new key or reference for a concrete endpoint.
        var endpointIdentity: String? = nil
        var referenceEndpointIdentity: String? = nil
        var referenceRevision: String? = nil
    }

    enum BoundCustomCredentialReadResult: Equatable {
        case found(String)
        case missing
        case unbound
        case endpointMismatch
        case failed
    }

    private struct BoundCustomKeyWrite {
        let expected: CustomProviderCredentialState?
        let replacement: CustomProviderCredentialState
    }

    private struct BoundCustomReferenceWrite {
        let account: String
        let expected: CustomProviderCredentialState
        let endpointIdentity: String
        let operationRevision: String
    }

    enum CustomProviderCredentialStateResult: Equatable {
        case legacy
        case state(CustomProviderCredentialState)
        case failed
    }

    enum CustomProviderReactivationResult: Equatable {
        case activated(String)
        case failed(MutationResult)
    }

    enum MutationResult: Equatable {
        case durable
        case notCommitted
        case committedDurabilityUnknown
        case unverified
    }

    enum ConditionalSaveResult: Equatable {
        case existing
        case existingDurabilityUnknown
        case mutation(MutationResult)
    }

    enum ReadResult: Equatable {
        case found(String)
        case missing
        case failed

        func value(orIfMissing fallback: String) -> String? {
            switch self {
            case let .found(value): return value
            case .missing: return fallback
            case .failed: return nil
            }
        }
    }

    enum LegacyFirecrawlReadResult: Equatable {
        case found(String)
        case missing
        case revoked
        case failed
    }

    struct Entry: Codable, Equatable {
        let account: String
        let nonce: Data            // AES-GCM nonce (12 bytes, random per write)
        let ciphertext: Data       // AES-GCM ciphertext + 16-byte auth tag
    }

    struct OnePasswordRefreshSnapshot: Equatable {
        let account: String
        let reference: ReadResult
        fileprivate let watchedEntries: [Entry]
        fileprivate let customState: CustomProviderCredentialState?
    }

    enum EncryptedKeyStoreError: LocalizedError {
        case platformUUIDUnavailable
        case encryptionFailed
        case decryptionFailed
        case fileCorrupted
        case writeUnverified

        var errorDescription: String? {
            switch self {
            case .platformUUIDUnavailable: return "无法获取机器标识"
            case .encryptionFailed: return "加密写入失败"
            case .decryptionFailed: return "解密失败"
            case .fileCorrupted: return "存储文件已损坏"
            case .writeUnverified: return "写入后无法确认存储状态"
            }
        }
    }

    // MARK: - Payload 读写

    /// A stable sidecar lock protects the entire read-modify-write transaction
    /// across processes; the in-process lock also serializes separate actors.
    private func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

        try PrivateFile.ensureDirectory(storeDirectory)
        let descriptor = try lockFile.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw PrivateFileError.invalidPath }
            while true {
                let fd = Darwin.open(
                    path,
                    O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK,
                    mode_t(0o600)
                )
                if fd >= 0 { return fd }
                if errno == EINTR { continue }
                throw PrivateFileError.openFailed(errno)
            }
        }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw PrivateFileError.openFailed(errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == Darwin.geteuid(),
              (info.st_mode & 0o777) == 0o600 else {
            throw PrivateFileError.permissionMismatch
        }
        return try operation()
    }

    func confirmWriteDurability() -> Bool {
        guard !storeDisabled else { return false }
        do {
            try withMutationLock {
                try PrivateFile.syncContainingDirectory(of: storeFile)
            }
            return true
        } catch {
            return false
        }
    }

    private func readPayload() throws -> EncryptedPayload {
        _ = PrivateFile.tightenExistingFile(storeFile)
        guard FileManager.default.fileExists(atPath: storeFile.path) else {
            return EncryptedPayload(version: Self.currentVersion, entries: [])
        }
        let data = try Data(contentsOf: storeFile)
        do {
            return try JSONDecoder().decode(EncryptedPayload.self, from: data)
        } catch {
            throw EncryptedKeyStoreError.fileCorrupted
        }
    }

    private func writePayload(_ payload: EncryptedPayload) throws {
        let data = try JSONEncoder().encode(payload)

        // 原子写入: 0600 临时文件 → F_FULLFSYNC → rename → 读回验证
        var postCommitError: PrivateFilePostCommitError?
        do {
            try PrivateFile.write(
                data,
                to: storeFile,
                durable: true,
                fullSync: true
            )
        } catch let error as PrivateFilePostCommitError {
            postCommitError = error
        }
        // 排除 Time Machine 备份
        try? (storeFile as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)

        // 读回验证
        #if DEBUG
        if PrivateFileFaults.failVerificationAfterWrite {
            throw EncryptedKeyStoreError.writeUnverified
        }
        #endif
        guard let verifyData = try? Data(contentsOf: storeFile), verifyData == data else {
            throw EncryptedKeyStoreError.writeUnverified
        }
        if let postCommitError { throw postCommitError }
    }

    // MARK: - API Key CRUD

    private static func customProviderAccount(for account: String) -> String? {
        let prefix = "one-password-ref."
        let provider = account.hasPrefix(prefix) ? String(account.dropFirst(prefix.count)) : account
        guard provider.hasPrefix("custom:"), provider.count > "custom:".count else { return nil }
        return provider
    }

    private static func permitsCredentialMutation(
        account: String, generation: String?, payload: EncryptedPayload
    ) -> Bool {
        guard let provider = customProviderAccount(for: account) else { return true }
        guard let state = payload.customProviderCredentials?[provider] else { return generation == nil }
        return !state.revoked && state.generation == generation
    }

    /// 保存 API Key（加密写入文件）
    /// - Returns: true 表示保存成功且完成持久性同步
    @discardableResult
    func saveAPIKey(_ key: String, account: String, customProviderGeneration: String? = nil) -> Bool {
        saveAPIKeyResult(key, account: account, customProviderGeneration: customProviderGeneration) == .durable
    }

    func saveAPIKeyResult(
        _ key: String, account: String, customProviderGeneration: String? = nil
    ) -> MutationResult {
        switch saveAPIKeyResult(
            key, account: account, customProviderGeneration: customProviderGeneration, onlyIfMissing: false
        ) {
        case let .mutation(result): return result
        case .existing, .existingDurabilityUnknown: return .notCommitted
        }
    }

    /// Imports a legacy credential only if the current payload has no usable
    /// value. The check and write share the cross-process mutation lock.
    func saveAPIKeyIfMissing(_ key: String, account: String) -> ConditionalSaveResult {
        saveAPIKeyResult(key, account: account, customProviderGeneration: nil, onlyIfMissing: true)
    }

    /// A refresh must not replace a key or reference changed while the secret
    /// reader was suspended, including changes made by another store instance.
    func saveRefreshedAPIKey(_ key: String, snapshot: OnePasswordRefreshSnapshot) -> MutationResult {
        switch saveAPIKeyResult(
            key, account: snapshot.account,
            customProviderGeneration: snapshot.customState?.generation,
            onlyIfMissing: false, expectedRefresh: snapshot
        ) {
        case let .mutation(result): return result
        case .existing, .existingDurabilityUnknown: return .notCommitted
        }
    }

    /// Restore the exact revoked generation and store the replacement key in
    /// one payload transaction. No intermediate active-but-empty state is
    /// visible if encryption or a pre-commit write fails.
    func saveAPIKeyRecoveringCustomProvider(
        _ key: String, account: String, matchingRevocation: String
    ) -> (result: MutationResult, generation: String?) {
        guard !Task.isCancelled, Self.customProviderAccount(for: account) == account else {
            return (.notCommitted, nil)
        }
        let generation = UUID().uuidString
        switch saveAPIKeyResult(
            key, account: account, customProviderGeneration: generation,
            onlyIfMissing: false, matchingRevocation: matchingRevocation
        ) {
        case let .mutation(result):
            return (result, result == .notCommitted ? nil : generation)
        case .existing, .existingDurabilityUnknown:
            return (.notCommitted, nil)
        }
    }

    /// Only a deliberate user save may establish or replace an endpoint
    /// binding. The old state, new generation and encrypted key are committed
    /// together; another process changing any of them makes this write stale.
    func saveBoundCustomKeyResult(
        _ key: String, account: String, expectedState: CustomProviderCredentialState?,
        endpointIdentity: String
    ) -> (result: MutationResult, state: CustomProviderCredentialState?) {
        guard !Task.isCancelled, !endpointIdentity.isEmpty,
              Self.customProviderAccount(for: account) == account else { return (.notCommitted, nil) }
        let next = CustomProviderCredentialState(
            generation: UUID().uuidString,
            revoked: false,
            endpointIdentity: endpointIdentity,
            referenceEndpointIdentity: expectedState?.referenceEndpointIdentity == endpointIdentity ? endpointIdentity : nil,
            referenceRevision: expectedState?.referenceRevision
        )
        switch saveAPIKeyResult(
            key, account: account, customProviderGeneration: next.generation,
            onlyIfMissing: false, boundCustomKey: BoundCustomKeyWrite(expected: expectedState, replacement: next)
        ) {
        case let .mutation(result):
            return (result, result == .durable || result == .committedDurabilityUnknown ? next : nil)
        case .existing, .existingDurabilityUnknown:
            return (.notCommitted, nil)
        }
    }

    /// A separately entered reference has its own binding; rebinding a key
    /// never silently adopts a legacy or previously scoped 1Password item.
    func saveBoundCustomReferenceResult(
        _ reference: String, account: String, expectedState: CustomProviderCredentialState,
        endpointIdentity: String, operationRevision: String = UUID().uuidString
    ) -> MutationResult {
        guard Self.customProviderAccount(for: account) == account,
              !expectedState.revoked, !endpointIdentity.isEmpty,
              expectedState.endpointIdentity == endpointIdentity,
              !operationRevision.isEmpty, operationRevision != expectedState.referenceRevision else { return .notCommitted }
        switch saveAPIKeyResult(
            reference, account: Self.onePasswordRefAccount(for: account),
            customProviderGeneration: expectedState.generation, onlyIfMissing: false,
            boundCustomReference: BoundCustomReferenceWrite(
                account: account, expected: expectedState, endpointIdentity: endpointIdentity,
                operationRevision: operationRevision
            )
        ) {
        case let .mutation(result): return result
        case .existing, .existingDurabilityUnknown: return .notCommitted
        }
    }

    private func saveAPIKeyResult(
        _ key: String, account: String, customProviderGeneration: String?, onlyIfMissing: Bool,
        expectedRefresh: OnePasswordRefreshSnapshot? = nil, matchingRevocation: String? = nil,
        boundCustomKey: BoundCustomKeyWrite? = nil,
        boundCustomReference: BoundCustomReferenceWrite? = nil
    ) -> ConditionalSaveResult {
        guard !storeDisabled else { return .mutation(.notCommitted) }
        guard !account.hasPrefix(Self.onePasswordClearMarkerPrefix),
              account != Self.legacyFirecrawlClearMarker else { return .mutation(.notCommitted) }
        guard !key.isEmpty,
              let plaintext = key.data(using: .utf8) else { return .mutation(.notCommitted) }

        do {
            return try withMutationLock {
                var payload = try readPayload()
                if let boundCustomKey {
                    guard !Task.isCancelled, Self.customProviderAccount(for: account) == account,
                          payload.customProviderCredentials?[account] == boundCustomKey.expected else {
                        return .mutation(.notCommitted)
                    }
                    var states = payload.customProviderCredentials ?? [:]
                    states[account] = boundCustomKey.replacement
                    payload.customProviderCredentials = states
                }
                if let boundCustomReference {
                    guard !Task.isCancelled,
                          account == Self.onePasswordRefAccount(for: boundCustomReference.account),
                          payload.customProviderCredentials?[boundCustomReference.account] == boundCustomReference.expected,
                          !boundCustomReference.expected.revoked,
                          boundCustomReference.expected.endpointIdentity == boundCustomReference.endpointIdentity else {
                        return .mutation(.notCommitted)
                    }
                    var updated = boundCustomReference.expected
                    updated.referenceEndpointIdentity = boundCustomReference.endpointIdentity
                    updated.referenceRevision = boundCustomReference.operationRevision
                    payload.customProviderCredentials?[boundCustomReference.account] = updated
                }
                if let matchingRevocation {
                    guard !Task.isCancelled,
                          let generation = customProviderGeneration,
                          let state = payload.customProviderCredentials?[account],
                          state.revoked, state.generation == matchingRevocation else {
                        return .mutation(.notCommitted)
                    }
                    payload.customProviderCredentials?[account] = CustomProviderCredentialState(
                        generation: generation, revoked: false
                    )
                }
                guard Self.permitsCredentialMutation(
                    account: account, generation: customProviderGeneration, payload: payload
                ) else { return .mutation(.notCommitted) }
                if let expectedRefresh {
                    guard expectedRefresh.account == account,
                          expectedRefresh.watchedEntries == Self.onePasswordRefreshEntries(account: account, payload: payload),
                          expectedRefresh.customState == payload.customProviderCredentials?[account] else {
                        return .mutation(.notCommitted)
                    }
                }

                if onlyIfMissing {
                    if account == Self.legacyFirecrawlAccount,
                       payload.entries.contains(where: { $0.account == Self.legacyFirecrawlClearMarker }) {
                        // A deletion wins over a later legacy import. Confirm
                        // the marker's directory entry before the caller may
                        // discard the old plaintext copy.
                        do {
                            try PrivateFile.syncContainingDirectory(of: storeFile)
                            return .existing
                        } catch {
                            return .existingDurabilityUnknown
                        }
                    }
                    switch readAPIKeyResult(account: account, payload: payload) {
                    case let .found(value) where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                        // A previous rename may have been visible without its
                        // directory entry being durable. Retain the legacy copy
                        // until that barrier succeeds.
                        do {
                            try PrivateFile.syncContainingDirectory(of: storeFile)
                            return .existing
                        } catch {
                            return .existingDurabilityUnknown
                        }
                    case .failed:
                        return .mutation(.notCommitted)
                    case .missing, .found:
                        break
                    }
                }

                let symmetricKey = try deriveKey()

                // 每次写入生成唯一随机 nonce — AES.GCM.Nonce() 使用 SecRandomCopyBytes
                let nonce = AES.GCM.Nonce()
                let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)

                let clearMarker = Self.onePasswordClearMarker(forScopedAccount: account)
                payload.entries.removeAll { $0.account == account || $0.account == clearMarker }
                payload.entries.append(Entry(
                    account: account,
                    nonce: Data(nonce),
                    ciphertext: sealedBox.ciphertext + sealedBox.tag
                ))

                let durabilityUnknown: Bool
                do {
                    try writePayload(payload)
                    durabilityUnknown = false
                } catch is PrivateFilePostCommitError {
                    durabilityUnknown = true
                }

                // 更新 staleness 时间戳和存在性 flag（与 KeychainManager 兼容）
                let timestampKey = "apiKeyLastSaved-\(account)"
                metadataDefaults.set(Date().timeIntervalSince1970, forKey: timestampKey)
                metadataDefaults.set(true, forKey: "hasAIKey-\(account)")
                if account.hasPrefix("ai-key-") {
                    let providerRaw = String(account.dropFirst("ai-key-".count))
                    metadataDefaults.set(true, forKey: "hasAIKey-\(providerRaw)")
                }
                return .mutation(durabilityUnknown ? .committedDurabilityUnknown : .durable)
            }
        } catch EncryptedKeyStoreError.writeUnverified {
            return .mutation(.unverified)
        } catch {
            NSLog("[EncryptedKeyStore] saveAPIKey(\(account)) failed: \(error.localizedDescription)")
            return .mutation(.notCommitted)
        }
    }

    func readAPIKeyResult(account: String) -> ReadResult {
        guard !storeDisabled else { return .failed }
        // Custom-provider credentials must be read through the bound API. The
        // generic entry point has no endpoint context, so it fails closed
        // instead of returning a key that belongs to another endpoint.
        if Self.customProviderAccount(for: account) != nil { return .missing }

        do {
            return readAPIKeyResult(account: account, payload: try readPayload())
        } catch {
            NSLog("[EncryptedKeyStore] readAPIKey(\(account)) failed: \(error.localizedDescription)")
            return .failed
        }
    }

    func readBoundCustomKeyResult(account: String, endpointIdentity: String) -> BoundCustomCredentialReadResult {
        readBoundCustomCredentialResult(account: account, endpointIdentity: endpointIdentity, reference: false)
    }

    func readBoundCustomReferenceResult(account: String, endpointIdentity: String) -> BoundCustomCredentialReadResult {
        readBoundCustomCredentialResult(account: account, endpointIdentity: endpointIdentity, reference: true)
    }

    /// Unified provider read: custom keys are never returned without a matching
    /// persisted endpoint binding. Built-in accounts keep their existing path.
    func readProviderAPIKeyResult(account: String, endpointIdentity: String?) -> ReadResult {
        guard Self.customProviderAccount(for: account) == account else {
            return readAPIKeyResult(account: account)
        }
        guard let endpointIdentity else { return .missing }
        switch readBoundCustomKeyResult(account: account, endpointIdentity: endpointIdentity) {
        case let .found(value): return .found(value)
        case .missing, .unbound, .endpointMismatch: return .missing
        case .failed: return .failed
        }
    }

    private func readBoundCustomCredentialResult(
        account: String, endpointIdentity: String, reference: Bool
    ) -> BoundCustomCredentialReadResult {
        guard !storeDisabled, !endpointIdentity.isEmpty,
              Self.customProviderAccount(for: account) == account else { return .failed }
        do {
            let payload = try readPayload()
            let state = payload.customProviderCredentials?[account]
            guard state?.revoked != true else { return .missing }
            let entryAccount = reference ? Self.onePasswordRefAccount(for: account) : account
            if reference, let marker = Self.onePasswordClearMarker(forScopedAccount: entryAccount),
               payload.entries.contains(where: { $0.account == marker }) { return .missing }
            guard payload.entries.contains(where: { $0.account == entryAccount }) else { return .missing }
            let binding = reference ? state?.referenceEndpointIdentity : state?.endpointIdentity
            guard let binding else { return .unbound }
            guard binding == endpointIdentity else { return .endpointMismatch }
            switch readAPIKeyResult(account: entryAccount, payload: payload) {
            case let .found(value): return .found(value)
            case .missing: return .missing
            case .failed: return .failed
            }
        } catch {
            return .failed
        }
    }

    private func readAPIKeyResult(account: String, payload: EncryptedPayload) -> ReadResult {
        if let provider = Self.customProviderAccount(for: account),
           payload.customProviderCredentials?[provider]?.revoked == true {
            return .missing
        }
        guard let entry = payload.entries.first(where: { $0.account == account }) else {
            return .missing
        }
        do {
            let symmetricKey = try deriveKey()

            // 拆分 ciphertext 和 tag（最后 16 字节）
            guard entry.ciphertext.count > 16 else {
                NSLog("[EncryptedKeyStore] Entry for \(account) has invalid ciphertext length")
                return .failed
            }
            let tag = entry.ciphertext.suffix(16)
            let ciphertext = entry.ciphertext.prefix(entry.ciphertext.count - 16)

            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: entry.nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)

            guard let value = String(data: decrypted, encoding: .utf8) else { return .failed }
            return .found(value)
        } catch let error as CryptoKitError {
            if case .authenticationFailure = error {
                NSLog("[EncryptedKeyStore] GCM auth failure for \(account) — key or data mismatch")
            }
            return .failed
        } catch {
            NSLog("[EncryptedKeyStore] readAPIKey(\(account)) failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// 读取 API Key（从加密文件解密）；未找到或解密失败时返回 nil。
    func readAPIKey(account: String) -> String? {
        guard case let .found(value) = readAPIKeyResult(account: account) else { return nil }
        return value
    }

    /// Decide the legacy fallback from the same payload as the encrypted key.
    func readLegacyFirecrawlKeyResult() -> LegacyFirecrawlReadResult {
        guard !storeDisabled else { return .failed }
        do {
            let payload = try readPayload()
            switch readAPIKeyResult(account: Self.legacyFirecrawlAccount, payload: payload) {
            case let .found(value) where !value.isEmpty:
                return .found(value)
            case .failed:
                return .failed
            case .missing, .found:
                return payload.entries.contains(where: { $0.account == Self.legacyFirecrawlClearMarker })
                    ? .revoked : .missing
            }
        } catch {
            return .failed
        }
    }

    /// 检查 API Key 是否存在（不解密）
    func checkAPIKeyExistence(account: String) -> Bool {
        guard !storeDisabled, let payload = try? readPayload() else { return false }
        if let provider = Self.customProviderAccount(for: account),
           payload.customProviderCredentials?[provider]?.revoked == true { return false }
        return payload.entries.contains { $0.account == account }
    }

    /// 删除 API Key。成功或条目已不存在时返回 true。
    @discardableResult
    func deleteAPIKey(account: String, customProviderGeneration: String? = nil) -> Bool {
        deleteAPIKeyResult(account: account, customProviderGeneration: customProviderGeneration) == .durable
    }

    func deleteAPIKeyResult(account: String, customProviderGeneration: String? = nil) -> MutationResult {
        guard !storeDisabled else { return .notCommitted }
        guard !account.hasPrefix(Self.onePasswordClearMarkerPrefix),
              account != Self.legacyFirecrawlClearMarker else { return .notCommitted }
        do {
            return try withMutationLock {
                var payload = try readPayload()
                guard Self.permitsCredentialMutation(
                    account: account, generation: customProviderGeneration, payload: payload
                ) else { return .notCommitted }
                let before = payload.entries.count
                payload.entries.removeAll { $0.account == account }
                let removedEntry = payload.entries.count < before
                var addedClearMarker = false
                if let marker = Self.onePasswordClearMarker(forScopedAccount: account),
                   !payload.entries.contains(where: { $0.account == marker }) {
                    payload.entries.append(Self.onePasswordClearEntry(account: marker))
                    addedClearMarker = true
                }
                if account == Self.legacyFirecrawlAccount,
                   !payload.entries.contains(where: { $0.account == Self.legacyFirecrawlClearMarker }) {
                    payload.entries.append(Self.onePasswordClearEntry(account: Self.legacyFirecrawlClearMarker))
                    addedClearMarker = true
                }
                // Deleting a custom provider's key also invalidates every
                // earlier save/import intent, even when the key was already
                // absent. Scoped references are intentionally left intact.
                let advancedCustomGeneration: Bool
                if let provider = Self.customProviderAccount(for: account), provider == account {
                    var states = payload.customProviderCredentials ?? [:]
                    let previous = states[provider]
                    // Remove the key's binding to any saved 1Password reference.
                    // The reference entry itself is retained, but it can no
                    // longer auto-renew an old secret over a future key.
                    states[provider] = CustomProviderCredentialState(
                        generation: UUID().uuidString, revoked: false,
                        endpointIdentity: previous?.endpointIdentity,
                        referenceEndpointIdentity: nil,
                        referenceRevision: UUID().uuidString
                    )
                    payload.customProviderCredentials = states
                    advancedCustomGeneration = true
                } else {
                    advancedCustomGeneration = false
                }
                var durabilityUnknown = false
                if removedEntry || addedClearMarker || advancedCustomGeneration {
                    do {
                        try writePayload(payload)
                    } catch is PrivateFilePostCommitError {
                        durabilityUnknown = true
                    }
                } else {
                    // The entry may be absent because an earlier rename was
                    // visible but its directory sync failed. Retry the barrier
                    // before reporting that the deletion is durable.
                    do {
                        try PrivateFile.syncContainingDirectory(of: storeFile)
                    } catch {
                        durabilityUnknown = true
                    }
                }

                // 仅在确认条目不存在后清理状态标记。
                metadataDefaults.removeObject(forKey: "hasAIKey-\(account)")
                metadataDefaults.removeObject(forKey: "apiKeyLastSaved-\(account)")
                if account.hasPrefix("ai-key-") {
                    let providerRaw = String(account.dropFirst("ai-key-".count))
                    metadataDefaults.removeObject(forKey: "hasAIKey-\(providerRaw)")
                }
                return durabilityUnknown ? .committedDurabilityUnknown : .durable
            }
        } catch EncryptedKeyStoreError.writeUnverified {
            return .unverified
        } catch {
            NSLog("[EncryptedKeyStore] deleteAPIKey(\(account)) failed: \(error.localizedDescription)")
            return .notCommitted
        }
    }

    @discardableResult
    func deleteCustomProviderCredentials(
        account: String, expectedState: CustomProviderCredentialState? = nil
    ) -> Bool {
        deleteCustomProviderCredentialsResult(account: account, expectedState: expectedState) == .durable
    }

    func deleteCustomProviderCredentialsResult(
        account: String, expectedState: CustomProviderCredentialState? = nil
    ) -> MutationResult {
        replaceCustomProviderCredentials(account: account, expectedState: expectedState, revoked: true)
    }

    /// A changed connection must never inherit the old key or reference. A new
    /// active generation also rejects writes that began for the old connection.
    func resetCustomProviderCredentialsForConnectionChange(
        account: String, expectedState: CustomProviderCredentialState?
    ) -> MutationResult {
        replaceCustomProviderCredentials(account: account, expectedState: expectedState, revoked: false)
    }

    private func replaceCustomProviderCredentials(
        account: String, expectedState: CustomProviderCredentialState?, revoked: Bool
    ) -> MutationResult {
        guard !storeDisabled, account.hasPrefix("custom:"), account.count > "custom:".count else { return .notCommitted }
        let accounts = [account, Self.onePasswordRefAccount(for: account)]
        do {
            return try withMutationLock {
                var payload = try readPayload()
                guard payload.customProviderCredentials?[account] == expectedState else { return .notCommitted }
                payload.entries.removeAll { accounts.contains($0.account) }
                let marker = Self.onePasswordClearMarkerPrefix + Self.onePasswordRefAccount(for: account)
                if !payload.entries.contains(where: { $0.account == marker }) {
                    payload.entries.append(Self.onePasswordClearEntry(account: marker))
                }
                var states = payload.customProviderCredentials ?? [:]
                states[account] = CustomProviderCredentialState(generation: UUID().uuidString, revoked: revoked)
                payload.customProviderCredentials = states
                var durabilityUnknown = false
                do {
                    try writePayload(payload)
                } catch is PrivateFilePostCommitError {
                    durabilityUnknown = true
                }
                for name in accounts {
                    metadataDefaults.removeObject(forKey: "hasAIKey-\(name)")
                    metadataDefaults.removeObject(forKey: "apiKeyLastSaved-\(name)")
                }
                return durabilityUnknown ? .committedDurabilityUnknown : .durable
            }
        } catch EncryptedKeyStoreError.writeUnverified {
            return .unverified
        } catch {
            NSLog("[EncryptedKeyStore] deleteCustomProviderCredentials(\(account)) failed: \(error.localizedDescription)")
            return .notCommitted
        }
    }

    /// Distinguish a legacy account from unreadable storage. The directory
    /// barrier also makes a previous visible but unconfirmed rename durable.
    func customProviderCredentialStateResult(account: String) -> CustomProviderCredentialStateResult {
        guard !storeDisabled, Self.customProviderAccount(for: account) == account else { return .failed }
        do {
            return try withMutationLock {
                let payload = try readPayload()
                if FileManager.default.fileExists(atPath: storeFile.path) {
                    try PrivateFile.syncContainingDirectory(of: storeFile)
                }
                guard let state = payload.customProviderCredentials?[account] else { return .legacy }
                return .state(state)
            }
        } catch {
            return .failed
        }
    }

    func customProviderRevocationGeneration(account: String) -> String? {
        guard !storeDisabled,
              Self.customProviderAccount(for: account) == account,
              let state = try? readPayload().customProviderCredentials?[account],
              state.revoked else { return nil }
        return state.generation
    }

    func reactivateCustomProviderCredentials(account: String, matchingRevocation: String) -> String? {
        guard case let .activated(generation) = reactivateCustomProviderCredentialsResult(
            account: account, matchingRevocation: matchingRevocation
        ) else { return nil }
        return generation
    }

    func reactivateCustomProviderCredentialsResult(
        account: String, matchingRevocation: String
    ) -> CustomProviderReactivationResult {
        guard !storeDisabled, Self.customProviderAccount(for: account) == account else { return .failed(.notCommitted) }
        do {
            return try withMutationLock {
                var payload = try readPayload()
                guard let state = payload.customProviderCredentials?[account],
                      state.revoked, state.generation == matchingRevocation else { return .failed(.notCommitted) }
                let generation = UUID().uuidString
                payload.customProviderCredentials?[account] = CustomProviderCredentialState(
                    generation: generation, revoked: false
                )
                try writePayload(payload)
                return .activated(generation)
            }
        } catch is PrivateFilePostCommitError {
            return .failed(.committedDurabilityUnknown)
        } catch EncryptedKeyStoreError.writeUnverified {
            return .failed(.unverified)
        } catch {
            NSLog("[EncryptedKeyStore] reactivateCustomProviderCredentials(\(account)) failed: \(error.localizedDescription)")
            return .failed(.notCommitted)
        }
    }

    /// Explicit one-time migration for credentials saved before endpoint
    /// binding existed. Only called after the user confirms; never automatic.
    func bindLegacyCustomCredentialsResult(
        account: String, endpointIdentity: String
    ) -> MutationResult {
        guard !storeDisabled, !endpointIdentity.isEmpty,
              Self.customProviderAccount(for: account) == account else { return .notCommitted }
        do {
            return try withMutationLock {
                var payload = try readPayload()
                guard payload.customProviderCredentials?[account] == nil,
                      payload.entries.contains(where: { $0.account == account }) else {
                    return .notCommitted
                }
                let scoped = Self.onePasswordRefAccount(for: account)
                let hasReference = payload.entries.contains(where: { $0.account == scoped })
                var state = CustomProviderCredentialState(
                    generation: UUID().uuidString,
                    revoked: false
                )
                state.endpointIdentity = endpointIdentity
                if hasReference {
                    state.referenceEndpointIdentity = endpointIdentity
                    state.referenceRevision = UUID().uuidString
                }
                var states = payload.customProviderCredentials ?? [:]
                states[account] = state
                payload.customProviderCredentials = states
                do {
                    try writePayload(payload)
                    return .durable
                } catch is PrivateFilePostCommitError {
                    return .committedDurabilityUnknown
                }
            }
        } catch EncryptedKeyStoreError.writeUnverified {
            return .unverified
        } catch {
            NSLog("[EncryptedKeyStore] bindLegacyCustomCredentials(\(account)) failed: \(error.localizedDescription)")
            return .notCommitted
        }
    }

    // MARK: - Staleness
    /// 检查 Key 是否过期（30 天）
    /// 使用 UserDefaults 时间戳，与 KeychainManager 保持兼容
    func isKeyStale(account: String) -> Bool {
        let lastSaved = metadataDefaults.double(forKey: "apiKeyLastSaved-\(account)")
        guard lastSaved > 0 else { return true }
        return Date().timeIntervalSince1970 - lastSaved > 30 * 24 * 3600
    }

    // MARK: - 1Password Reference

    private static let onePasswordRefAccount = "one-password-ref"
    private static let onePasswordClearMarkerPrefix = "__newsbar_1password_cleared_v1__."

    /// One reference per credential account. A single shared value let saving a
    /// key for one provider overwrite the reference used for another.
    private static func onePasswordRefAccount(for account: String) -> String {
        "one-password-ref.\(account)"
    }

    private static func onePasswordClearMarker(forScopedAccount account: String) -> String? {
        let prefix = "one-password-ref."
        guard account.hasPrefix(prefix), account.count > prefix.count else { return nil }
        return onePasswordClearMarkerPrefix + account
    }

    /// Reserved, non-secret state entry. Its presence suppresses legacy fallback;
    /// it is stored in the same payload transaction as the scoped reference.
    private static func onePasswordClearEntry(account: String) -> Entry {
        Entry(account: account, nonce: Data(), ciphertext: Data())
    }

    private static func onePasswordRefreshEntries(account: String, payload: EncryptedPayload) -> [Entry] {
        let scoped = onePasswordRefAccount(for: account)
        let marker = onePasswordClearMarker(forScopedAccount: scoped)
        return payload.entries.filter {
            $0.account == account || $0.account == scoped || $0.account == onePasswordRefAccount || $0.account == marker
        }
    }

    func onePasswordRefreshSnapshot(account: String, endpointIdentity: String? = nil) -> OnePasswordRefreshSnapshot? {
        guard !storeDisabled else { return nil }
        do {
            let payload = try readPayload()
            guard case let .found(key) = readAPIKeyResult(account: account, payload: payload), !key.isEmpty,
                  payload.customProviderCredentials?[account]?.revoked != true else { return nil }
            let reference: ReadResult
            if Self.customProviderAccount(for: account) == account {
                guard let endpointIdentity, !endpointIdentity.isEmpty,
                      let state = payload.customProviderCredentials?[account],
                      state.endpointIdentity == endpointIdentity,
                      state.referenceEndpointIdentity == endpointIdentity else { return nil }
                let scoped = Self.onePasswordRefAccount(for: account)
                if let marker = Self.onePasswordClearMarker(forScopedAccount: scoped),
                   payload.entries.contains(where: { $0.account == marker }) { return nil }
                guard case let .found(value) = readAPIKeyResult(account: scoped, payload: payload),
                      !value.isEmpty else { return nil }
                reference = .found(value)
            } else {
                reference = readOnePasswordRefResult(account: account, payload: payload)
            }
            if case .failed = reference { return nil }
            return OnePasswordRefreshSnapshot(
                account: account,
                reference: reference,
                watchedEntries: Self.onePasswordRefreshEntries(account: account, payload: payload),
                customState: payload.customProviderCredentials?[account]
            )
        } catch {
            return nil
        }
    }

    @discardableResult
    func saveOnePasswordRef(_ ref: String) -> Bool {
        saveAPIKey(ref, account: Self.onePasswordRefAccount)
    }

    func readOnePasswordRef() -> String? {
        readAPIKey(account: Self.onePasswordRefAccount)
    }

    func deleteOnePasswordRef() {
        deleteAPIKey(account: Self.onePasswordRefAccount)
    }

    @discardableResult
    func saveOnePasswordRef(_ ref: String, account: String, customProviderGeneration: String? = nil) -> Bool {
        saveAPIKey(ref, account: Self.onePasswordRefAccount(for: account), customProviderGeneration: customProviderGeneration)
    }

    func saveOnePasswordRefResult(_ ref: String, account: String, customProviderGeneration: String? = nil) -> MutationResult {
        saveAPIKeyResult(ref, account: Self.onePasswordRefAccount(for: account), customProviderGeneration: customProviderGeneration)
    }

    /// Scoped reference first, then the legacy single value so a reference
    /// stored before this change keeps working until it is re-saved.
    func readOnePasswordRef(account: String) -> String? {
        guard case let .found(reference) = readOnePasswordRefResult(account: account),
              !reference.isEmpty else { return nil }
        return reference
    }

    func readOnePasswordRefResult(account: String) -> ReadResult {
        guard !storeDisabled else { return .failed }
        // Custom references require an endpoint binding; the generic read has
        // no context and must fail closed rather than fall back to the shared
        // reference.
        if Self.customProviderAccount(for: account) != nil { return .missing }
        do {
            // Resolve the marker, scoped value and shared value from one snapshot.
            return readOnePasswordRefResult(account: account, payload: try readPayload())
        } catch {
            NSLog("[EncryptedKeyStore] readOnePasswordRef failed: \(error.localizedDescription)")
            return .failed
        }
    }

    private func readOnePasswordRefResult(account: String, payload: EncryptedPayload) -> ReadResult {
        let scopedAccount = Self.onePasswordRefAccount(for: account)
        if let marker = Self.onePasswordClearMarker(forScopedAccount: scopedAccount),
           payload.entries.contains(where: { $0.account == marker }) {
            // Unlike .missing, this cannot trigger the caller's legacy fallback.
            return .found("")
        }
        if payload.customProviderCredentials?[account]?.revoked == true {
            return .found("")
        }
        switch readAPIKeyResult(account: scopedAccount, payload: payload) {
        case let .found(scoped) where !scoped.isEmpty:
            return .found(scoped)
        case .missing, .found:
            return readAPIKeyResult(account: Self.onePasswordRefAccount, payload: payload)
        case .failed:
            return .failed
        }
    }

    func deleteOnePasswordRef(account: String, customProviderGeneration: String? = nil) {
        deleteAPIKey(account: Self.onePasswordRefAccount(for: account), customProviderGeneration: customProviderGeneration)
    }

    func deleteOnePasswordRefResult(account: String, customProviderGeneration: String? = nil) -> MutationResult {
        deleteAPIKeyResult(account: Self.onePasswordRefAccount(for: account), customProviderGeneration: customProviderGeneration)
    }

    func deleteBoundCustomReferenceResult(
        account: String, expectedState: CustomProviderCredentialState, endpointIdentity: String,
        operationRevision: String = UUID().uuidString
    ) -> MutationResult {
        guard !storeDisabled, !Task.isCancelled,
              Self.customProviderAccount(for: account) == account,
              !expectedState.revoked, expectedState.endpointIdentity == endpointIdentity,
              !operationRevision.isEmpty, operationRevision != expectedState.referenceRevision else { return .notCommitted }
        let scoped = Self.onePasswordRefAccount(for: account)
        do {
            return try withMutationLock {
                var payload = try readPayload()
                guard !Task.isCancelled, payload.customProviderCredentials?[account] == expectedState else {
                    return .notCommitted
                }
                payload.entries.removeAll { $0.account == scoped }
                if let marker = Self.onePasswordClearMarker(forScopedAccount: scoped),
                   !payload.entries.contains(where: { $0.account == marker }) {
                    payload.entries.append(Self.onePasswordClearEntry(account: marker))
                }
                var updated = expectedState
                updated.referenceEndpointIdentity = nil
                updated.referenceRevision = operationRevision
                payload.customProviderCredentials?[account] = updated
                var durabilityUnknown = false
                do {
                    try writePayload(payload)
                } catch is PrivateFilePostCommitError {
                    durabilityUnknown = true
                }
                metadataDefaults.removeObject(forKey: "hasAIKey-\(scoped)")
                metadataDefaults.removeObject(forKey: "apiKeyLastSaved-\(scoped)")
                return durabilityUnknown ? .committedDurabilityUnknown : .durable
            }
        } catch EncryptedKeyStoreError.writeUnverified {
            return .unverified
        } catch {
            return .notCommitted
        }
    }

    /// Retries one specific reference update without adopting changes made by
    /// another writer. If the first write may already have committed, confirm
    /// that exact operation and sync it rather than rewriting newer data.
    func applyBoundCustomReferenceResult(
        _ reference: String, account: String, expectedState: CustomProviderCredentialState,
        endpointIdentity: String, operationRevision: String
    ) -> MutationResult {
        guard !storeDisabled, !Task.isCancelled,
              Self.customProviderAccount(for: account) == account,
              !expectedState.revoked, !endpointIdentity.isEmpty,
              expectedState.endpointIdentity == endpointIdentity,
              !operationRevision.isEmpty, operationRevision != expectedState.referenceRevision else { return .notCommitted }
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = Self.onePasswordRefAccount(for: account)
        var committedState = expectedState
        committedState.referenceEndpointIdentity = trimmed.isEmpty ? nil : endpointIdentity
        committedState.referenceRevision = operationRevision

        enum Preparation {
            case needsWrite, confirmed, conflict, unverified, syncUnknown
        }
        let preparation: Preparation
        do {
            preparation = try withMutationLock {
                guard !Task.isCancelled else { return .conflict }
                let payload = try readPayload()
                let current = payload.customProviderCredentials?[account]
                if current == expectedState { return .needsWrite }
                guard current == committedState else { return .conflict }
                if trimmed.isEmpty {
                    guard !payload.entries.contains(where: { $0.account == scoped }),
                          let marker = Self.onePasswordClearMarker(forScopedAccount: scoped),
                          payload.entries.contains(where: { $0.account == marker }) else { return .unverified }
                } else {
                    guard case let .found(value) = readAPIKeyResult(account: scoped, payload: payload),
                          value == trimmed else { return .unverified }
                }
                do {
                    try PrivateFile.syncContainingDirectory(of: storeFile)
                    return .confirmed
                } catch {
                    return .syncUnknown
                }
            }
        } catch {
            return .unverified
        }
        switch preparation {
        case .needsWrite:
            if trimmed.isEmpty {
                return deleteBoundCustomReferenceResult(
                    account: account, expectedState: expectedState, endpointIdentity: endpointIdentity,
                    operationRevision: operationRevision
                )
            }
            return saveBoundCustomReferenceResult(
                trimmed, account: account, expectedState: expectedState, endpointIdentity: endpointIdentity,
                operationRevision: operationRevision
            )
        case .confirmed: return .durable
        case .conflict:
            // Another writer may have reached the same target. Treat that as
            // success instead of asking the user to retry a completed change.
            if trimmed.isEmpty {
                if case .missing = readBoundCustomReferenceResult(
                    account: account, endpointIdentity: endpointIdentity
                ) {
                    return .durable
                }
            } else if case let .found(current) = readBoundCustomReferenceResult(
                account: account, endpointIdentity: endpointIdentity
            ), current == trimmed {
                return .durable
            }
            return .notCommitted
        case .unverified: return .unverified
        case .syncUnknown: return .committedDurabilityUnknown
        }
    }

    // MARK: - Keychain 迁移

    enum KeychainMigrationAction: Equatable {
        case migrate(String)
        case markComplete
        case retry
    }

    static func keychainMigrationAction(_ result: KeychainManager.ReadResult) -> KeychainMigrationAction {
        switch result {
        case .found(let value):
            return value.isEmpty ? .markComplete : .migrate(value)
        case .missing:
            return .markComplete
        case .failed:
            // An unreadable keychain is not proof that no key exists.
            return .retry
        }
    }

    /// 一次性迁移: 从 Keychain 读取所有条目，加密写入文件。
    /// 使用逐 item 原子策略：写入文件并验证 → 删除 Keychain 项 → 记录 per-item flag。
    /// 崩溃安全：未完成迁移的项下次启动自动重试。
    static func migrateFromKeychainIfNeeded() {
        guard !isDisabled else { return }

        let defaults = TestIsolation.defaults
        guard !defaults.bool(forKey: "didMigrateAPIKeysFromKeychain") else { return }

        // 确保 UUID 快照在迁移前已保存
        _ = try? Self.resolveMachineIdentifier(in: Self.defaultStoreDirectory)

        // 收集所有需要迁移的 account
        let providerAccounts = AIProvider.allCases.map { $0.apiKeyAccount() }
        let allAccounts = ["one-password-ref"] + providerAccounts

        let migratedKey = "migratedToEncrypted-"

        // 使用同步方式逐项迁移（在 app 启动早期执行）
        for account in allAccounts {
            // 检查此项是否已迁移
            guard !defaults.bool(forKey: migratedKey + account) else { continue }

            // 从 Keychain 读取
            let readResult: KeychainManager.ReadResult
            if account == "one-password-ref" {
                readResult = KeychainManager.readOnePasswordRefResult()
            } else {
                readResult = KeychainManager.readAPIKeyResult(account: account)
            }
            let keyValue: String
            switch Self.keychainMigrationAction(readResult) {
            case .retry:
                // The keychain refused the read. Keep the per-item flag unset
                // so the next launch retries instead of losing the key.
                NSLog("[EncryptedKeyStore] Keychain read failed for \(account), retry next launch")
                continue
            case .markComplete:
                defaults.set(true, forKey: migratedKey + account)
                continue
            case .migrate(let value):
                keyValue = value
            }

            // 同步写入 EncryptedKeyStore
            // actor 方法需要 async 上下文，这里用同步包装
            let writeSuccess: Bool
            let readBack: String?
            do {
                // 使用同步执行避免 async 链
                let store = EncryptedKeyStore()
                let sem = DispatchSemaphore(value: 0)
                var writeResult = false
                var readResult: String? = nil
                Task {
                    writeResult = await store.saveAPIKey(keyValue, account: account)
                    if writeResult {
                        readResult = await store.readAPIKey(account: account)
                    }
                    sem.signal()
                }
                sem.wait()
                writeSuccess = writeResult
                readBack = readResult
            }

            guard writeSuccess, readBack == keyValue else {
                NSLog("[EncryptedKeyStore] Migration verify failed for \(account), retry next launch")
                continue
            }

            // 验证成功 → 删除 Keychain 项
            if account == "one-password-ref" {
                KeychainManager.deleteOnePasswordRef()
            } else {
                KeychainManager.deleteAPIKey(account: account)
            }
            defaults.set(true, forKey: migratedKey + account)
            NSLog("[EncryptedKeyStore] Migrated \(account) from Keychain ✓")
        }

        // 检查是否所有项都迁移完成
        let allMigrated = allAccounts.allSatisfy {
            defaults.bool(forKey: migratedKey + $0)
        }
        if allMigrated {
            defaults.set(true, forKey: "didMigrateAPIKeysFromKeychain")
            // 清理 per-item flags
            for account in allAccounts {
                defaults.removeObject(forKey: migratedKey + account)
            }
            NSLog("[EncryptedKeyStore] Keychain migration complete ✓")
        }
    }
}
