import Foundation
import CryptoKit
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

    // MARK: - Debug Gate

    /// 当启用时，所有操作被跳过 — 读取返回 nil，写入假装成功。
    /// 开发期间避免反复操作加密文件。
    ///
    /// 启用: `defaults write com.newsbar.app debugDisableEncryptedStore -bool YES`
    /// 禁用: `defaults delete com.newsbar.app debugDisableEncryptedStore`
    static var isDisabled: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "debugDisableEncryptedStore")
        #else
        return false
        #endif
    }

    // MARK: - 存储路径

    private static let storeDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
        let dir = appSupport.appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        // 排除 Time Machine 备份
        var mutableDir = dir
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableDir.setResourceValues(resourceValues)
        // 限制目录权限
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path
        )
        return dir
    }()

    private static let storeFile = storeDirectory.appendingPathComponent("apikeys.enc")
    private static let tempFile = storeDirectory.appendingPathComponent("apikeys.enc.tmp")
    private static let uuidSnapshotFile = storeDirectory.appendingPathComponent(".machine-uuid")

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
        let machineUUID = try Self.resolveMachineIdentifier()
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
    private static func resolveMachineIdentifier() throws -> String {
        // 读取已保存的 UUID 快照
        if let savedUUID = try? String(contentsOf: uuidSnapshotFile, encoding: .utf8),
           !savedUUID.isEmpty {
            let currentUUID = (try? currentPlatformUUID()) ?? savedUUID
            if savedUUID != currentUUID {
                NSLog("[EncryptedKeyStore] IOPlatformUUID changed; using saved UUID for backward compatibility.")
            }
            return savedUUID
        }
        // 首次启动：保存当前 UUID 快照
        let uuid = try currentPlatformUUID()
        try Data(uuid.utf8).write(to: uuidSnapshotFile, options: .atomic)
        try? (uuidSnapshotFile as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        return uuid
    }

    // MARK: - 文件格式

    static let currentVersion = 1

    struct EncryptedPayload: Codable {
        let version: Int
        var entries: [Entry]
    }

    struct Entry: Codable {
        let account: String
        let nonce: Data            // AES-GCM nonce (12 bytes, random per write)
        let ciphertext: Data       // AES-GCM ciphertext + 16-byte auth tag
    }

    enum EncryptedKeyStoreError: LocalizedError {
        case platformUUIDUnavailable
        case encryptionFailed
        case decryptionFailed
        case fileCorrupted

        var errorDescription: String? {
            switch self {
            case .platformUUIDUnavailable: return "无法获取机器标识"
            case .encryptionFailed: return "加密写入失败"
            case .decryptionFailed: return "解密失败"
            case .fileCorrupted: return "存储文件已损坏"
            }
        }
    }

    // MARK: - Payload 读写

    private func readPayload() throws -> EncryptedPayload {
        guard FileManager.default.fileExists(atPath: Self.storeFile.path) else {
            return EncryptedPayload(version: Self.currentVersion, entries: [])
        }
        let data = try Data(contentsOf: Self.storeFile)
        do {
            return try JSONDecoder().decode(EncryptedPayload.self, from: data)
        } catch {
            throw EncryptedKeyStoreError.fileCorrupted
        }
    }

    private func writePayload(_ payload: EncryptedPayload) throws {
        let data = try JSONEncoder().encode(payload)

        // 原子写入: temp → F_FULLFSYNC → replaceItemAt → 设权限 → 读回验证
        try data.write(to: Self.tempFile, options: .atomic)

        if let fd = fopen(Self.tempFile.path, "a") {
            _ = fcntl(fileno(fd), F_FULLFSYNC)
            fclose(fd)
        }

        if FileManager.default.fileExists(atPath: Self.storeFile.path) {
            _ = try FileManager.default.replaceItemAt(
                Self.storeFile,
                withItemAt: Self.tempFile
            )
        } else {
            try FileManager.default.moveItem(at: Self.tempFile, to: Self.storeFile)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Self.storeFile.path
        )
        // 排除 Time Machine 备份
        try? (Self.storeFile as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)

        // 读回验证
        let verifyData = try Data(contentsOf: Self.storeFile)
        guard verifyData == data else {
            throw EncryptedKeyStoreError.encryptionFailed
        }
    }

    // MARK: - API Key CRUD

    /// 保存 API Key（加密写入文件）
    /// - Returns: true 表示保存成功
    @discardableResult
    func saveAPIKey(_ key: String, account: String) -> Bool {
        guard !Self.isDisabled else { return true }
        guard !key.isEmpty,
              let plaintext = key.data(using: .utf8) else { return false }

        do {
            let symmetricKey = try deriveKey()

            // 每次写入生成唯一随机 nonce — AES.GCM.Nonce() 使用 SecRandomCopyBytes
            let nonce = AES.GCM.Nonce()
            let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)

            var payload = try readPayload()
            payload.entries.removeAll { $0.account == account }
            payload.entries.append(Entry(
                account: account,
                nonce: Data(nonce),
                ciphertext: sealedBox.ciphertext + sealedBox.tag
            ))

            try writePayload(payload)

            // 更新 staleness 时间戳和存在性 flag（与 KeychainManager 兼容）
            let timestampKey = "apiKeyLastSaved-\(account)"
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)
            UserDefaults.standard.set(true, forKey: "hasAIKey-\(account)")
            if account.hasPrefix("ai-key-") {
                let providerRaw = String(account.dropFirst("ai-key-".count))
                UserDefaults.standard.set(true, forKey: "hasAIKey-\(providerRaw)")
            }
            return true
        } catch {
            NSLog("[EncryptedKeyStore] saveAPIKey(\(account)) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 读取 API Key（从加密文件解密）
    /// - Returns: 解密后的 key，不存在或解密失败返回 nil
    func readAPIKey(account: String) -> String? {
        guard !Self.isDisabled else { return nil }

        do {
            let payload = try readPayload()
            guard let entry = payload.entries.first(where: { $0.account == account }) else {
                return nil
            }

            let symmetricKey = try deriveKey()

            // 拆分 ciphertext 和 tag（最后 16 字节）
            guard entry.ciphertext.count > 16 else {
                NSLog("[EncryptedKeyStore] Entry for \(account) has invalid ciphertext length")
                return nil
            }
            let tag = entry.ciphertext.suffix(16)
            let ciphertext = entry.ciphertext.prefix(entry.ciphertext.count - 16)

            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: entry.nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)

            return String(data: decrypted, encoding: .utf8)
        } catch let error as CryptoKitError {
            if case .authenticationFailure = error {
                NSLog("[EncryptedKeyStore] GCM auth failure for \(account) — key or data mismatch")
            }
            return nil
        } catch {
            NSLog("[EncryptedKeyStore] readAPIKey(\(account)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 检查 API Key 是否存在（不解密）
    func checkAPIKeyExistence(account: String) -> Bool {
        guard !Self.isDisabled else { return false }
        return (try? readPayload().entries.contains { $0.account == account }) ?? false
    }

    /// 删除 API Key
    func deleteAPIKey(account: String) {
        guard !Self.isDisabled else { return }
        do {
            var payload = try readPayload()
            let before = payload.entries.count
            payload.entries.removeAll { $0.account == account }
            guard payload.entries.count < before else { return } // 没找到，不写
            try writePayload(payload)
        } catch {
            NSLog("[EncryptedKeyStore] deleteAPIKey(\(account)) failed: \(error.localizedDescription)")
        }

        // 清理 UserDefaults flag
        UserDefaults.standard.removeObject(forKey: "hasAIKey-\(account)")
        UserDefaults.standard.removeObject(forKey: "apiKeyLastSaved-\(account)")
        if account.hasPrefix("ai-key-") {
            let providerRaw = String(account.dropFirst("ai-key-".count))
            UserDefaults.standard.removeObject(forKey: "hasAIKey-\(providerRaw)")
        }
    }

    // MARK: - Staleness

    /// 检查 Key 是否过期（30 天）
    /// 使用 UserDefaults 时间戳，与 KeychainManager 保持兼容
    func isKeyStale(account: String) -> Bool {
        let lastSaved = UserDefaults.standard.double(forKey: "apiKeyLastSaved-\(account)")
        guard lastSaved > 0 else { return true }
        return Date().timeIntervalSince1970 - lastSaved > 30 * 24 * 3600
    }

    // MARK: - 1Password Reference

    private static let onePasswordRefAccount = "one-password-ref"

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

    // MARK: - Keychain 迁移

    /// 一次性迁移: 从 Keychain 读取所有条目，加密写入文件。
    /// 使用逐 item 原子策略：写入文件并验证 → 删除 Keychain 项 → 记录 per-item flag。
    /// 崩溃安全：未完成迁移的项下次启动自动重试。
    static func migrateFromKeychainIfNeeded() {
        guard !isDisabled else { return }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didMigrateAPIKeysFromKeychain") else { return }

        // 确保 UUID 快照在迁移前已保存
        _ = try? resolveMachineIdentifier()

        // 收集所有需要迁移的 account
        let providerAccounts = AIProvider.allCases.map { $0.apiKeyAccount() }
        let allAccounts = ["one-password-ref"] + providerAccounts

        let migratedKey = "migratedToEncrypted-"

        // 使用同步方式逐项迁移（在 app 启动早期执行）
        for account in allAccounts {
            // 检查此项是否已迁移
            guard !defaults.bool(forKey: migratedKey + account) else { continue }

            // 从 Keychain 读取
            let key: String?
            if account == "one-password-ref" {
                key = KeychainManager.readOnePasswordRef()
            } else {
                key = KeychainManager.readAPIKey(account: account)
            }

            guard let keyValue = key, !keyValue.isEmpty else {
                // 无 Keychain 数据，标记已迁移（跳过此项）
                defaults.set(true, forKey: migratedKey + account)
                continue
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
