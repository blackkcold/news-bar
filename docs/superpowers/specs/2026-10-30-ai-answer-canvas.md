# AI 答案画布：P0 实施规格

本规格固化 2026-10-30 复核后确认的范围。执行期间未提交、未发版、未发起任何真实付费请求；所有模型输出均为测试桩。

## 目标与范围

- 一个 `AnswerDocument`，两个入口：阅读器划词「AI 解释」与 ⌘K「AI 搜索」共用同一内容画布。
- P0 只做：结构化答案、真实来源、离线标注、复制、取消；不做流式、不做自动联网、不做置信度。
- 搜索与解释的差异只在来源：搜索有本次真实读取的页面，解释永远离线、永远零来源。

## 输出协议

首行是短 JSON meta，之后是纯文本小节：

```
@@ {"kind":"event","oneLine":"一句话结论"}
## 时间线
3 月 4 日发布。[1]
- 首批备货 20 万台[2]
- 定价：与上一代持平
> 引用原话
```

- `kind` ∈ term / event / number / comparison / howto；非法值回退到调用方给的 fallback。
- 小节标题由模型自拟，prompt 只给参考骨架，不强制。
- 解析器必须容忍：缺 meta、坏 meta、整段代码围栏、正文中的重复 meta、无 `##`、空小节。
- 上限：8 个区块、单块 1 400 字、全篇 5 000 字；超限截断而不是丢弃整篇。
- 不使用 NDJSON：长中文正文进 JSON 字符串时，一个未转义换行就会毁掉整块，且行未闭合前无法渲染。

## 不变量

1. `sources` 只包含本次真实读取的页面；模型只能引用编号，不能新增来源。
2. 编号越界（`[9]` 而只读了 3 页）按普通文本渲染，不生成可点击引用，也不从正文里抹掉。
3. 有来源但全篇零有效引用 → 整篇降级为「未能获得可引用的来源」，不展示无依据的正文。
4. 离线答案禁止 `[n]`；UI 固定显示「未联网 · 基于模型知识」，不使用任何暗示已核实的措辞。
5. 不展示模型自报置信度。只展示可计算的证据：读取来源数、被引用来源数、是否联网。
6. 来源列表只有一档：真正读过的页面。检索到但未读取的结果不进来源列表。

## 视图

- 面板宽 420；答案区上限：解释 380、搜索 360，内容不足时按内容收缩（`clampedHeight`）。
- 溢出时底部渐隐（material overlay），provenance 行的「已读取 N 个来源 ⌄」可跳到来源区。
- 行内引用是小号强调色 `[n]` 链接；点击高亮对应来源行并在同一滚动区内滚过去，不打开页面、不关闭面板。
- 来源行点击才打开页面；已引用来源的编号用强调色，未引用用次级色。
- 复制走 `AnswerDocument.plainText`，保留 `##` 标题、列表、`[n]` 与来源 URL。
- 减少动态效果、VoiceOver、文本选择均沿用系统行为；不引入打字机。

## 额度与成本

- 搜索输出预算 1 200 → 1 600 token；划词解释 600 → 900 token。
- reserve 输入按 `pageCount × 6 000` token 估算（prompt 每页上限 6 000 字符），是上界而非计费。
- 检索前先做不消耗额度的预检（`snapshot` + `policy.blocks`），额度已满不发起搜索与读页。
- `HTTPAIChatClient` 实现 `price`；划词解释原先 reserve/settle 都传 0，成本从未入账，现已按目录价计入。

## 测试与验收

- `AnswerProtocolTests`（21）、`AnswerPromptTests`（5）、`AnswerCanvasRenderingTests`（6，含 fittingSize 与截图）。
- 全量：1 183 个测试，0 失败，2 跳过。
- 视觉快照写入 `.build/answer-ui-validation/`：`explain-offline-zh.png`、`search-web-zh.png`、`explain-offline-dark.png`。

## P1：流式（已实现）

- 协议：OpenAI 与 Anthropic 两种 SSE 都映射到 `AIChatStreamEvent`；`[DONE]`、`message_stop`、`finish_reason`、`stop_reason` 都收敛到 `.finished(truncated:)`。
- 帧解码对任意分块边界安全：未闭合的帧留在缓冲区，CRLF 与多行 `data:` 都处理。
- 请求体：仅流式请求带 `stream: true`；OpenAI 格式额外带 `stream_options.include_usage`，否则无法计价。
- 拒绝流式的 provider/代理（400/404/405/415/422/501）自动回退到 `complete()`，且此时尚未生成 token，不会重复计费。
- 缓冲型代理不会失败，只是整段到达；行为与 P0 相同。
- 服务层：`AISearchService` 增加 `streamAnswer` 与 `onPartial`；每 24 个字符解析一次快照，最终仍走同一套降级规则。`SelectionExplainService` 直接消费 `client.stream`。
- UI：`AnswerReveal` 追赶式显示（落后约 1/6，33ms 一帧，≤250ms 视觉延迟）；Reduce Motion 时直接整段；阶段条只显示检索/读取/组织，当前页范围不显示检索；首字到达前显示骨架屏。

## 划词联网（已实现）

- 「联网检索」只在离线答案上出现，点击后先确认：「这段文字会作为搜索词发送给搜索提供商，并计入每日 AI 额度」。
- 复用 `AISearchServiceFactory`（从 ⌘K 面板抽取），两个入口的 provider、密钥、搜索路由与额度接线不再各写一份。
- 结果按 `.web` 模式渲染，来源为本次真正读取的页面。

## 仍未做

- 真实 provider 的 SSE 探针（TTFB、usage 位置、`[DONE]`）需要最小付费请求，本轮未执行；流式路径由合成帧与注入传输测试覆盖。
- 实时流式状态的截图未纳入快照（打字机是时间相关的），现有快照覆盖静态终态。
- 划词联网没有自动化测试（依赖 `AppSettings`/Keychain），确认弹窗与按钮只在渲染层面覆盖。
