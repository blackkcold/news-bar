# 阶段 4：免费一手来源与条件备援

## 目标与现状

给已入选的事件补充免费的一手材料，降低搜索调用，同时不替用户订阅来源。目前 `RSSService.fetchConditional` 支持 ETag/Last-Modified 与 304；事件追踪也有 RSS cursor 和滚动小时预算。搜索已有 Tavily、Firecrawl、TinyFish、Exa、Parallel、Brave 适配、缓存、provider 本地限额和按配置 failover；自动研究当前先用现有固定路由。

## 来源与准入

- 建立只读的内置证据目录；第一批为国家统计局「最新发布」RSS、香港政府新闻公报 RSS、USGS GeoJSON 地震摘要。目录仅在候选主题与来源类别/事件字段相符时按需检查，不全量轮询，也不写入用户 RSS 设置。
- 复用条件请求和缓存，保留来源 ID、原始 URL、来源标题、发布时间、抓取/更新时间和原始结构化字段。304 不产生新证据，超时、错误或数据过期也不产生事实断言。
- RSS 用来识别官方发布身份和原文标题/字段；不能据标题推断效果。USGS 只允许从 GeoJSON 自带的 event ID、time、place、magnitude、status 和详情 URL 生成限定字段的事实，自动补充的影响解释继续要求其他材料。
- 已启用用户 RSS 仍由原有订阅刷新复用；新的来源目录不修改开启/关闭状态。用户订阅以外的官方来源只为候选事件的补证流程服务。

## 搜索备援与预算

- 先使用一手目录、已有正文与缓存；仍存在具体缺口时才调用已启用的免 Key provider。每个 provider 只在预算、开关和冷却允许时分发；缓存命中不收费。
- 新增独立、默认关闭的 Parallel MCP 选项。它使用官方托管端点 `https://mcp.parallel.ai/mcp?tools=web_search,web_fetch`，仅暴露只读 `web_search` / `web_fetch`，不注册 research、decisions 或其他工具；用户打开该选项即允许此通道。普通 SearchProvider 已有结果时不调用，普通 provider 全部不可用或返回零个可用结果且自动额度剩余时才调用一次。现有 Parallel REST/API Key 配置保持独立。
- MCP `web_search` 只发送这次研究的公开主题与具体缺口，不附本机兴趣画像/阅读轨迹；`web_fetch` 只读取经 `PublicURLPolicy` 校验的搜索结果或用户已经提供的原始 URL。分别按一次实际工具分发计入搜索/抓页计数，缓存命中不计，限流进入 provider 冷却。
- 自动调用只走免 Key 通道；已保存的 provider Key 仍供手动研究使用。当前无法取得匿名供应商的真实月余额/日剩余或多 provider 共享用量，故使用每 provider 本地保守限额、为手动调用保留 50% 的本地日额度，以及阶段 2 的 8/20/40 自动调用硬上限；计数明确标为请求数，不宣称金额边界。以后若允许自动 Key 调用，必须先有可核算的供应商余额、单价、剩余天数、手动保留额和日/月费用限额。
- 继续沿用现有 Tavily/Firecrawl keyless 与用户已配置 Key 的适配和 SearchRouter failover。Exa、Parallel keyed REST 与 GDELT 仍是候补；不要求用户安装 MCP。失败/限流时按 SearchRouter 冷却，不复制同一查询无上限重试。
- 自动搜索统一走阶段 2 的日额度与逐任务硬上限；每日 search dispatch、provider failover 和抓页/AI 开销分别计数。服务商未公开的匿名额度采用本机保守值，服务商实际余额未知时不声称精确账单。

## 官方端点来源

- 国家统计局 RSS 目录：<https://www.stats.gov.cn/wzgl/rss/>（最新发布：`https://www.stats.gov.cn/sj/zxfb/rss.xml`）。
- 香港政府新闻公报开放数据条目：<https://data.gov.hk/sc-data/dataset/hk-isd-gnmis-gnmis>（条目列出政府新闻处 RSS 与更新时间）。
- USGS GeoJSON summary feed 说明：<https://earthquake.usgs.gov/earthquakes/feed/v1.0/geojson.php>。
- Parallel MCP 2.0：<https://docs.parallel.ai/integrations/mcp/quickstart>（匿名 `web_search`/`web_fetch` 与 `tools` URL 参数）；<https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http>（每个只读调用均为独立 HTTP POST）。
- 这些端点的可达性、字段变更和中文相关性应在集成验证中再确认；加入目录不等同于证明各类候选均可核验。
