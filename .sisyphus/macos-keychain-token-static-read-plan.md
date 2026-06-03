# macOS Swift App Keychain Token 保存与静默读取方案

版本：2026-05-25  
适用对象：macOS Swift / SwiftUI App，需要保存 API Key、Access Token、Refresh Token，并尽量避免 Keychain 系统授权弹窗。

---

## 0. 核心结论

### 标准事实

macOS Keychain 的静默读取不是“绕过授权”，而是依赖以下机制：

```text
App 自己创建 Keychain item
        ↓
创建者应用被自动信任
        ↓
macOS 用代码签名的 Designated Requirement 追踪该 App
        ↓
后续同一 App 读取自己的 item
        ↓
login keychain 已解锁时，通常静默返回
```

Apple 官方说明：Keychain Access Controls 中，创建 item 的应用会被自动信任；后续访问会通过该应用的 Designated Requirement（DR）追踪。

---

## 1. 正规流程：稳定签名 + App 自己创建 Keychain item

### 1.1 目标

实现：

```text
系统级加密
+ token 不落明文文件
+ App 后续启动静默读取
+ 不反复弹 Keychain 授权框
+ 支持正式分发
```

---

## 2. 正规链路

### 2.1 构建与签名链路

```text
Apple Developer Account
        ↓
Apple Development / Developer ID Application Certificate
        ↓
codesign 给 .app 签名
        ↓
App 获得稳定身份
        ↓
macOS Keychain 用 DR 识别是否为同一 App
```

稳定身份主要由以下内容构成：

| 项目 | 说明 |
|---|---|
| Bundle Identifier | App 的逻辑身份，例如 `com.yourcompany.yourapp` |
| Team ID | Apple Developer Team 标识 |
| Code Signature | App 签名 |
| Designated Requirement | macOS 判断“是不是同一个 App”的核心规则 |
| Entitlements | 沙盒、Keychain Access Group 等权限声明 |

---

### 2.2 首次保存 token

```text
用户在 App 内输入 API Key / 完成 OAuth
        ↓
App 调用 SecItemAdd
        ↓
token 作为 Generic Password Item 写入 Keychain
        ↓
创建者 = 当前 App
        ↓
当前 App 自动成为可信访问方
```

推荐存储内容：

| 数据 | 推荐位置 |
|---|---|
| refresh_token | Keychain |
| api_key | Keychain |
| local database encryption key | Keychain |
| access_token | 内存优先；必要时短期 Keychain |
| user_id / email / workspace_id | UserDefaults |
| 缓存数据 | Application Support / SQLite |

---

### 2.3 后续静默读取

```text
App 启动
        ↓
调用 SecItemCopyMatching
        ↓
securityd / secd 校验：
- login keychain 是否解锁
- App 签名是否有效
- DR 是否匹配
- Bundle ID 是否稳定
- Team ID 是否稳定
- Entitlements / Access Group 是否匹配
        ↓
校验通过
        ↓
静默返回 token
```

正常情况下，不应出现系统授权弹窗。

---

## 3. 推荐 Keychain item 设计

### 3.1 单 App 场景

| Keychain 字段 | 推荐值 |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `com.yourcompany.yourapp.auth` |
| `kSecAttrAccount` | 用户 ID / 邮箱 / workspace ID |
| `kSecValueData` | token data |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| `kSecAttrSynchronizable` | `false` |
| `kSecAttrAccessGroup` | 单 App 不显式设置 |

---

### 3.2 后台菜单栏 / Agent 场景

如果 App 需要用户登录后在后台访问 token，可考虑：

```swift
kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

但普通 GUI App 更建议：

```swift
kSecAttrAccessibleWhenUnlockedThisDeviceOnly
```

---

### 3.3 不建议设置的访问控制

如果目标是“静默无感读取”，不要给普通 token item 加：

```swift
kSecAccessControlUserPresence
kSecAccessControlBiometryAny
kSecAccessControlBiometryCurrentSet
```

这些会主动要求用户确认、Touch ID、密码或生物识别，不适合普通 API token 的无感读取。

---

## 4. Swift 实现模板

### 4.1 保存 / 更新 token

```swift
import Foundation
import Security

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
    case invalidData
}

final class TokenKeychainStore {
    private let service = "com.yourcompany.yourapp.auth"

    func saveToken(_ token: String, account: String) throws {
        let data = Data(token.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addQuery[kSecAttrSynchronizable as String] = false

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }

            return
        }

        throw KeychainError.unexpectedStatus(updateStatus)
    }
}
```

---

### 4.2 静默读取 token

```swift
extension TokenKeychainStore {
    func readToken(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: false
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return token
    }
}
```

---

### 4.3 删除 token

```swift
extension TokenKeychainStore {
    func deleteToken(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
```

---

## 5. 正规分发配置

### 5.1 Xcode 配置

| 配置项 | 建议 |
|---|---|
| Team | 固定 Apple Developer Team |
| Bundle Identifier | 固定，例如 `com.yourcompany.yourapp` |
| Debug Signing Certificate | `Apple Development` |
| Release Signing Certificate | `Developer ID Application` |
| Hardened Runtime | Release 建议开启 |
| App Sandbox | 按需开启 |
| Keychain Sharing | 单 App 不开；多 target 共享才开 |

---

### 5.2 外部分发链路

```text
Archive
        ↓
Developer ID Application 签名
        ↓
Hardened Runtime
        ↓
Notarization
        ↓
Staple
        ↓
用户安装
        ↓
App 首次写入 Keychain
        ↓
后续静默读取
```

---

### 5.3 验证签名

```bash
codesign -dv --verbose=4 /path/to/YourApp.app 2>&1
```

重点检查：

```text
Identifier=com.yourcompany.yourapp
TeamIdentifier=ABCD123456
Authority=Developer ID Application: ...
```

查看 Designated Requirement：

```bash
codesign -d -r- /path/to/YourApp.app 2>&1
```

理想输出类似：

```text
designated => identifier "com.yourcompany.yourapp"
and anchor apple generic
and certificate leaf[subject.OU] = "ABCD123456"
```

---

## 6. 无 Apple Developer 稳定签名时的解决方案

### 6.1 先给结论

如果没有 Developer ID / Apple Development 稳定签名，仍然可以实现：

```text
用户首次在 App 内填写 API Key
        ↓
App 自己创建 Keychain item
        ↓
后续同一 App 构建产物读取自己的 item
        ↓
通常不会反复弹窗
```

但该结论必须加限定：

| 条件 | 结论 |
|---|---|
| 同一个未修改的 App 构建产物反复打开 | 通常不会再次弹 |
| App 自己创建 item，自己读取 item | 官方机制支持 |
| 重新 build，二进制变化 | 不能保证不弹 |
| Bundle ID 变化 | 不能保证不弹 |
| ad-hoc 签名变化 | 不能保证不弹 |
| 用户手动在 Keychain Access 创建 item | 第一次读取可能弹 |
| App 被修改、替换、感染、更新 | Apple 明确说明可能需要重新授权 |

所以，准确表述应该是：

> 无稳定签名时，只读取自己创建的 item，可以降低弹窗概率；但只要 App 发生变化，macOS 可能认为它不是原来的 App，从而重新要求授权。该方案适合本地开发、小工具、内测，不适合正式分发。

---

## 7. 无稳定签名的推荐 fallback：本地自签名证书

Apple 文档说明，Keychain 这类系统更看重“有效签名和稳定性”，不一定要求证书链来自 Apple；自签名身份或自建 CA 在 Keychain 这类场景中可以工作。

因此，没有 Apple Developer 账号时，推荐：

```text
不要完全无签名
不要纯 ad-hoc 签名
而是使用本地自签名 Code Signing Certificate
```

---

### 7.1 创建本地自签名证书

在 macOS Keychain Access：

```text
Keychain Access
→ Certificate Assistant
→ Create a Certificate
```

建议：

| 项目 | 建议 |
|---|---|
| Name | `Local Code Signing - YourApp` |
| Identity Type | Self Signed Root |
| Certificate Type | Code Signing |
| Keychain | login |
| Trust | 本机信任即可 |

---

### 7.2 用自签名证书签 App

```bash
APP="/path/to/YourApp.app"
IDENTITY="Local Code Signing - YourApp"

codesign --force \
  --deep \
  --sign "$IDENTITY" \
  "$APP"
```

验证：

```bash
codesign -dv --verbose=4 "$APP" 2>&1
codesign -d -r- "$APP" 2>&1
```

这种方案的优点：

| 优点 | 说明 |
|---|---|
| 无需 Apple Developer 账号 | 本地即可使用 |
| DR 相对稳定 | 比 ad-hoc 更可靠 |
| Keychain 静默读取更稳定 | 更容易被识别为同一个 App |
| 适合个人工具 / 内测 | 成本最低 |

限制：

| 限制 | 说明 |
|---|---|
| 不适合正式对外分发 | Gatekeeper / 用户信任体验不好 |
| 只适合本机或受控机器 | 其他机器也需要信任证书 |
| 不等于 notarization | 不能替代 Developer ID 分发 |

---

## 8. 无稳定签名但只读自己 item 的实现策略

### 8.1 产品流程

```text
首次启动
        ↓
检查 Keychain 中是否已有 token
        ↓
没有 token
        ↓
展示 API Key 输入界面
        ↓
用户粘贴 API Key
        ↓
App 调用 SecItemAdd 创建 item
        ↓
后续启动 App 调用 SecItemCopyMatching
        ↓
读取自己的 item
```

关键原则：

| 原则 | 要求 |
|---|---|
| 不读取其他签名版本创建的 item | 避免触发授权与身份混乱 |
| 不扫描 Keychain | 只查固定 service/account |
| 不使用用户手动创建的 item | 由 App 内部创建 |
| 不设置 UserPresence | 避免主动弹窗 |
| 不使用 shared access group | 单 App 简化 |
| 不在启动时高频读取 | 启动读取一次，放内存 |

---

### 8.2 只读取自己的 item 的做法

使用固定 service + account：

```swift
private let service = "com.yourcompany.yourapp.auth"
private let account = "default_api_key"
```

查找时只查：

```swift
[
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account
]
```

不要做：

```text
- 遍历所有 Generic Password
- 尝试读取旧 Bundle ID 的 item
- 尝试读取其他 App / helper 创建的 item
- 使用 Keychain Access 中手动创建的 item
```

---

### 8.3 首次设置引导

推荐 UX：

```text
首次打开
        ↓
未检测到 API Key
        ↓
显示设置页：
“请输入 API Key。本应用会将其保存到 macOS Keychain，不会以明文文件保存。”
        ↓
用户点击保存
        ↓
SecItemAdd 成功
        ↓
立即读取校验
        ↓
进入主界面
```

错误处理：

| OSStatus | 处理 |
|---|---|
| `errSecSuccess` | 正常 |
| `errSecItemNotFound` | 引导用户设置 |
| `errSecAuthFailed` | 提示 Keychain 授权失败 |
| `errSecInteractionNotAllowed` | 提示当前系统状态不允许交互，稍后重试 |
| 其他 | 显示错误码，建议重置 token |

---

## 9. 两套方案的选择

| 场景 | 推荐方案 |
|---|---|
| 正式分发给用户 | Developer ID Application + Notarization |
| App Store | Apple Distribution / Mac App Store 流程 |
| 自己本机使用 | 本地自签名证书 |
| 内测给少数同事 | 自签名证书 + 明确安装说明，或 TestFlight / Developer ID |
| 快速开发验证 | Apple Development 或自签名，不建议长期 ad-hoc |
| CI 每次构建产物不同 | 必须稳定签名，否则 Keychain 授权可能变化 |

---

## 10. 最终建议

### 最稳版本

```text
Developer ID Application
+ 固定 Bundle Identifier
+ 固定 Team ID
+ 固定 Entitlements
+ App 自己 SecItemAdd
+ 后续 SecItemCopyMatching
+ 不设置 UserPresence
+ 不让用户手动创建 Keychain item
```

### 没有 Apple Developer 时的最低可接受版本

```text
本地自签名 Code Signing Certificate
+ 固定 Bundle Identifier
+ App 自己创建 item
+ 只读取固定 service/account 的 item
+ 不读旧签名/旧 Bundle ID 的 item
+ 首次启动引导用户填写 API Key
```

### 不推荐版本

```text
完全无签名
ad-hoc 签名长期使用
让用户去 Keychain Access 手动新建 token
每次 delete + add token
helper / CLI 直接读取主 App 的 token
频繁改变 Bundle ID / entitlements / signing identity
```

---

## 11. 官方依据

1. Apple Technical Note TN2206: macOS Code Signing In Depth  
   https://developer.apple.com/library/archive/technotes/tn2206/_index.html

2. Apple Code Signing Guide: Understanding the Code Signature  
   https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/AboutCS/AboutCS.html

3. Apple Support: If a Mac app you’ve already trusted asks for keychain access  
   https://support.apple.com/en-sg/guide/keychain-access/kyca1331/mac

4. Apple Developer Documentation: Sharing access to keychain items among a collection of apps  
   https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps

5. Apple Developer Documentation: SecItemCopyMatching  
   https://developer.apple.com/documentation/security/secitemcopymatching%28_%3A_%3A%29

---

## 12. 一句话版本

正式方案：

```text
稳定签名的 App 自己创建 Keychain item，后续由同一个签名身份的 App 静默读取。
```

无 Apple Developer 方案：

```text
至少使用本地自签名证书保持 DR 稳定；如果完全无稳定签名，只能保证同一未修改构建产物读取自己创建的 item 时通常不弹，不能保证重构建/更新后仍不弹。
```
