# Agent 后台测试

这套入口给 agent / CI 用：在不启动窗口、不退出、不写入正在运行的 NewsBar 的前提下，跑完逻辑、解析、缓存、控制器、store 只读核对和阅读器离屏渲染。

## 快速开始

```bash
bash scripts/agent-test.sh --tier headless   # 默认；不开窗口
bash scripts/agent-test.sh --tier render     # 离屏快照
bash scripts/agent-test.sh --tier launch     # 同步入口 / 主 actor 探针
bash scripts/agent-test.sh --tier all        # 全量 swift test + render + launch
bash scripts/agent-test.sh --tier all --json # 机器可读报告
```

日志与产物写入 `.build/agent-test/<timestamp>/`。退出码 `0` 表示每一步都通过。

## 分层

| 层 | 内容 | 是否开窗口 | 是否碰运行实例 |
|---|---|---|---|
| `headless` | `AgentHeadlessTests`、评论解析/缓存/控制器、Feed 过滤；`NewsBarAgent check / store-summary / doctor`；`newsbarctl recommend summary` 契约检查 | 否 | 否 |
| `render` | `FollowingReaderRenderingTests`、`WeiboMonitorRenderingTests` 的离屏快照；`render-reader` 三张 | 仅离屏，不 makeKey | 否 |
| `launch` | `--launch-probe`：进入 AppKit run loop，并断言主 actor 任务能执行 | 不显示窗口，`.prohibited` | 否 |
| `all` | 完整 `swift test` + headless + render + launch | 仅离屏 | 否 |

`NEWSBAR_TEST_HEADLESS=1` 会跳过唯一需要 key window 的 AX 树测试，避免抢焦点。`launch` 是 v3.4.0 主 actor 饿死事故的回归门禁：v3.4.0 的 async 入口会让探针只写出 `enteredRun`、缺少 `mainActorTask`，45 秒后超时失败。

## Agent CLI

v3.4.2 起 agent 命令由独立可执行文件 `NewsBarAgent` 提供；App 入口只保留同步 `runApp()`。`NewsBar --agent ...` 会以 exit 2 明确失败，不会启动 GUI。

```bash
.build/debug/NewsBarAgent check
.build/debug/NewsBarAgent parse-comments <file|->
.build/debug/NewsBarAgent store-summary [--root <dir>]
.build/debug/NewsBarAgent render-reader <fixture> [--out <png>] \
  [--width <pt>] [--height <pt>] [--theme modern|retroEditorial] [--language zh|en]
.build/debug/NewsBarAgent doctor
```

- `check`：6 条内置不变量（链接两侧空白、mention/topic 的 href、sinaurl 只解一层、http 降级、`data-href` 不误判、大写 `<A>`）。
- `parse-comments`：跑生产解析器，输出 `text` 与 `runs`，用于核对真实 payload。
- `store-summary`：**先复制**真实 store 到临时目录再读；原目录不会被 `load()` 的归档或重建写入。
- `render-reader`：离屏渲染 `FollowingReaderPane` 到 PNG；agent 进程显式激活 `TestIsolation`，使用 `.prohibited` 激活策略。
- `doctor`：分别报告真实 store 根（`storeRoot`）与隔离后的有效根（`effectiveRoot`）、agent 根目录、是否隔离、正在运行的实例数；只读，不启动第二个 App。

## 推荐诊断与 `newsbarctl recommend summary`

`newsbarctl` 是独立 CLI（`.build/debug/newsbarctl`），不属于 `NewsBarAgent`。推荐汇总只从**正在运行**的 App 读取：

```bash
.build/debug/newsbarctl recommend summary --window 7d --json
```

- 前提：App 内「隐私与数据 → 兴趣与推荐」已开启推荐诊断、本地学习可用，并由用户显式授权 15 分钟；授权前会展示固定日期范围、覆盖是否完整、计数（不足 20 条时只给日期范围），授权中可看到剩余时间并随时撤销。
- 窗口只有 `7d` / `30d`，且必须等于授权时选定的窗口；CLI 不能扩大范围。
- 退出码：`0` ok / insufficient_data，`2` 用法错误，`3` App 未运行，`4` 未授权或限流，`5` 存储不可用或超时。
- App 未运行时直接返回 `app_unavailable`：不唤醒 App、不写命令队列、不排队。响应只走内存 socket，不落 `AgentPaths`、outbox 或日志；App 退出后授权失效。
- 已交付给 Agent 的汇总无法收回；撤销只阻止后续读取。

`bash scripts/agent-test.sh --tier headless` 会跑 `scripts/check-recommend-cli.sh`，核对退出码、字段白名单、无队列写入与不拉起 App。

## 隔离模型

- v3.4.1 的 launch probe 不构造 `AppSettings`、不碰任何 store；它只验证 AppKit run loop 与主 actor。
- 测试：`TestIsolation` 在 XCTest 下自动启用，store、缓存、ImageCache、偏好都走临时目录。
- 渲染：窗口不 `makeKeyAndOrderFront`，AX 树测试在 headless 模式下跳过。
- 脚本只报告正在运行的实例数，从不退出或重启它。
- v3.4.2 的 `NewsBarAgent` 会在入口显式激活 `TestIsolation`，不依赖外部 env。

## 覆盖边界（明确不做自动化）

以下项目不在后台自动化的范围内，发版也不把它们当作手工闸门；需要时由阅读者自行选择是否验证：

- 系统浏览器真实打开外链（`open` 会切前台）。
- 真实微博网络与登录态下的评论刷新（自动化只走 fixture / 缓存副本）。
- VoiceOver 激活与真实窗口的键位手感。

自动证据覆盖：解析结果、runs 与空白、缓存兼容、controller 的 pending/分页、Feed 过滤、三套主题与两种宽度的离屏渲染、store 只读一致性。

## Fixture

`Tests/NewsBarHeadlessTests/Fixtures/reader.json` 是 `render-reader` 的样例：

```json
{
  "width": 558,
  "height": 900,
  "theme": "modern",
  "language": "zh",
  "post": { "mid": "...", "uid": "...", "screenName": "...", "text": "...", "createdAt": "2026-11-23T07:00:00Z" },
  "user": { "uid": "...", "screenName": "...", "priority": "p0" },
  "comments": [
    { "id": "...", "mid": "...", "uid": "...", "screenName": "...", "text": "...", "createdAt": "2026-11-23T08:45:00Z",
      "runs": [{ "kind": "link", "text": "链接", "url": "https://example.com/a" }] }
  ]
}
```

日期用 ISO-8601；`runs` 可省略，省略时按纯文本渲染。图片 URL 会走真实 `ImageCache`，后台检查不建议放远程图片。

## 新增检查

- 解析不变量：加到 `Sources/NewsBar/Agent/AgentChecks.swift`，`check` 命令会自动包含。
- 新的 headless 测试：放进 `Tests/NewsBarHeadlessTests/`，不要创建 `NSWindow`。
- 新的渲染命令参数：扩展 `AgentReaderRender` 的 option 解析，并在脚本的 `render` 分支补一条 `run_step`。

## 已知抖动

全量层包含既有的 `RecommendationTests.testFiveHundredCandidateRankingTiming`（debug 构建下 500 候选排序的 P95 上限，v3.4.1 从 200ms 调整为 600ms：稳态约 150ms，负载抖动曾到 430ms）。它仍能拦住 4 倍的真实回归；`all` 档若只因这一条失败，先确认 full-tests 日志中没有其他失败，再单独复跑：

```bash
swift test --filter RecommendationTests/testFiveHundredCandidateRankingTiming
```

发版证据以干净全量结果为准。
