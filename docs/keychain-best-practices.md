# macOS Keychain 安全存储最佳实践

> 基于 NewsBar 项目实战经验，综合 CodexBar、Token-Cost-App、OnlySwitch 等优质开源项目的验证方案。

---

## 1. 核心挑战

### 1.1 macOS ad-hoc 签名与 Keychain ACL

macOS 的 file-based keychain 对每个 keychain item 维护一个 ACL，记录哪些应用可以访问。当使用 ad-hoc 签名（`codesign --sign -`）时：

- **每次构建产生不同的 code signing identity**
- 上次构建创建的 keychain item 的 ACL 绑定旧签名
- 新构建的 app 访问旧 item 时，macOS 判定为"不同的应用"→ **弹出系统授权对话框**

这是开发阶段反复弹窗的**首要根因**。

### 1.2 `SecItemUpdate` vs `SecItemDelete+SecItemAdd`

| 策略 | 行为 | ad-hoc 签名下的结果 |
|------|------|-------------------|
| `SecItemUpdate` 优先 | 原地修改 item | ACL 不匹配 → **弹窗** |
| `SecItemDelete` + `SecItemAdd` | 删除旧 item 后新建 | 新 item 的 ACL 自动包含当前签名 → **不弹窗** ✅ |

**结论**：对 ad-hoc 签名的 macOS 应用，**永远使用 Delete+Add 策略**。

---

## 2. 写入策略：SecItemDelete + SecItemAdd

```swift
static func saveAPIKey(_ key: String) -> Bool {
    guard !isDisabled else { return true }
    guard let data = key.data(using: .utf8) else { return false }

    let query = baseQuery(account: "deepseek-api-key")
    SecItemDelete(query as CFDictionary)  // 清除旧 ACL

    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    addQuery[kSecAttrSynchronizable as String] = false
    let status = SecItemAdd(addQuery as CFDictionary, nil)

    if status == errSecSuccess {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "apiKeyLastSaved")
        UserDefaults.standard.set(true, forKey: "hasDeepSeekAPIKey")
        return true
    }
    return false
}
```

**关键设计决策**：

| 决策 | 取值 | 原因 |
|------|------|------|
| `kSecAttrAccessible` | `WhenUnlockedThisDeviceOnly` | `ThisDeviceOnly` 变体对代码签名变化更宽容 |
| `kSecAttrSynchronizable` | `false` | 不同步到 iCloud，避免设备间迁移导致的 ACL 问题 |
| `kSecClass` | `kSecClassGenericPassword` | 通用密码类型，不需要特殊 entitlement |

---

## 3. 读取策略：双重 NoUI 保护

### 3.1 单靠 `kSecUseAuthenticationUIFail` 不够

Apple 在 macOS 11.0 标记 `kSecUseAuthenticationUIFail` 为 deprecated，推荐使用 `LAContext.interactionNotAllowed`。但实战经验（CodexBar 项目）表明：
- **macOS file-based keychain 上，单独使用 `LAContext.interactionNotAllowed` 仍可能弹出 Allow/Deny 对话框**
- **必须两者同时使用**才能彻底阻止弹窗

### 3.2 双重保护实现

```swift
import LocalAuthentication

private static func applyNoUI(to query: inout [String: Any]) {
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
    query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
}
```

在所有 `SecItemCopyMatching` 调用中统一使用：

```swift
static func readAPIKey(allowUI: Bool = false) -> String? {
    guard !isDisabled else { return nil }
    var query = baseQuery(account: "deepseek-api-key")
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    if !allowUI {
        applyNoUI(to: &query)
    }
    // ... SecItemCopyMatching
}
```

`allowUI` 参数默认为 `false`，仅在用户主动操作的场景（如 AITab 中测试连接）才传 `true`。

---

## 4. 启动时零 Keychain 交互

### 4.1 UserDefaults Flag 预检

使用 `UserDefaults` boolean flag 做**零 Keychain 交互**的存在性判断：

```swift
// 保存时设置 flag
UserDefaults.standard.set(true, forKey: "hasDeepSeekAPIKey")

// 启动时检查 flag（不碰 Keychain）
let hasKey = UserDefaults.standard.bool(forKey: "hasDeepSeekAPIKey")
```

### 4.2 内存缓存

```swift
@ObservationIgnored var cachedAPIKey: String?
```

- 首次成功读取 key 后存入 `cachedAPIKey`
- 整个 app session 不再重复读 Keychain
- 重启后缓存丢失，但 `hasDeepSeekAPIKey` flag 仍在，可快速确认 key 存在

### 4.3 init 期间禁止 Keychain 写入

利用 `isInitializing` 守卫跳过 init 期间的 didSet 触发：

```swift
private var isInitializing = true

var onePasswordRef: String {
    didSet {
        guard !isInitializing else { return }  // init 期间跳过
        // ... Keychain 写入逻辑
    }
}

init() {
    // ... 初始化所有属性
    self.isInitializing = false  // init 结束后才允许 didSet
}
```

---

## 5. Debug KeychainAccessGate

开发期间通过 `UserDefaults` flag 完全禁用 Keychain 访问，所有读写操作静默短路：

```swift
static var isDisabled: Bool {
    #if DEBUG
    return UserDefaults.standard.bool(forKey: "debugDisableKeychainAccess")
    #else
    return false  // Release 构建永远不禁用
    #endif
}

static func readAPIKey(account: String) -> String? {
    guard !isDisabled else { return nil }  // 短路：返回 nil
    // ... 正常读取逻辑
}

static func saveAPIKey(_ key: String) -> Bool {
    guard !isDisabled else { return true }  // 短路：假装成功
    // ... 正常写入逻辑
}
```

用法：
```bash
# 启用（开发阶段避免反复弹窗）
defaults write com.newsbar.app debugDisableKeychainAccess -bool YES

# 禁用（恢复正常 Keychain 访问）
defaults delete com.newsbar.app debugDisableKeychainAccess
```

`#if DEBUG` 条件编译确保 **Release 构建不包含此代码路径**。

---

## 6. 安全增强：SecureField + 自动清空

### 6.1 输入遮盖

API Key 输入框使用 `SecureField` 替代 `TextField`，输入时显示为圆点：

```swift
SecureField("输入 DeepSeek API Key (sk-...)", text: $apiKeyInput)
```

### 6.2 保存后清空

Key 保存到 Keychain 后立即清空本地输入，不在内存留明文：

```swift
private func saveAPIKey() {
    let sanitized = SecurityPolicies.sanitizeUserInput(apiKeyInput)
    if KeychainManager.saveAPIKey(sanitized) {
        settings.cachedAPIKey = sanitized
        apiKeyInput = ""  // 清空本地明文
    }
}
```

### 6.3 不自动回填

**不在 `onAppear` 中自动将 `cachedAPIKey` 回填到输入框**，避免已保存的 key 在打开设置页时自动以明文暴露。

---

## 7. 体系架构一览

```
┌─────────────────────────────────────────────────────────────┐
│                         AITab (UI)                          │
│  SecureField → saveAPIKey() → SecItemDelete + SecItemAdd   │
│                      ↓                                      │
│              apiKeyInput = ""  (清空明文)                    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     KeychainManager                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │  applyNoUI() │  │ isDisabled   │  │  SecItemDelete   │  │
│  │  LAContext + │  │ #if DEBUG    │  │  + SecItemAdd    │  │
│  │  UIFail      │  │ UserDefaults │  │  (写入策略)       │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      AppSettings                            │
│  cachedAPIKey (内存缓存)  │  hasDeepSeekAPIKey (UD flag)    │
│  isInitializing (守卫)     │  isKeyStale (30天过期)          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      AppDelegate                            │
│  scheduleDelayedKeychainRead (1.5s 延迟静默探测)            │
│  loadAPIKeyFromKeychainIfNeeded (用户打开 popover 时触发)    │
│  refreshAPIKeyIfNeeded (1Password 集成路径)                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 8. 正确链路时序

```
app 启动
  → AppSettings.init()
    → 读取 UserDefaults flag（零 Keychain 交互）
    → isInitializing = true（阻止 didSet 触发 Keychain 写入）
    → isInitializing = false
  → applicationDidFinishLaunching
    → scheduleDelayedKeychainRead()   ← 1.5s 后用双重 NoUI 静默探测存在性
    → observeAPIKeyConfigured()       ← 注册保存通知监听
  → 用户打开 popover
    → loadAPIKeyFromKeychainIfNeeded()
      → checkAPIKeyExistence() 双重 NoUI ✅ 不弹窗
      → readAPIKey() 双重 NoUI ✅ 不弹窗
      → cachedAPIKey = key（内存缓存，Session 内不再读 Keychain）
  → 用户点「配置 Key」→ AITab → 填 key（SecureField 遮盖）
    → 点「保存」
      → saveAPIKey() → SecItemDelete + SecItemAdd
      → 此时弹出系统授权对话框 ✅（用户预期内，唯一弹窗时机）
      → apiKeyInput = ""（清空本地明文）
```

---

## 9. 参考项目

| 项目 | 核心贡献 |
|------|---------|
| [CodexBar](https://github.com/steipete/CodexBar) | 双重 NoUI 保护策略、KeychainAccessGate、KeychainMigration |
| [Token-Cost-App](https://github.com/blackkcold/Token-Cost-App-OC-Codex) | API Key 不存 Keychain 的思路、Delete+Add 写入策略 |
| [OnlySwitch](https://github.com/jacklandrin/OnlySwitch) | macOS menu bar app 的 KeychainManager 实现 |
| [OpenClaw](https://github.com/openclaw/openclaw) | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 使用 |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | `#if LOCAL_BUILD` 条件编译降级到 UserDefaults |

---

## 10. 检查清单

实施 Keychain 存储时，逐项确认：

- [ ] 所有写入使用 `SecItemDelete` + `SecItemAdd` 策略（不使用 `SecItemUpdate`）
- [ ] `kSecAttrAccessible` 使用 `ThisDeviceOnly` 变体
- [ ] `kSecAttrSynchronizable` 设为 `false`
- [ ] 所有 `SecItemCopyMatching` 调用使用双重 NoUI 保护（`LAContext.interactionNotAllowed` + `kSecUseAuthenticationUIFail`）
- [ ] 所有 Keychain 操作函数有 `isDisabled` 守卫
- [ ] `isDisabled` 用 `#if DEBUG` 包裹
- [ ] 启动时用 `UserDefaults` flag 做零 Keychain 交互的预检
- [ ] 使用内存缓存（`cachedAPIKey`）避免 Session 内重复读取
- [ ] `init()` 期间用 `isInitializing` 守卫阻止 didSet 触发 Keychain 写入
- [ ] UI 输入使用 `SecureField`，保存后清空本地输入

---

## 11. 加密文件存储方案（替代 Keychain）

> v1.5.0 起采用。适用于 AI API Key 等经济性资产。

### 11.1 动机

macOS Keychain 在 ad-hoc 签名环境下反复弹窗的问题虽然可通过双重 NoUI 保护缓解，但在某些 macOS 配置下仍可能出现授权对话框。加密文件存储方案完全消除系统弹窗，同时提供可接受的安全级别。

### 11.2 架构

```
密钥派生链:
  IOPlatformUUID (IOKit) + 硬编码 32-byte salt
  → HKDF-SHA256(inputKeyMaterial, info=bundleID, outputByteCount=32)
  → 256-bit AES-GCM 密钥

存储:
  ~/Library/Application Support/{bundleID}/apikeys.enc
  文件权限 0600，目录权限 0700
  Time Machine 排除 (NSURLIsExcludedFromBackupKey)
  格式: { version: Int, entries: [{ account, nonce, ciphertext }] }

加密:
  AES-GCM (CryptoKit)
  Nonce: 每次写入随机生成 (AES.GCM.Nonce() → SecRandomCopyBytes)
  Tag: 附加在 ciphertext 末尾 (16 bytes)
```

### 11.3 安全边界

| 威胁 | 防护 | 说明 |
|------|------|------|
| 文件浏览器查看 | ✅ AES-256-GCM 加密 | 密文不可读 |
| 跨机器 Time Machine 恢复 | ✅ UUID 绑定 | 不同机器派生不同密钥 |
| 其他 UID 访问 | ✅ 0600 权限 | 仅 owner 可读写 |
| **同 UID 恶意进程** | ❌ 无防护 | IOPlatformUUID 公开可读，攻击者可派生相同密钥 |
| 硬件更换/逻辑板更换 | ⚠️ UUID 快照 | 首次保存 UUID 快照，变更时使用旧 UUID 解密 |

### 11.4 补偿措施

- **原子写入**: temp → F_FULLFSYNC → replaceItemAt → 0600 → 读回验证
- **UUID 快照**: 首次启动保存 IOPlatformUUID，后续变更时使用旧值解密
- **Time Machine 排除**: 设置 `NSURLIsExcludedFromBackupKey`
- **actor 隔离**: `EncryptedKeyStore` 是 actor，所有操作自动序列化
- **版本化格式**: `version: Int` 字段支持未来密钥轮转
- **Debug Gate**: `#if DEBUG` + UserDefaults flag，与 KeychainManager 模式一致

### 11.5 迁移策略

从 Keychain 迁移到加密文件存储采用**逐 item 原子策略**：

1. 对每个 account: 从 Keychain 读取 (NoUI) → 写入 EncryptedKeyStore → 验证回读 → 删除 Keychain 项
2. 每个 item 迁移成功后设置 per-item flag (`migratedToEncrypted-{account}`)
3. 全部完成设置全局 flag (`didMigrateAPIKeysFromKeychain`)
4. 崩溃安全：未完成的 item 下次启动自动重试

### 11.6 与 Keychain 威胁模型对比

| 维度 | Keychain | 加密文件 |
|------|----------|----------|
| 同 UID 恶意进程 | ✅ ACL 阻止 | ❌ 可派生密钥 |
| Secure Enclave | ✅ 支持 | ❌ 不支持 |
| 跨机器迁移 | ✅ iCloud Keychain | ❌ 数据需重新输入 |
| 弹窗体验 | ⚠️ 可能弹窗 | ✅ 零弹窗 |
| 开发签名容忍 | ⚠️ ad-hoc 签名导致 ACL 变化 | ✅ 与签名无关 |

### 11.7 适用场景

- ✅ AI API Key（经济性资产，非隐私凭证）
- ✅ 非敏感配置（用户偏好、API endpoint）
- ❌ 银行密码、SSH 私钥等高敏感凭证（应继续使用 Keychain + Secure Enclave）
