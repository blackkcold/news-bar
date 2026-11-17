# Stage 1 Report — Foundation (assembly / clients / cache)

**Branch:** `feat/unified-research-workspace`
**Worktree:** `/Users/11169285/.local/share/opencode/worktree/2c2cb18db9ec202ac5ec607efad1feaa54f77c57/unified-research-workspace`
**Plan:** `docs/superpowers/plans/unified-research/stage-1-foundation.md`
**Date:** 2026-11-16
**Status:** 代码完成，`swift build` 通过。**未执行测试、未启动 app、未调用业务 API、未联网。**

## 1. 裁决落版（先于代码）

四条裁决已写回 `stage-1-foundation.md` 的 `## Rulings` 与 `progress.md` 的
`## Stage 1 rulings`；父计划删除了“人工启动复核”的说法，并把“每个任务组编译”
改为“每阶段一次构建”。

| 裁决 | 落地方式 |
|---|---|
| R1 共享缓存不得牺牲时效 | 新增 `maxAge` 向下钳制；AI 搜索 600s、研究 12h、页面概览仍 `useCache: false`。同一 key / 文件 / epoch，无第二层缓存。 |
| R2 统一清理入口 | 设置页清缓存/清全部、清空历史、维护裁剪全部走 `ResearchCacheCoordinator`；一次 clear 只 bump 一次 epoch。 |
| R3 每阶段一次构建 | 全部改动落地后构建；不逐任务编译，不启动 app。 |
| R4 客户端工厂覆盖现有构造点 | 研究/triage、AI 搜索、评估、划词、页面概览全部改走 `AIChatClientFactory`；每入口 timeout / thinking / DeepSeek / 预检语义保持不变。 |

补充执行裁决 **R5**：单一共享 router 下，403 仍是“本轮不再重试”，不会变永久屏蔽；
`authRejected` 状态不再跨 key/provider 配置复用。

## 2. 新增接口（实际签名）

```swift
final class ResearchServiceAssembly: Sendable {
    static let shared: ResearchServiceAssembly
    let cache: ResearchCacheStore
    let ledger: ResearchLedger
    let aiQuota: AIQuotaStore
    let searchQuota: SearchQuotaStore
    let searchRouter: SearchRouter
    let basePageReader: PageReader
    init(cache: ResearchCacheStore = .shared, ledger: ResearchLedger = .shared,
         aiQuota: AIQuotaStore = .shared, searchQuota: SearchQuotaStore = .shared)
    func pageReader(isScrapeEnabled: Bool) -> PageReader
}

enum AIChatClientFactory {
    static func unmetered(connection:apiKey:model:disableDeepSeekThinking:thinking:timeout:) -> HTTPAIChatClient
    static func metered(origin:policy:price:connection:apiKey:model:
                        disableDeepSeekThinking:thinking:timeout:quota:) -> HTTPAIChatClient
}

struct ResearchCacheClearReceipt: Sendable, Equatable { let epoch: Int; let removedBytes: Int64; let isComplete: Bool }

enum ResearchCacheCoordinator {
    static func clearAll(cache: ResearchCacheStore = .shared) async -> ResearchCacheClearReceipt
    @discardableResult
    static func enforceLimits(maxBytes:protecting:protectingSince:now:cache:) async -> ResearchCacheStats
}
```

与冻结接口相比只做了**兼容性扩展**（默认参数）：`metered` 增加
`disableDeepSeekThinking`；`enforceLimits` 增加 `protectingSince:/now:/cache:`；
`clearAll` 增加 `cache:`。原有调用形式不受影响。

缓存层新增参数：

```swift
ResearchCacheStore.load(kind:key:now:maxAge: TimeInterval? = nil) -> Data?
SearchRouter.search(..., useCache: Bool = true, maxAge: TimeInterval? = nil, ticket: ...)
```

`maxAge` 只能缩短该消费者的有效期，且**不会删除**仍在 store TTL 内的文件——
否则 AI 搜索 10 分钟后会把研究还能用的 12h 快照删掉（实现中专门修正过一次）。

## 3. 文件清单

新增（3）：

- `Sources/NewsBar/Services/Research/ResearchServiceAssembly.swift`
- `Sources/NewsBar/Services/AI/AIChatClientFactory.swift`
- `Sources/NewsBar/Services/Research/ResearchCacheCoordinator.swift`

修改（12）：

- `Sources/NewsBar/Services/AISearch/AISearchServiceFactory.swift`
- `Sources/NewsBar/Services/AISearch/SearchHitCache.swift`
- `Sources/NewsBar/Services/NewsOrchestrator.swift`
- `Sources/NewsBar/Services/PageSummary/PageSummaryEvidenceProvider.swift`
- `Sources/NewsBar/Services/PageSummary/PageSummaryService.swift`
- `Sources/NewsBar/Services/Research/ResearchCacheStore.swift`
- `Sources/NewsBar/Services/Research/ResearchHistoryClearer.swift`
- `Sources/NewsBar/Services/Research/ResearchMaintenance.swift`
- `Sources/NewsBar/Services/Search/ManualSearchGateway.swift`
- `Sources/NewsBar/Services/Search/SearchRouter.swift`
- `Sources/NewsBar/Views/Dashboard/SelectionExplainModel.swift`
- `Sources/NewsBar/Views/Settings/ResearchDataSection.swift`

文档：`docs/superpowers/plans/2026-11-16-unified-research-workspace.md`、
`unified-research/stage-1-foundation.md`、`unified-research/progress.md`。

## 4. 装配与接线

### 4.1 唯一生产图

| 组件 | 生产来源 | 原来 |
|---|---|---|
| `SearchRouter` | `ResearchServiceAssembly.shared.searchRouter` | 4 处各自 new：AI 搜索、页面概览、NewsOrchestrator、ManualSearchGateway 默认参数 |
| `PageReader` | `assembly.pageReader(isScrapeEnabled:)` | 3 处各自 new，且各自 new `ResearchCacheStore()` |
| `ResearchCacheStore` | `assembly.cache`（=`.shared`） | 每个 router/reader 一份 |
| 搜索配额 | `assembly.searchQuota`（=`.shared`） | AI 搜索/页面概览显式传、研究显式传、手动搜索没有 |

`grep` 结果：生产代码中 `SearchRouter(` / `PageReader(` / `HTTPAIChatClient(` 只出现在
`ResearchServiceAssembly.swift` 与 `AIChatClientFactory.swift`。

### 4.2 客户端装配表

| 入口 | 工厂方法 | origin | timeout | thinking | DeepSeek 开关 | 计量 |
|---|---|---|---|---|---|---|
| 研究 Pipeline | `unmetered` | —（pipeline 自管 `.research`） | 60（默认） | nil | 保留 | **nil** |
| 研究 triage | `metered` | `.triage` | 12 | nil | 保留 | `.tracked` |
| AI 搜索回答 | `metered` | `.aiSearch` | 45 | `settings.aiSearchThinking` | 默认 | `.tracked` |
| AI 搜索评估 | `metered` | `.aiSearch` | 45 | nil | 默认 | `.tracked` |
| 页面概览评估 | `metered` | `.pageSummary` | 45 | nil | 默认 | `.tracked` |
| 页面概览摘要 | `metered` | `.pageSummary` | 45 | `thinking` 参数 | 默认 | `.tracked` |
| 划词分类 | `metered` | `.selection` | 20 | nil | 保留 | `.tracked` |
| 划词解释 | `metered` | `.selection` | 60 | nil | 保留 | `.tracked` |

AI 搜索原来手写的 `AIChatQuota` 与 `.tracked` 逐行等价（同样的 system/user 拼接、
同样的 `reserveMicros`、同样的 `reserveTracked`/settle 分支），因此替换不改变扣费；
预检 `preflight` 与评估预留 `assessmentReservation` 闭包**未改动**。

### 4.3 缓存语义

| 消费者 | 读缓存 | 有效新鲜度 | 写缓存 |
|---|---|---|---|
| 研究 | `useCache: true` | 12h（`maxAge == nil`） | 是，带 epoch |
| AI 搜索 | `useCache: true` | `min(12h, 600s)` | 是，带 epoch |
| 页面概览补充资料 | `useCache: false` | 总是重新检索（原策略） | 是，带 epoch |
| 手动搜索 | `useCache: true` | 12h（原策略） | 是，带 epoch |

key 由 `SearchRouter.cacheKey` 统一生成：规范化 query + recency + language +
maxResults + `providers:`<可分发 provider 排序集合>。AI 搜索删除了手写 key 与
`SearchHitCache` 读写；`SearchHitCache` 只保留内存 actor 与 `clearAll()`，由
coordinator 防御性清空（不再有第二层正在写入的缓存）。

epoch：`ResearchCacheStore.writeGeneration` 是唯一 epoch 来源；`clearAll` 自增一次，
coordinator 不再二次自增。`PageReader` 与 `SearchRouter` 都在进入时捕获 epoch，
清理后才落盘的写入会被丢弃。

### 4.4 清理入口

| 入口 | 现路径 |
|---|---|
| 设置 → 研究数据 → 清空缓存 | `ResearchCacheCoordinator.clearAll()` |
| 设置 → 研究数据 → 清空全部 | `cacheClearAction?()` + `ResearchCacheCoordinator.clearAll()` |
| 清空研究历史（含启动恢复） | `ResearchHistoryClearer` → `clearAll(cache:)`，用 `receipt.isComplete` 判定 |
| 周期维护 / 修改上限 | `ResearchCacheCoordinator.enforceLimits(...)`（保留 1 小时保护窗口） |

清理后不再无条件显示“已清空”：receipt 不完整时显示失败提示。

### 4.5 ticket 与配额

- `SearchAttemptTicket` 仍在 `SearchRouter` 内、`provider.search` 之前消费；缓存命中、
  跳过 provider、限流/冷却都不消耗 ticket，消费点未移动。
- `ManualSearchGateway.search` 每次调用只创建 `SearchAttemptTicket(limit: 6)`，
  使用共享 router（=共享 quota/ledger），不再自带 router/quota。
- `QuickSearchContent` 仍以 `@State` 持有唯一 `ManualSearchGateway`；view body 不构造 router。
- `ResearchPipeline` 拿到 `quota == nil`：`.research` 只由 pipeline
  `reserve/settle` 一次；其余入口仍是 `.tracked`，无双扣漏扣。

### 4.6 安全边界

`PublicURLPolicy`、`SSRF` 检查、`PrivateHTTP`、`ReportValidator`、`EvidenceIdentity`
均未改动；私密/被阻断页面仍不联网、不写缓存（改动只在装配与缓存参数层）。
未触碰真实用户缓存目录与凭证（构建只写 `.build/`）。

## 5. 实际命令与结果

```
$ swift build            # 首次（全部改动后）
Build complete! (40.07s)
EXIT=0

$ swift build            # 修正 maxAge 误删共享快照后的最终构建（增量）
Build complete! (7.27s)
EXIT=0
```

日志：`.build/unified-research-stage1-build.log`（约 958 条 warning，全部为既有
Swift 6 模式/Actor 隔离警告；新增 3 个文件 0 warning、全日志 0 error）。

偏差说明：做了两次 `swift build`。第一次已通过；读 diff 时发现 `maxAge` 命中失败会
删除仍在 12h TTL 内的快照（会实际缩短研究缓存寿命），修正后必须再构建一次验证。
除此之外没有逐任务编译。

## 6. 未执行

- 未运行 `swift test` / 任何测试二进制 / baseline / 专项评测。
- 未启动 app，未调用任何业务 API 或网络接口。
- 未 commit、未 push、未发布、未安装依赖、未新增依赖。
- 因此**没有任何“测试通过”的结论**；唯一验证是编译。

## 7. 风险与后需关注

1. **共享 router 的冷却会跨入口生效**（设计意图）：AI 搜索触发 429 后，研究会在冷却
   窗口内跳过该 provider。这是“单图”的必然结果，但用户可能感知为研究变慢；若需按入口
   隔离冷却，应在 stage 4 之前讨论，不要私自拆回多 router。
2. **手动搜索/研究仍接受 12h 旧结果**（原有行为，未改）。若 UX 要求手动搜索更新鲜，
   给 `ManualSearchGateway` 传一个较短的 `maxAge` 即可，属后续决策。
3. **`SearchHitCache` 现在是“有清理但无人写入”的层**：保留是为了不破坏现有测试目标与
   旧调用方；stage 2 起若无新调用方，可整体删除并同步删测试。
4. **AI 搜索与研究会互相覆盖同一 key 的快照**：数据形状一致、后写者更新，可接受；
   但如果未来某个消费者改变 `CachedSearchResult` 结构，需要同时升级解码兼容。
5. **`basePageReader` 目前无人使用**（冻结接口的一部分），stage 2/3 若仍不用应删掉，
   避免出现“看起来是生产入口”的死字段。
6. `ResearchDataSection` 仍有 `ResearchCacheStore.shared.setPagesTTL/totalBytes` 直连
   `.shared`（与 `assembly.cache` 同一实例，非清理路径），未改为注入；若后续要支持
   测试注入，需统一。

## 8. 人工复核要点（读 diff 即可）

- `grep -R "SearchRouter(\|PageReader(\|HTTPAIChatClient(" Sources/NewsBar` → 只在
  assembly 与 factory。
- `grep -R "clearAll(" Sources/NewsBar` → 研究清理只剩 coordinator。
- `grep -n "maxAge" SearchRouter/ResearchCacheStore/AISearchServiceFactory` → 600s 与 nil 两条。
- `grep -n "quota: nil" AIChatClientFactory` → 仅 `unmetered`。
- `NewsOrchestrator.executeResearch` 里 pipeline 的 `ai:` 是 `unmetered`。
