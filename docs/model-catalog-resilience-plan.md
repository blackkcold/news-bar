# AI 模型目录韧性修复（Provider Model Catalog Resilience）

状态：已落版，待执行
日期：2026-11-12
适用版本：v3.0.3 之后

## 1. 现象

菜单栏 AI 简报长期显示：

> 更新失败，仍显示上次内容：模型列表格式异常或分页不完整，请重新获取。

且「重新获取」永远返回同一错误。设置 → AI 的模型列表最终变为空，AI 摘要不可用。

## 2. 已证实的根因

### 2.1 一次类型变化打掉整份目录（P0）

`Sources/NewsBar/Models/ProviderModel.swift:150-164` 把 OpenCode 价格表的缓存写价声明为
`let write: Double?`。2026-11-11 起 OpenCode 网关对部分模型返回按 TTL 计价的对象：

```json
"cost": { "text": { "input": { "cache": { "read": 0.02, "write": { "30m": 0.25, "12h": 0.5 } } } } }
```

`decodeIfPresent` 遇到类型不符会抛错（不是返回 nil），而 `ProviderModel.swift:199` 用一次性
`try? JSONDecoder().decode(Envelope.self, …)` 解析整个响应。因此 **85 条里 1 条写价是对象，整份目录就返回
`.malformedResponse`**。

实测命中：

| 目录 | 条目 | 受影响条目 |
| --- | --- | --- |
| `https://opencode.ai/inference/go/v1/models` | 30 | `gpt-5.6-luna`、`gpt-6-luna` |
| `https://opencode.ai/inference/v1/models` | 85 | `gpt-5.6-luna`、`gpt-5.6-sol`、`gpt-6-astra`、`gpt-6-sol`、`gpt-6.1-sol`、`gpt-6-luna`、`gpt-5.6-terra` |

Swift 复现输出：

```
typeMismatch: expected Double. Path: data[1].cost.text.input.cache.write
```

### 2.2 失败后无法自愈（P0）

- `.malformedResponse` 不在 `ProviderModelError.invalidatesCache` 里，`catalog()` 会一直返回
  `.stale` + 错误，旧快照被反复复用。
- 快照超过 24h 后 `AppSettings.swift:1170-1175` 的 `isAIModelCatalogValidated` 恒为 false，
  `canUseCurrentAIModel` 恒为 false，摘要生成被拦截。
- `AITab.swift:616` 的手动输入出口只在 `currentAIModels.isEmpty && !aiModelManuallyEntered` 时出现；
  而本机当前状态是 `aiModelManuallyEntered = 1`、`aiModel = ""`，既没有模型也没有提示。

结果：目录坏了就等于 AI 功能坏了，且没有任何可用出口。

### 2.3 协议过滤形同虚设（P1）

`ProviderModel.swift:236-243` 只排除 `systemone`，而两个 OpenCode 目录当前都不含该字段。目录为每个模型
发布了 `api` 路由：

| 目录 | 可选模型 | 声明 `chat-completions` | 不支持 |
| --- | --- | --- | --- |
| OpenCode Zen | 73（85 − 12 免费） | 16 | 57（`messages` / `responses` / `generate-content`） |
| OpenCode Go | 30 | 19 | 11 |

App 对所有模型统一请求 `…/openai/v1/chat/completions`。一旦打开「显示全部模型」，picker 里会出现无法调用的
模型，选中后必然失败。

### 2.4 端点与回退的小偏差（P2）

- 401 之后不尝试第二跳是**既有且有意的策略**（`testAuthenticationFailureDoesNotFallBackToCachedModelOrOtherRoutes`
  明确断言：被拒的凭证不得向其他路由扩散）。执行阶段复核后撤销了「401 也回退」的改动。
- `ProviderModelService.swift:73` 用 `replacingOccurrences(of: "/anthropic", with: "")` 替换路径中所有出现位置，
  而不是仅剥离前导段。已修正。

### 2.5 端点核对结论（无需改动）

| Provider | 实际请求 | 结论 |
| --- | --- | --- |
| DeepSeek | `GET https://api.deepseek.com/models` | 正确 |
| MiniMax Token Plan / API | `GET …/anthropic/v1/models` → 回退 `…/v1/models` | 两条路由都存在 |
| OpenCode Go | `GET https://opencode.ai/inference/go/v1/models` | 正确，单页 |
| OpenCode Zen | `GET https://opencode.ai/inference/v1/models` | 正确，单页 |
| Google AI Studio | `GET …/v1beta/models` | 正确 |
| Ollama Cloud | `GET https://ollama.com/api/tags` | 可用（保留，因 `capabilities` 可过滤非对话模型） |

## 3. 目标

1. 任一 provider 改变任一字段形状，都不得让整份模型目录失效。
2. 目录失败后必须始终存在可用的手动出口，UI 必须说明「为什么不能用」。
3. Picker 只展示当前连接方式真正能调用的模型。
4. 不改变默认选择（DeepSeek 优先）与现有安全策略（24h 目录有效期、401 即停止使用缓存）。

非目标：

- 不为 `messages` / `responses` / `generate-content` 模型实现协议路由（改动面覆盖请求构建与流式解析，
  另行立项）。
- 不替换 Ollama 的发现端点。
- 不调整价格表生成脚本。

## 4. 变更清单

### 4.1 `Sources/NewsBar/Models/ProviderModel.swift`

**（a）价格字段容错**

新增 `PriceAmount`，同时接受数字与「按 TTL/上下文分档的对象」，对象取最大值作为上限：

```swift
private struct PriceAmount: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let number = try? single.decode(Double.self) {
            value = number
            return
        }
        guard let object = try? decoder.container(keyedBy: DynamicKey.self) else { value = nil; return }
        value = object.allKeys.compactMap { try? object.decode(Double.self, forKey: $0) }.max()
    }
}
```

`ModelCost.Text.Side.price`、`Cache.read`、`Cache.write` 改为 `PriceAmount?`；
`isFree` 判断改为 `price?.value == 0`。`DynamicKey` 从 `APIMap` 内提升到文件作用域复用。

**（b）Entry 全字段容错**

`Entry` 改为自定义 `init(from:)`，每个字段 `try?` 解码，容器本身不可读时全部置 nil。
这样单条异常记录只会被 `compactMap` 丢弃，不会让整份目录抛错。
`Envelope` 的 `has_more` / `last_id` / `nextPageToken` 同样容错（数组字段仍是硬要求）。

**（c）协议过滤**

```swift
let apiKeys = entry.api?.keys ?? []
let chatType = entry.type == nil || entry.type == "chat" || entry.type == "text"
// 目录公布的 api 路由是权威信息：没有 chat-completions 就无法用本客户端的
// OpenAI 形状请求调用。
let chatProtocol = apiKeys.isEmpty || apiKeys.contains("chat-completions")
isChatCompatible = chatType && chatProtocol && !apiKeys.contains("systemone")
```

### 4.2 `Sources/NewsBar/Services/ProviderModelService.swift`

**（a）401 回退：不改动**

复核发现既有测试 `testAuthenticationFailureDoesNotFallBackToCachedModelOrOtherRoutes` 明确要求
「凭证被拒后不得尝试其他路由」。该策略属于安全边界，保留原样；MiniMax 的两条路由当前都存在，
无需扩大凭证投放面。

**（b）只剥离前导 `/anthropic` 段**

```swift
if connection.responseFormat == .anthropic, path.hasPrefix("/anthropic") {
    parts.path = String(path.dropFirst("/anthropic".count)) + "/models"
    …
}
```

### 4.3 `Sources/NewsBar/Views/Settings/AITab.swift`

模型区错误提示改为「图标 + 文案」的告警行，并且只要存在 `modelCatalogError` 就提供手动输入出口
（不再要求模型列表为空）。这样目录彻底坏掉时，用户始终有一条可用路径。

### 4.4 测试 `Tests/NewsBarTests/ProviderModelTests.swift`

新增：

1. `testTTLKeyedCacheWritePricesDoNotBreakTheCatalog`
2. `testOneUnreadableEntryDoesNotDiscardTheWholeCatalog`
3. `testFreeModelKeepsFreeFlagWhenCacheWriteIsTTLKeyed`
4. `testOpenCodeCatalogHidesModelsWithoutChatCompletions`（Go 与 Zen）
5. `testAnthropicFallbackOnlyStripsTheLeadingSegment`

## 5. 验收标准

- `swift build` 通过。
- `swift test --filter ProviderModelTests` 全绿；随后 `swift test` 全量通过。
- 用真实 Go / Zen 目录验证：`catalog()` 返回 `.live`，Go 30 条、Zen 85 条原始条目可解析；
  picker 可选模型只保留 16（Zen，非免费）/ 19（Go）条 `chat-completions` 模型。
- 断开网络后仍能返回 `.stale` + 旧快照，不丢模型。
- 设置页出现错误时，「手动输入模型」按钮始终可见。

## 6. 风险与回滚

| 风险 | 处置 |
| --- | --- |
| 协议过滤误伤实际可调用的模型 | 过滤依据是 provider 自己发布的 `api` 路由；若后续确认网关宽松，只需放宽 `chatProtocol` 一行 |
| 容错解码掩盖 provider 的真实异常 | 单条丢弃仍保留其余模型；错误不再影响整份目录，但日志/文案不变 |
| 401 继续下一跳导致多一次请求 | 仅在存在第二跳时发生（目前只有 MiniMax Anthropic 路径） |

回滚：单文件回退 `ProviderModel.swift` / `ProviderModelService.swift` / `AITab.swift` 即可，无数据迁移。

## 7. 执行顺序

1. `ProviderModel.swift`（容错解码 + 协议过滤）→ 4 个解析测试
2. `ProviderModelService.swift`（只剥离前导 `/anthropic`）→ 1 个端点测试
3. `AITab.swift`（错误行 + 手动出口）
4. `swift build` + `swift test`
5. 用真实目录做一次只读核对
6. 用 `AISettingsRenderingTests` 渲染三种主题核对 UI

## 8. 执行结果（2026-11-12）

- `swift build`：通过，无新增警告。
- `swift build -c release`：通过（与 CI 一致）。
- `swift test --filter ProviderModelTests`：40 项全通过。
- `swift test`：1901 项，0 失败，5 跳过。
- `AISettingsRenderingTests`：三种主题 + 中英双语渲染通过，错误行与手动出口在 live / stale / empty 三态下均无溢出。
- 真实目录只读核对（用交付版 parser 直接解析生产响应）：

| 目录 | 字节 | 解析条数 | `chat-completions` | 分页 |
| --- | --- | --- | --- | --- |
| OpenCode Go | 35797 | 30 | 19 | 无（单页） |
| OpenCode Zen | 103285 | 85 | 28（过滤免费后 16） | 无（单页） |

修复前同一响应在 `data[8]`（Go）/ `data[48]`（Zen）抛 `typeMismatch`，整份目录不可用。

执行期改动：撤销「401 也回退」（与既有安全测试冲突）。新增 5 个测试全部通过。
