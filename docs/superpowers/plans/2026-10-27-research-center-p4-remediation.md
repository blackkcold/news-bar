# Research Center P4 Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 关闭研究中心的 4 个 P0、25 个 P1 与关键 P2，补齐渲染/性能/本地化门禁，并以 2.8.0 发版。

**Architecture:** 先建立干净基线并合入 origin/main（v2.7.3），再按「安全 → 数据完整性 → 管线正确性 → UI/设置/通知 → 文档发版」五层推进。每层先写失败测试，再最小修复，层末跑全量 `swift test`。

**Tech Stack:** Swift 6 / SwiftUI / AppKit，Xcode 工程，`swift test`，Keychain，URLSession（ephemeral + 流式读取）。

**Spec:** `docs/superpowers/specs/2026-10-27-research-center-design.md`

## Global Constraints

- 平台 macOS arm64；不引入第三方依赖。
- 所有密钥只进 Keychain；配置文件与日志不得出现明文 Key。
- 新建文件权限 0600（创建时即生效，不做事后 chmod）。
- 中文 / 英文文案必须成对；key 集合与格式符一致。
- 版本号唯一出口 `version.txt`，本次目标 `2.8.0`。
- `release/2.7.0` 为脏工作树重建的错误产物，禁止发布；已隔离到 `release/_invalid/2026-10-27-dirty/`。
- 每个提交前 `swift test` 必须 0 失败；不允许 `as any` / `@ts-ignore` 类抑制。

## Review Focus

- 搜索结果 URL 指向回环/私网 IPv6 时，直抓必须拒绝且不发起连接。
- 分块响应超过上限时，必须在读取过程中中止，而不是读完再判断。
- 研究进行中删除记录或清空历史后，任何迟到回调不得把记录写回。
- 引文逐字校验失败时，结论不得仍为 confirmed / strength 4。
- 关闭某个 provider 后，该 provider 不得收到任何请求（含页面抓取）。

## Decisions

| # | 决策 |
|---|---|
| D1 | `researchAutoEnabled` 为唯一总开关；`burstPushEnabled` 只决定通知；关键词受总开关约束。 |
| D2 | 已有 `.ready` 记录再点「联网核查」只打开；重跑走详情页按钮 + 确认。 |
| D3 | Firecrawl 关闭 = 零请求；启用无 Key 也不发 keyless 请求，回退本地直抓；新增个人 API Key 输入。 |
| D4 | 通知正文为一句话摘要（≤80 字符、脱敏），默认开启，可关闭。 |
| D5 | 允许 provider 全关，降级 AI-only 并标注「未联网」。 |
| D6 | 版本 `2.8.0`（合入 main 之后）。 |
| D7 | 先 checkpoint + merge origin/main，再修。 |

---

## 批次 0 — 冻结与基线（0.5d）

- [x] T0.1 隔离 `release/2.7.0` 与 `latest` 到 `release/_invalid/2026-10-27-dirty/`。
- [ ] T0.2 提交当前绿色状态为 checkpoint。
- [ ] T0.3 `git merge origin/main`（v2.7.1–v2.7.3），解冲突，`swift test` 全绿。
- [ ] T0.4 记录测试数、耗时、已知 flaky。

**Gate 0:** 工作树干净、main 已合入、测试全绿。

## 批次 1 — 安全门（1.5d）

- [ ] T1.1 新建 `Services/Search/IPAddress.swift`；重写 `PublicURLPolicy`：`inet_pton` 16 字节解析，仅接受 `2000::/3`，拒绝 `::/128`、`::1/128`、`::ffff:0:0/96`、`0::/8`、`2001:db8::/32`、`2001::/32`、`2002::/16`、`64:ff9b::/96`、`fc00::/7`、`fe80::/10`、`fec0::/10`、`ff00::/8`；拒绝前导零；仅 443。与 `ReaderNavigationPolicy` 统一。
- [ ] T1.2 新建 `Services/HTTP/PrivateHTTP.swift`：ephemeral、逐跳重定向回调、`bytes(for:)` 流式上限、Content-Type 白名单、超时。替换 `DirectHTMLReader`、`WebScrapeService`、`SearchProvider`、`AIChatClient`。
- [ ] T1.3 `DirectHTMLReader` 连接后断言 `transactionMetrics.remoteAddress` 为公网。
- [ ] T1.4 RSS 新增/抓取/重定向/图标四路径统一校验。
- [ ] T1.5 `FirecrawlClient` 单一出口；disabled 或无 Key 时 0 请求；consent 只列实际接收方。
- [ ] T1.6 通知正文脱敏、缓存 Entry 只存哈希、`writePrivate` 创建即 0600、ledger `chmod` 改 `try?` + version。

**Gate 1:** 安全测试 ≥20 条全绿；`rg "session.data\(for:" Sources` 仅剩允许点。

## 批次 2 — 数据完整性（2d）

- [ ] T2.1 bootstrap 按 `record.status.isActive` 清扫；区分目录不存在/读取失败；`interruptedIDs` 上送 UI。
- [ ] T2.2 `mutate(id:)` + 墓碑 + 删除先 cancel + 进度回调 generation 检查 + `touch` 状态守卫。
- [ ] T2.3 `saveProgress` 只写 `run` 子文档；索引 ≥10s 节流或字段变更才写；终态失败进 pending 重试。
- [ ] T2.4 索引 version + `updatedAt` + mtime 比对；去掉 1000 条截断；淘汰比较器确定性；`.corrupt` 不计入上限。
- [ ] T2.5 `schemaVersion` + 全字段 `decodeIfPresent`；`meta.version` 校验；删除协议 no-op 默认实现。
- [ ] T2.6 迁移去重扫全量 records；空标题回退摘要；导入时间保真。
- [ ] T2.7 清历史：cancelAll + deleteAll + artifacts + search cache，**保留 `legacyImportVersion = 1`**；停 `burstResearchCache` 回灌；artifacts 30 天/500 条兜底。
- [ ] T2.8 管线登记 `fileKey`；maintenance 合并活跃集合；preview/enforce 同一算法含 `excluding`。
- [ ] T2.9 协调器 `await` 前占位；Job UUID token；完成比对 token；取消只标记。
- [ ] T2.10 provisioner 按 `topicKey` 去重。

**Gate 2:** 1000 条、陈旧索引、删除后并发写、部分删除失败、同 recordID 并发、清历史迟到 tick、孤儿文件回收全绿。

## 批次 3 — 管线正确性（2d）

- [ ] T3.1 搜索失败也计 attempts/failovers 并写 ledger；额度每任务只算一次；深档最坏 12 次。
- [ ] T3.2 验证器按 `claim.evidenceIDs` 过滤；`quoteVerified` 参与 verdict/strength；snippet 不算逐字核验；conflicts/missing 回写；strength 按规格。
- [ ] T3.3 `inlineEvidence` 入候选池并走同一校验。
- [ ] T3.4 解析失败/空候选/零命中/综合预算耗尽 → `.partial` 且保留证据；仅完全无内容 → `.failed`；`isPartial` 含空证据。
- [ ] T3.5 取消语义全程保留；每 provider 前检查 `Task.isCancelled`；`PageReader` 不吞取消。
- [ ] T3.6 `superseded` → `.cancelled`，保留已完成报告。
- [ ] T3.7 standard 6 / fast 4，重试与修复独立预留。
- [ ] T3.8 `researchAutoEnabled` 唯一总开关；关键词受约束；冷却改 `lastAttemptAt`；删除 `forceSearch`/`webSearchEnabled`/`makeSearchConfig`/`regenerateBurstResearch`。
- [ ] T3.9 401/冷却 UI；换 Key `resetKeyState`；`SearchRouter` 注入 `.shared`。

**Gate 3:** 交叉测试全绿；`rg "forceSearch|webSearchEnabled|makeSearchConfig" Sources` = 0。

## 批次 4 — UI / 设置 / 通知（1.5d）

- [ ] T4.1 删 `ReminderTab` 旧联网段；footer 改写为中英新语义。
- [ ] T4.2 默认开启一次性说明；设置页显示今日用量与剩余额度。
- [ ] T4.3 Firecrawl 个人 Key：状态 chip、SecureField、保存/测试/移除、额度链接；`scrapeCalls` 账本；每任务 8 页上限；首次付费确认。
- [ ] T4.4 通知一句话摘要；标题「研究完成」；payload 仅 recordID；动作「打开报告」；语言切换重注册；记录已删兜底。
- [ ] T4.5 ⌘F/⌘⌫/⌘1–5、上下键 + 回车、6 种空态、错误 banner、最新未读、窗口记忆、Dashboard 右键。
- [ ] T4.6 详情页 createdAt、六段固定、cancelled 独立黄条、来源并入 05。
- [ ] T4.7 VoiceOver + reduceMotion；相对时间与标点按语言。
- [ ] T4.8 补 `rss.validationProgress`；删死 key；parity 测试。
- [ ] T4.9 设置测试：白名单、默认值、回滚、Key 迁移、全关。
- [ ] T4.10 渲染矩阵 32 张 + 固定 UserDefaults suite。

**Gate 4:** 32 PNG 落盘；zh/en key 集合相等；手动双主题双语言复核。

## 批次 5 — 性能 / 文档 / 发版（1d）

- [ ] T5.1 1000 条索引 <150ms；单次进度写 P95 <5ms；启动不建中心；进度 tick 不触发全盘扫描。
- [ ] T5.2 `docs/research-center.md` + `.zh-CN.md`；README 五语；spec 状态；RELEASE_NOTES；`.release.json`。
- [ ] T5.3 三家真实 smoke + 个人 Key + 缺 Key 行为，记录入文档。
- [ ] T5.4 `version.txt` → 2.8.0；build / codesign / DMG / sha256 校验。
- [ ] T5.5 `chore(release): v2.8.0` + tag。

**Gate 5:** 五条命令全过；四处版本一致。

---

## 提交序列

1. `feat(research): add research center and online verification pipeline`
2. `merge: origin/main (v2.7.3) into feature/research-center`
3. `fix(security): harden URL validation and response limits`
4. `fix(research): prevent data loss and duplicate scheduling`
5. `fix(research): correct evidence verification and search budget`
6. `fix(research): align automation switches and notifications`
7. `test(research): add rendering matrix, localization and performance gates`
8. `docs(research): document research center for v2.8.0`
9. `chore(release): v2.8.0`

## Exit Criteria

1. P0/P1 归零。
2. `swift test` 0 失败，用例数 +约 70。
3. 32 张渲染图 + 3 项性能门槛 + 本地化 parity 全绿。
4. 三家 smoke 与个人 Key 路径有记录。
5. 文档、README、RELEASE_NOTES、spec 全部更新。
6. tag / `version.txt` / `Info.plist` / DMG 名四处一致，签名与 sha256 通过。
7. 2.7.1–2.7.3 无回归。
