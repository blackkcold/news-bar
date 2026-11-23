# Agent 后台测试

这套入口给 agent / CI 用：在不启动窗口、不退出、不写入正在运行的 NewsBar 的前提下，跑完逻辑、解析、缓存、控制器、store 只读核对和阅读器离屏渲染。

## 快速开始

```bash
bash scripts/agent-test.sh --tier headless   # 默认；不开窗口
bash scripts/agent-test.sh --tier render     # 离屏快照 + render-reader
bash scripts/agent-test.sh --tier all        # 全量 swift test + 所有 CLI 检查
bash scripts/agent-test.sh --tier all --json # 机器可读报告
```

日志与产物写入 `.build/agent-test/<timestamp>/`。退出码 `0` 表示每一步都通过。

## 分层

| 层 | 内容 | 是否开窗口 | 是否碰运行实例 |
|---|---|---|---|
| `headless` | `AgentHeadlessTests`、评论解析/缓存/控制器、Feed 过滤、`--agent check`、`store-summary`、`doctor` | 否 | 否 |
| `render` | `FollowingReaderRenderingTests`、`WeiboMonitorRenderingTests`、`render-reader` 的 modern / retro / 960 三张图 | 仅离屏，不 makeKey | 否 |
| `all` | 完整 `swift test`（含渲染） + headless 与 render 的 CLI 步骤 | 仅离屏 | 否 |

`NEWSBAR_TEST_HEADLESS=1` 会跳过唯一需要 key window 的 AX 树测试，避免抢焦点。

## CLI

```bash
.build/debug/NewsBar --agent check
.build/debug/NewsBar --agent parse-comments <file|->
.build/debug/NewsBar --agent store-summary [--root <dir>]
.build/debug/NewsBar --agent render-reader <fixture> [--out <png>] \
  [--width <pt>] [--height <pt>] [--theme modern|retroEditorial] [--language zh|en]
.build/debug/NewsBar --agent doctor
```

- `check`：6 条内置不变量（链接两侧空白、mention/topic 的 href、sinaurl 只解一层、http 降级、`data-href` 不误判、大写 `<A>`）。
- `parse-comments`：跑生产解析器，输出 `text` 与 `runs`，用于核对真实 payload。
- `store-summary`：**先复制** store 到临时目录再读，输出 users / posts / unread / comments / latestMid / issues；原目录不会被 `load()` 的归档或重建写入。
- `render-reader`：离屏渲染 `FollowingReaderPane` 到 PNG，进程使用 `.prohibited` 激活策略，不显示窗口。
- `doctor`：输出 bundle id、版本、agent 根目录、store 根目录、是否隔离、正在运行的实例数。它只读，不会启动第二个 App。

## 隔离模型

- CLI：`NEWSBAR_AGENT_ROOT` 指向临时目录；`NEWSBAR_AGENT_ISOLATED=1` 让 `TestIsolation.isActive` 为真，`AppSettings` 的读写落在按进程隔离的 UserDefaults suite，不碰真实偏好。
- 测试：`TestIsolation` 在 XCTest 下自动启用，store、缓存、ImageCache、偏好都走临时目录。
- 渲染：窗口不 `makeKeyAndOrderFront`，AX 树测试在 headless 模式下跳过。
- 脚本只报告正在运行的实例数，从不退出或重启它。

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

全量层包含既有的 `RecommendationTests.testFiveHundredCandidateRankingTiming`（debug 构建下 500 候选排序的 P95 上限 200ms）。机器负载高时偶发超过阈值；它与关注阅读器无关，干净环境复跑通常通过。`all` 档若只因这一条失败，先确认 full-tests 日志中没有其他失败，再单独复跑：

```bash
swift test --filter RecommendationTests/testFiveHundredCandidateRankingTiming
```

发版证据以干净全量结果为准（本次全量为 1984 tests / 6 skipped / 0 failures）。
