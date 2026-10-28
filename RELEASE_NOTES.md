## [Unreleased]

## [v2.8.1] - 2026-10-28

### ✨ 新增
- **API Key 管理**：设置中可直接删除本机保存的密钥（含确认），1Password 中的原始条目与提供商侧密钥不受影响。
- **密钥状态**：AI 设置显示「已保存 / 未保存 / 标记为已保存但无法读取」三种状态，重启后也能判断当前提供商是否有可用密钥。
- **1Password 引用按提供商隔离**：每个提供商的引用单独保存，切换或保存其它提供商不再覆盖原引用；旧版单一引用继续作为迁移回退。
- **研究准入**：自动研究从本次尝试时间起算 6 小时冷却，最多 3 次自动尝试；自动队列上限 6 个，超出时挤掉最旧任务并标记为已中断；自动任务串行执行且间隔 120 秒，手动重试不受限制。

### 🛠 修复
- 自动研究失败后不再因「上次成功时间」未更新而在每次刷新时反复重跑；中断或取消的记录不会自动重跑。
- 研究进度快照不再覆盖自动尝试计数与运行来源；旧记录缺失新增字段时按原值读取，不伪造新状态。
- B 站条目优先用校验过的 BV 直链打开，短链仍作为新闻身份参与去重与记录；旧缓存不含新字段时仍可正常读取。
- 阅读器区分 DNS 解析失败、连接超时与普通网络错误，并给出对应恢复建议；不再把 DNS 失败显示成内网拦截。
- 设置页的成功/失败颜色由结果类型决定，不再依据本地化文案做字符串匹配。

### 🔒 安全
- 搜索提供方的 429/额度冷却写入研究账本，重启后仍然生效，避免重启即重新消耗已被拒绝的额度。
- 爆款详情页的「重新研究」改走与研究中心相同的协调器、账本与 HTTP 预算，遗留的 `BurstResearchService` 生产调用点已移除。
- 密钥相关测试改用注入的临时目录，不再读写真实加密凭据文件。

### ✅ 测试
- `swift test`：951 项通过，0 失败，2 项需显式开启的公网测试跳过。
- 新增自动准入、队列上限、冷却持久化、密钥作用域与 B 站直链回归测试。

### 📌 说明
- B 站原始故障未复现；本次只保证错误分类、直链打开与本机网络可达性，不宣称已修复特定网络环境下的问题。
- 自动研究固定串行 + 120 秒间隔，并发设置对手动任务生效；详情页「重新研究」最多等待 120 秒，超时返回上一份报告，研究会在后台继续。

### 📦 安装
- 下载 `NewsBar-2.8.1.dmg`，打开后拖入 Applications。首次启动如提示未验证开发者，请在「系统设置 → 隐私与安全性」中允许。

## [v2.8.0] - 2026-10-27

### ✨ 新增
- **研究中心**：统一的记录列表、详情、证据与核验面板；支持手动联网核查、爆款自动研究与关键词监控。
- **联网核查管线**：计划 → 搜索（Tavily / Firecrawl / Brave）→ 读取（内联 / 缓存 / Firecrawl / 本地直抓）→ 抽取 → 综合 → 逐字引文校验。
- **Firecrawl 个人 API Key**：可在设置中填入个人 Key，抓取按你的 Firecrawl 额度计费；关闭 provider 或无 Key 时不发出任何 Firecrawl 请求。
- **研究完成通知**：标题统一为「研究完成」，正文为不超过 80 字的一句话摘要，副标题为话题；失败与取消不推送。
- **研究历史清除**：统一的分阶段清除流程——写持久化清除意图 → 停止新研究 → 清空搜索与页面缓存 → 删除权威记录 → 清理旧版遗留 → 逐阶段验证 → 最后移除意图；崩溃或重启会从意图继续，失败阶段会保留意图并如实报告。
- **记录兼容与只读保护**：记录与索引写入 `schemaVersion`；缺失按 v1 读取，更高版本只做只读投影且不会被旧版本覆盖；损坏、不可读或更高版本的记录不能置顶、标记已读或改写，但仍可删除。
- **Provider 状态面板**：设置中显示每个搜索 provider 的关闭、缺少 Key、尚未尝试、上次成功、鉴权被拒、访问被拒、冷却中或临时失败状态；401 只在确实发送过 Key 时记住，403 不在同一轮重试但不会跨轮记忆。

### 🔒 安全
- IPv6 分类改用 `inet_pton` 二进制判定，只接受 `2000::/3`；非压缩回环、IPv4 映射、NAT64、6to4、站点本地地址全部拒绝。
- 新增 `PrivateHTTP`：所有外部请求使用 ephemeral 会话、逐跳重定向校验、流式响应上限；直抓、Firecrawl、搜索、AI 四条路径统一。
- RSS 抓取改为逐跳校验，堵住 302 到内网的 SSRF 缺口。
- 缓存条目不再保存明文查询词；通知正文剥离 HTML、链接与 Markdown。
- 以下个人数据文件从创建时即为 0600：研究记录/索引/meta/缓存/账本/清除意图、翻译缓存、AI 摘要缓存、API Key 存储、机器 UUID、阅读历史与请求预算；目录为 0700，写入失败保留原文件，不再出现世界可读窗口。
- 旧版本遗留的 0644 个人数据文件会在首次读取时收紧为 0600。

### 🛠 修复
- 进度写入只重写记录文件，索引最多每 10 秒刷新一次；长任务不再每秒重写全部条目。
- 删除记录或清空历史后，迟到的进度回调与 `touch` 不再复活记录。
- 索引截断不再隐藏第 1000 条之后的记录文件。
- 协调器加入 job token，重复调度与取消中的竞态不再产生双任务。
- 引文校验失败的证据不能再支撑 `confirmed`；结论只使用各 claim 自己引用的证据。
- 搜索结果失败也计入每任务 12 次 HTTP 上限。
- 自动研究以 `researchAutoEnabled` 为唯一总开关；`burstPushEnabled` 只决定通知。
- 已有 `.ready` 记录再次点击「联网核查」只打开报告，不再自动重跑。
- 搜索预算按实际派发精确计一次：缓存命中、禁用 provider 与冷却跳过不计数；成功、失败或分发后取消按同一实际分发数结算。
- 账本状态区分 `available / corrupt / ioUnavailable / unsupportedVersion`，异常时界面显示「—」而不是假的 0；重置会先归档损坏文件（0600），研究任务运行中拒绝重置。
- 旧版研究数据导入使用稳定身份；标题归一化为空也不会碰撞，只有全部持久化或可证明等价时才写入一次性完成标记，清除后不会重新导入。

### ✅ 测试

- `swift test`：929 个测试，2 skipped，0 failures。
- `scripts/build.sh`：release 构建、ad-hoc 签名、DMG 与 SHA256 校验通过。

### 📝 文档
- 新增 `docs/research-center.md` 与 `docs/research-center.zh-CN.md`。
- README 增加研究中心入口说明。

### 📦 安装

下载 `NewsBar-2.8.0.dmg`，拖入 Applications 即可。本版为本地 ad-hoc 签名，首次打开如被 Gatekeeper 拦截，请右键「打开」或在「系统设置 → 隐私与安全性」中允许。

## [v2.7.3] - 2026-10-27

### 🐛 修复
- **通知点击弹出摘要**：聚合通知的载荷缺少可用摘要时（旧版投递、每日模板、载荷损坏），改用已缓存的最新条目现造摘要并弹出，而不是只打开 Dashboard。
- **每日推送存活**：退出 App 不再清空待发通知，11:30 的每日摘要可以在 App 退出后按时触发；此前每次退出都会把定时请求一并删掉。
- **通知堆积**：每小时推送与每日推送改用固定请求标识，新推送替换上一条，不再每小时在通知中心堆一条。

### 🔧 改进
- **摘要面板主题**：通知摘要弹窗接上应用主题，复古主题下不再露出系统 sheet 的圆角灰底；分隔线随主题切换为墨线或细线。
- **点击可诊断**：通知点击的路由决策写入统一日志（`subsystem: com.newsbar.app`），可直接区分「系统没送到」与「送到了没弹窗」。
- **测试推送**：设置 → 开发者新增「发送测试推送」，用当前缓存条目立即投递一条推送，便于验证点击链路。

### ✅ 测试
- `swift test`：687 个测试，2 skipped，0 failures。

### 📦 安装
下载 `NewsBar-2.7.3.dmg`，拖入 Applications 即可。

## [v2.7.2] - 2026-10-27

### 🐛 修复
- **短链登录态**：B 站（`b23.tv`、`bili2233.cn`）与微博（`weibo.cn`、`t.cn`）的短链现在与主站共用同一份登录 Cookie；在榜单里打开短链条目不再退回未登录状态。
- **登录 Cookie 配额**：全局 600 条上限改为先保留所有站点的登录 Cookie、再淘汰普通站点；多个站点同时登录时不会再整站丢失。
- **匿名访问误判**：`buvid3`、`b_nut` 等匿名设备 Cookie 不再被当作已登录，普通站点不会挤占登录名额。
- **登出清理**：在站点自己的登出落地页（如 `passport.bilibili.com/login/exit`）完成登出后，本机保存的该站点登录会被移除；其他页面不会误删。
- **重复站点合并**：旧版本或降级运行留下的同一站点重复条目，会在下次启动时自动合并。

### ✨ 新功能
- **B 站阅读归因**：短链条目经 302 跳到 `www.bilibili.com` 后仍被识别为同一次打开，B 站内容开始计入阅读偏好；此前这类条目一律不计。
- **页面内弹窗**：`window.open` 不再被静默丢弃，改为在阅读器内打开；无法加载的目标直接忽略，不再新建逃出隔离环境的窗口。

### 🔧 改进
- **退出前采集**：有阅读器窗口时退出 App 会最多等待 2 秒，补一次 Cookie 采集，避免刚扫码登录就退出导致登录态丢失。
- **Cookie 库升级**：本机 Cookie 库升级到 v3 并按登录站点归并；降级到旧版本不会损坏数据，但旧版本可能显示同一站点的两个条目，再升级会自动合并。

### ✅ 测试
- `swift test`：681 个测试，2 skipped，0 failures。

### 📦 安装
下载 `NewsBar-2.7.2.dmg`，拖入 Applications 即可。

## [v2.7.1] - 2026-10-27

### 🐛 修复
- **热搜榜单回归右栏 02**：按源浏览恢复「01 每日简报 + 02 实时热榜」右栏，来源浏览只承载 RSS 源并回到 03；筛选、计数与空态统一由来源目录模型派生。
- **阅读器侧窗保留热搜**：阅读器把列表压到 320–480pt 时，02 以可展开的折叠行留在 03 上方，点开条目直接切换侧窗文章。
- **筛选空态**：热搜命中集中在 02 时，来源浏览显示明确提示，不再误报「没有匹配」。
- **文案与本地化**：补齐 01/02 标题与副标题的中英文，提示引用本地化标题。

### ✅ 测试
- `swift test`：651 个测试，2 skipped，0 failures。

### 📦 安装
下载 `NewsBar-2.7.1.dmg`，拖入 Applications 即可。

## [v2.7.0] - 2026-10-27

### ✨ 新功能
- **来源浏览目录**：Dashboard 新增按来源（全部 / 微博 / B 站 / RSS）浏览的目录视图；过滤与计数抽成独立纯模型，保持各来源原有顺序，并给出当前筛选结果数量。
- **聚合通知摘要**：一条通知聚合多个条目时，点击通知会列出该批全部内容，可逐条选择打开，而不是只跳转到第一条。
- **通知点击路由**：通知点击解析与路由从 AppDelegate 抽出为独立决策层，覆盖摘要、热榜、单条新闻与 Dashboard 四类入口，并注册通知分类。
- **更新检查回退**：GitHub API 限流时从官方 Release 页面恢复版本信息；自动下载仍只认可 GitHub 官方来源与下载域名，SHA-256 校验不变。

### 🔧 改进
- 推送条数上限收敛为 1–3，历史配置中的越界值会被夹紧，避免一次推送过多条目。

### ✅ 测试
- `swift test`：651 个测试，2 skipped，0 failures。

### 📦 安装
下载 `NewsBar-2.7.0.dmg`，拖入 Applications 即可。本版包含 v2.6.1 的阅读器内嵌访问修复。

## [v2.6.1] - 2026-10-26

### 🐛 修复
- **阅读器浏览器标识**：为阅读器 WKWebView 设置与系统版本一致的完整 Safari User-Agent，避免站点把内嵌 WebView 判为“浏览器版本过低”并返回拦截页。
- **风控页识别**：主文档返回 HTTP 412 时直接判定为站点风控拒绝，显示可操作的失败提示并支持在浏览器打开；不再把错误页当作正常加载，也不会计入有效打开与正向阅读证据。

### ✅ 测试
- `swift test`：612 个测试，1 skipped，0 failures。

### 📦 安装
下载 `NewsBar-2.6.1.dmg`，拖入 Applications 即可。

## [v2.6.0] - 2026-10-26

### ✨ 新功能
- **推荐原理与我的兴趣**：设置 → 通用 → 本地兴趣与隐私内新增只读解释中心，分「概览 / 兴趣关联 / 推荐链路 / 数据与隐私」四段；展示本机画像、主题/实体/关注分组、标签命中关系与逐条文字等价，不把布局位置当作向量距离或因果。
- **真实推荐轨迹**：每个推荐条目记录原始分量、加权贡献、个人/基线混合、惩罚、多样性前后名次与实际选择策略；公共热度位、公共新鲜位、来源补位分别标注，来源补位明确为确定性轮换而非加分。
- **离线推荐说明**：新增单一双语 JSON 来源，App 内可离线阅读，并生成中英文仓库文档；`scripts/sync-recommendation-guide.sh --check` 校验一致性。
- **关注主题归一**：词典内关注词映射到规范主题/实体（如“人工智能”→AI、“Swift”→科技、“EV”→汽车），同一主题多别名只计一次；词典外关键词保留字面匹配。

### 🐛 修复
- **曝光口径**：曝光绑定信息流自身窗口、列表可见性与阅读器遮挡；应用失活、锁屏或不可见时重置连续计时；稳定信息流会话并按 consent epoch 去重，避免设置窗、阅读器覆盖或视图重建造成误采与重复曝光。
- **事件与画像分离**：原始事件流水不再因证据升级被删除；画像仍按同篇同日最强证据聚合；只有成功加载的打开才计入正向证据，失败/拦截不留正向学习。
- **批次归因**：事件补充 surface、contextID、position、feed/reader 会话与真实 ranking/profile 版本；打开、阅读、失败与外部打开可归属同一推荐批次。
- **反馈幂等与同意语义**：屏蔽来源、隐藏事件、减少主题、收藏按真实作用域去重；“更多同类”会话级幂等且可撤销；关闭/暂停/隐私阅读时收藏、屏蔽、隐藏仍可用，减少主题/更多同类/关注需学习开启且之后不会补学。
- **清空与恢复**：清空个人数据默认停止学习，同时清理行为、画像、阅读会话、关注与公开内容缓存；保留收藏但不参与画像；失败显示“状态未确认”而非成功；损坏或未知 schema 的兴趣库可经显式清空恢复。
- **推荐文案**：将确定性来源补位从“探索推荐”改为“来源补位”，避免把系统编排误读为兴趣探索。

### 📝 文档
- 新增 `docs/recommendations-explained.md` 与 `docs/recommendations-explained.zh-CN.md`，与 App 内离线说明共用同一份双语 JSON。
- README 增加推荐说明入口。
- 新增 `--verify-recommendation-guide` 诊断入口，可在不启动 App 的情况下验证打包资源。

### ✅ 测试
- `swift test`：608 个测试，1 skipped，0 failures。
- 打包后真实 `.app` 资源诊断：`available=true`、`zh=8 en=8`、`result=ok`。
- `scripts/build.sh`：release 构建与 DMG 打包。

### 📦 安装
下载 `NewsBar-2.6.0.dmg`，拖入 Applications 即可。

## [v2.5.0] - 2026-10-26

### ✨ 新功能
- **本地兴趣引擎**：显式开启后在本机记录阅读证据、构建兴趣画像并生成「为你推荐」；支持暂停、隐私阅读、清空个人数据与同意 epoch 隔离，学习数据仅保存在本机 SQLite。
- **推荐反馈闭环**：支持收藏、更多同类、不感兴趣、隐藏事件、减少主题、屏蔽来源与会话级撤销；推荐排序在本机完成，不改变来源原榜顺序。
- **Dashboard 内嵌阅读器**：在独立 Dashboard 中直接阅读原文，使用隔离 WebKit 会话、导航策略与可选受信任 HTTP CONNECT 代理；支持站内前进/后退、重新加载与外部浏览器打开。
- **阅读登录记忆与历史**：阅读器仅保存第一方 Cookie 到本机加密 vault，并在下一次访问时回填；可在设置中关闭登录记忆/历史，也可管理站点登录、阅读历史与清除数据，不导入系统浏览器 Cookie 或历史。
- **阅读器过渡与分栏**：新增 Hero 卡片过渡、列表快照、宽屏分栏与可拖拽分隔条，开合阅读器时保持列表稳定。
- **AI 提供商模型与摘要快照**：新增 provider model 查询、持久化请求预算与摘要 manifest，提升模型选择与引用回溯的稳定性。

### ⚡ 性能与稳定性
- **渲染降本**：移除重复窗口材质与卡片材质/合成层，卡片改为近不透明表面；支持「降低透明度」；阅读器使用不透明底。
- **曝光管线批处理**：阅读曝光进入内存缓冲，1.5 秒合并 flush；持久化合并为最新快照，prune 降为每 60 秒；关闭 Dashboard 不再重建无人查看的排名。
- **打开路径减负**：Dashboard 刷新延后 450ms；首帧不再解密 Cookie 库或预编译 WebKit 规则；AI 摘要延后 2 秒并缓存解析结果。
- **阅读器与图片**：阅读器心跳降为 2 秒且仅在活跃时读取输入空闲；Cookie 并发注入；RSS 图片增加磁盘缓存、失败负缓存与 120 张内存缓存。
- **搜索与排名**：搜索 150ms 防抖，查询词只折叠一次；排名前一次性构建阻断索引，复用候选 ID。
- **稳定性修复**：本地兴趣写入、同意撤销、阅读会话结束、Cookie/历史存储与打包路径均补充回归测试。

### 📦 打包与规则
- 本地验证构建统一输出到 `release/{version}/NewsBar.app`，不再写入 `output/`。
- 新增 `--force` 覆盖保护；本地打包不生成 DMG，不更新 `release/latest`、`release/versions.json` 或 GitHub Release。
- 同步全局文件输出规则：构建/发布产物遵循项目约定目录，文档/报告才使用 `output/`。

### ✅ 测试
- `swift test`：486 个测试，1 skipped，0 failures。
- `scripts/build.sh`：release 构建与 DMG 打包。

### 📦 安装
下载 `NewsBar-2.5.0.dmg`，拖入 Applications 即可。

## [v2.4.1] - 2026-08-07

### 🐛 修复
- **36氪 RSS 源修复**：将旧地址 `https://36kr.com/feed`（返回 HTML 反爬页面）自动迁移到规范地址 `https://www.36kr.com/feed`（返回合法 RSS）。已保存的旧订阅、手动添加和推荐列表均会统一到规范主机，并自动去重。
- **HTML 反爬响应处理**：识别 `text/html` 挑战页后，使用浏览器兼容头重试一次，仍失败时给出含状态码、Content-Type、响应类型与字节数的诊断信息，避免误导性「未返回有效 RSS」提示。
- **RSS 解析与验证统一**：添加源验证、推荐验证与正式刷新共用同一完整解析链路，避免「验证通过但刷新失败」的分歧。

### ⚡ 稳定性
- **失败调度修正**：区分「最近尝试」与「最近成功」，失败源按指数退避重试，不再被当作「刚刷新过」而跳过。
- **过期缓存上限**：连续失败超过 24 小时的缓存不再继续展示，避免长期显示过期内容。

### ✅ 测试
- **新增 11 项根因回归测试**：覆盖 36kr 地址规范化、HTML 挑战页识别、正式解析器对有效 feed/挑战页的处理、浏览器兼容头、旧订阅迁移去重与 24 小时缓存边界。
- **全量测试**：`swift test` 374/374 通过。

## [v2.4.0] - 2026-08-05

### ✨ 新功能
- **爆款联网搜索增强**：爆款调研改用多角度查询（来龙去脉/起因经过结果/news timeline），并在搜索后主动抓取前 4 个结果的完整正文喂给 AI，时间线素材更充足、来龙去脉更完整。
- **自定义关键词监控**：新增「关键词监控」设置，扫描微博、B站热搜与全部已启用 RSS 标题，命中任一关键词即推送单条通知并调用 AI 调研（来龙去脉与时间线），复用爆款详情窗口。大小写/变音符不敏感，可按关键词+标题去重防刷屏。
- **Dashboard 搜索与筛选**：顶部新增统一搜索框与来源筛选（全部/微博/B站/RSS），实时过滤 RSS 主版与热点卡片，显示匹配条数。
- **设置页重制为 7 页签**：通用 / 刷新与诊断 / RSS / AI / 提醒 / 开发者 / 关于。原「通用」页签拆分，刷新状态与日志、爆款测试与开发者开关归入独立页签，布局更清晰。
- **Liquid Glass 支持**：macOS 26+ 下设置页与 Dashboard 筛选栏使用 Liquid Glass（浮框/胶囊），macOS 15 自动降级为材质；复古主题同步沿用纸张 + 硬描边风格。

### 🔧 改进
- **关键词匹配工具**：`AppSettings` 新增 `activeKeywords` 与 `keywordMatches` 助手，统一匹配语义供编排器与设置页复用。

### ✅ 测试
- **新增关键词监控测试**：覆盖关键词去空格、大小写/变音符不敏感、多关键词任一命中、子串匹配等场景。
- **全量测试**：`swift test` 349/349 通过。

## [v2.3.0] - 2026-08-05

### ✨ 新功能
- **RSS 标题翻译**：英文界面下可开启 RSS 标题自动翻译（免费 MyMemory 服务），翻译结果缓存避免重复请求与限流；原文始终保留用于 AI 总结，失败自动回退原文。
- **多语言本地化框架**：新增轻量 `L10n` 本地化层（无需 `.xcstrings` bundle），界面文案全面支持中英双语，随语言设置实时切换。

### ⚡ 性能与稳定性
- **AI 总结提速与截断修复**：请求超时由 30s 提升至 60s；输出 token 预算按摘要长度动态扩容，避免 360 字简报被截断。
- **DeepSeek 思考模式开关**：新增「关闭 DeepSeek 思考模式（更快输出）」设置项（默认开启）。DeepSeek V4 思考过程会占用输出额度并拖慢速度，关闭后可大幅提速并避免摘要截断；可在设置中重新开启以换取更高归纳精度。
- **AI 截断判定增强**：即使返回 `length` 截断标记，只要已解析出【趋势概览】与【每日精选】两个完整板块即视为摘要完整，消除「内容其实完整仍被标记为不完整」的误报。
- **AI 请求兼容性**：放宽响应 `Content-Type` 校验，兼容代理缺失请求头的情况，减少偶发「AI 总结失败」。

### ✅ 测试
- **全量测试**：`swift test` 333/333 通过。

## [v2.2.3] - 2026-08-04

### ✨ 新功能
- **AI 两层判断 + 爆标签即时触发**：AI 摘要新增两层判断。常态下统一按「距上次总结 ≥ 1 小时」作为自动生成基准；当识别到微博热搜出现「爆」标签话题时，立即触发一次总结，并强制将带爆标签的微博热搜纳入【趋势概览】优先展示。爆标签成功总结后 15 分钟内不重复触发。
- **微博状态标签识别**：新增解析微博热搜 `label_name`（爆/沸/热/新）及 `is_boom`/`is_fei`/`is_hot`/`is_new` 布尔兜底标记，作为 AI 即时触发的依据。
- **Ollama Cloud 提供商**：新增 Ollama Cloud 内置提供商，支持 deepseek-v4-flash:cloud、deepseek-v4-pro:cloud、gpt-oss、kimi-k3、minimax-m3 等云模型。
- **自定义 AI 提供商**：支持用户自定义端点、模型 ID 与认证头，灵活接入任意兼容 OpenAI 的服务。
- **AI 模型折叠**：默认仅显示各供应商的 DeepSeek 系模型；在「通用 → 开发者选项」开启「显示全部 AI 模型」可查看全部官方模型。

### 🐛 稳定性修复
- **AI 冷却倒计时假死修复**：Popup 与 Dashboard 的「重新生成/独立刷新」按钮冷却倒计时由静态快照改为每秒实时刷新，倒计时结束后自动解除禁用，不再出现按钮无法点击的假死问题。

### ✅ 测试
- **新增测试**：`testBurstWeiboTriggersImmediatelyButThrottled` 覆盖爆标签即时触发与 15 分钟去抖；`testAutomaticSummaryRespectsTrendAndRSSMinimumIntervals` 更新为 1 小时基准。
- **全量测试**：`swift test` 322/322 通过。

---

## [v2.2.2] - 2026-08-03

### ✨ 新功能
- **共享 AI 摘要**：Popup 与 Dashboard 复用同一份详细 AI 简报，不再各自独立生成。Popup 每类最多显示 2 条，Dashboard 显示完整结果，消除重复 AI 请求。
- **Dashboard AI 独立刷新**：AI 简报面板新增独立刷新按钮，支持 60s 冷却保护，不依赖全局刷新。
- **RSS 单源刷新**：Dashboard 每个 RSS 源卡片增加独立刷新按钮，带加载状态反馈，不影响其他源。
- **智能刷新调度**：热搜按可见性自适应刷新（可见 5 分钟/后台 30 分钟/低电量 60 分钟），RSS 按活跃度自适应（30 分钟/60 分钟/3 小时），失败退避（15 分钟 → 30 分钟 → 60 分钟 → 最长 3 小时）。
- **12/24 小时趋势历史**：新增 TrendHistoryStore，24 小时滚动保留最多 288 个快照，30 分钟 heartbeat，趋势评分与变化摘要，跨启动持久化。
- **历史感知 AI 总结**：AI 自动总结结合近 12/24 小时趋势历史，仅在显著变化及冷却条件满足时重建（趋势 ≥30 分钟、RSS ≥4 小时），避免重复总结热点。
- **AI 摘要持久化**：新增 AISummaryCacheStore，持久化摘要内容、内容哈希、趋势哈希、引用快照和生成时间，跨启动恢复。
- **RSS 条件请求**：支持 ETag/Last-Modified 与 HTTP 304，减少无效网络传输。

### ⚡ 性能优化
- **Popup 实例复用**：首次打开后复用 NSPopover 实例，消除重复创建 SwiftUI 树的开销。
- **启动缓存预热**：App 启动时异步预加载缓存数据，减少首次打开 popup/Dashboard 的等待时间。
- **图片缩略解码**：ImageCache 新增 CGImageSource 缩略图解码（最大 480px），避免 SwiftUI 渲染时解码原始大图。
- **图片请求合并**：相同 URL 的并发请求自动合并，减少重复网络开销。
- **Popup 外层懒加载**：ScrollView 内 VStack 改为 LazyVStack，延迟非可见区域视图创建。
- **日期格式器复用**：Popup 与 Dashboard 的 DateFormatter 提升为静态常量，避免每次 body 重建。
- **缓存 freshness 追踪**：新增 lastValidatedAt 字段，stale-while-revalidate 策略，过期缓存立即显示不阻塞 UI。
- **AI 逐字动画计算优化**：预计算 RenderModel 和字符数组，30ms/3 字符稳定帧率，AISummaryParser 正则静态缓存。
- **Observation 子树隔离**：Popup AI 区域拆为独立 Observation 子树，减少无关视图刷新。
- **稳定 NewsItem ID**：改为 SHA-256 哈希，消除重复条目。
- **BatchProgress 结构体化**：改为 Equatable struct，减少不必要的 SwiftUI 重绘。

### 🎨 UI 优化
- **RSS 卡片元信息精简**：移除图文卡片底部重复的来源徽章和网址，仅保留顶部来源徽章，底部改为「阅读原文」提示。
- **RSS 文本行精简**：移除来源名称右侧的网址显示，减少信息冗余。
- **AI 设置页简化**：移除独立的 Popup/Dashboard 摘要长度和预算模式选择器，统一为共享摘要长度和共享额度。
- **设置页刷新说明**：通用设置新增智能刷新调度说明和日志类型。

### ✅ 测试
- **新增测试**：`AISummaryParser.limited` 摘要裁剪、`ImageCache.decodeThumbnail` 缩略解码、共享摘要目标常量。
- **测试适配**：截断哈希、连续截断计数、clearCache 等测试从双目标改为共享单目标。
- **新增回归测试**：RefreshTrendPerformanceTests 覆盖刷新调度、缓存 freshness、条件请求、趋势历史、AI 持久化、性能回归。
- **全量测试**：`swift test` 321/321 通过。

---

## [v2.2.0] - 2026-07-30

### ✨ 新功能
- **复古报刊编辑风主题**：新增可持久化的 Retro Editorial 主题，并在设置页主题区域提供切换入口；以米白、砖红、黑色、纸张颗粒、粗边框和硬阴影统一覆盖主要界面。
- **全局主题组件体系**：新增共享主题色、纸张背景、编辑式抬头、剪报卡片、印刷按钮与新闻源徽记，确保 Dashboard、Popup、设置页及状态组件使用同一套视觉语言。

### 🎨 界面重制
- **Dashboard 深度重制**：重新设计窗口导航栏、趋势卡片、AI 简报和 RSS 新闻卡片；居中椭圆标题改为响应式布局，并移除重复标题与文字阴影重影。
- **Popup 深度重制**：重做新闻分区、AI 摘要、新闻行、RSS 文本流与图片流、底部操作栏和更新提示，使主题在完整弹窗流程中保持一致。
- **主题形态统一**：复古主题下将圆角容器与控件切换为方框和硬边界；普通模式同步引入更清晰的页面抬头结构，同时保持现代材质外观。
- **新闻源与热搜符号重制**：为微博、B 站、RSS 与趋势排行提供适配复古报刊语义的印刷式 UI 符号、徽记和状态标识。

### ✅ 测试
- **主题状态回归测试**：覆盖主题默认值、持久化、无效值回退和复古主题配色解析。
- **全量测试**：`swift test` 303/303 通过。

---

## [v2.1.0] - 2026-07-29

### 🔐 安全增强
- **更新下载信任链加固**：仅接受 canonical GitHub Release 元数据与 GitHub 自有下载主机组合，拒绝代理元数据、第三方主机及重定向攻击路径。
- **网络与图片负载上限**：为微博、B 站、RSS、AI 响应设定大小上限；图片缓存校验 MIME 类型和 10 MB 单文件上限，并限制总缓存成本。
- **1Password 引用校验**：校验 `op://` 引用格式，并以异步读取避免阻塞主线程。

### 🐛 稳定性修复
- **AI 预算共享正确记账**：Popup 与 Dashboard 共享每日请求基线，避免并发生成或重试重置预算；两端截断计数彼此隔离。
- **摘要生成更可控**：Dashboard 仅在打开时惰性生成，避免普通刷新触发不必要的 AI 请求。

### ✨ 交互与一致性
- **设置操作增加确认**：删除 RSS 源、清除缓存与退出应用均提供明确确认，减少误操作。
- **原生可访问控件**：更新提示改用原生 Button，AI 摘要重试状态由实际生成与冷却状态驱动。

### ✅ 测试
- **新增安全与回归测试**：覆盖更新信任链、HTTP 负载边界、图片缓存、1Password 引用及 AI 预算/截断状态；全量 `swift test` 301/301 通过。

---

## [v2.0.8] - 2026-07-28

### 📦 构建优化
- **DMG 打包增加 Applications 文件夹快捷方式**：打开 DMG 即可看到 Applications 文件夹符号链接，用户可快速拖入安装
- **自定义 DMG 背景布局**：新增 Resources/DMGBackground.png 深色玻璃质感背景图，Finder 图标自动定位在 {200,200}（App）和 {600,200}（Applications）
- **DMG 打包流程重构**：从纯 hdiutil 升级为 staging + 可写 DMG + Finder layout 两阶段流程，支持自定义背景和图标布局

### 🔧 改进
- `scripts/build.sh`：新增 DMG_STAGING 临时目录组装；osascript 写入 Finder 窗口布局（图标位置/大小/背景/视图选项）；压缩阶段添加 zlib-level=9 提高压缩率

---

## [v2.0.9] - 2026-07-29

### 🐛 Bug 修复
- **Popup AI 摘要格式异常不再显示原始长文本**：当 AI 返回的响应无法解析出任何主题板块时，自动以更严格的格式约束重试一次（受日调用上限约束）；重试后仍不可解析则显示格式错误提示与「重新生成」按钮，不再回退显示原始 AI 文本。
- **来源徽章首次启动一致性**：摘要状态、解析结果与新闻快照作为同一生成结果提交，消除首次渲染时来源索引映射的残余时序风险。

### ✅ 测试
- **新增离线回归测试**：覆盖不可渲染格式的解析器行为、格式重试判定逻辑、重试预算边界，共 15 个新测试用例。

### 🔧 改进
- **格式重试受预算约束**：重试计入既有日调用上限，不绕过预算检查；最多一次，不循环。
- **开发文档同步**：`.memory/PROJECT_BOOTSTRAP.md` 更新 AI 生成/重试说明。

---
## [v2.0.7] - 2026-07-28

### 🐛 Bug 修复
- **Popup AI 摘要逐字生成保持 SectionRow 与可点击来源角标**：逐字生成时不再切换成单个原始文本块，保持 SectionRow 结构和来源角标可点击。
- **修复内联引用格式未提取来源**：修复 `【标题】正文[#N]` 格式中来源未正确提取的问题，Popup 现可正确显示并点击来源角标。

## [v2.0.6] - 2026-07-28

### 🐛 Bug 修复
- **无引用趋势概览不再消失**：趋势概览分类明确标注为「趋势概览」时，即使无有效引用编号，该段落仍保持可见，不再被错误隐藏。无引用时不显示来源角标

### ✨ 新功能
- **Popup 双分类渲染**：Popup AI 摘要面板与 Dashboard 一致，支持「趋势概览」和「每日精选」双分类渲染，分段显示
- **引用来源角标常驻可见**：有有效引用编号的 AI 摘要行，来源角标始终可见（不再仅悬停显示），点击即可跳转原始新闻

## [v2.0.5] — AI 摘要截断修复 & Dashboard 信息量增强 - 2026-07-27

### 🐛 Bug 修复
- **Popup AI 截断内容不再卡死**：修复截断时 `popupLastHash` 仍被更新导致自动刷新跳过生成的问题。新增双哈希去重（`popupLastTruncatedHash`/`dashboardLastTruncatedHash`），截断写截断哈希不污染成功哈希，成功后清除截断哈希
- **Dashboard 截断死锁修复**：`generateDashboardSummaryIfNeeded` 的 `shouldGenerate` 增加 `dashboardLastTruncatedHash` 检查，`dashboardSummaryNeedsGeneration` 增加 `.truncated` 触发重试，消除截断后重开 Dashboard 不再生成的死锁
- **regenerateAISummary 哈希泄漏修复**：将哈希管理从 3 个调用方内聚到 `generateSummary` 内部统一处理，消除手动重新生成截断后不更新哈希导致下次自动刷新重复生成的预算泄漏
- **连续截断保护**：新增 `consecutiveTruncationCount` 计数器，连续截断 ≥3 次自动停止重试，防止变化条目持续截断导致预算消耗，用户仍可手动重新生成（60s 冷却限制频率）

### ✨ 新功能
- **Dashboard AI Briefing 信息量增强**：趋势概览和每日精选话题数从 2-3 提升到 4-5，确保 Dashboard 摘要信息量多于 Popup
- **AI prompt 话题数参数化**：`AISummaryService.summarize` 新增 `trendTopicCount`/`dailyTopicCount` 参数，Popup 保持 2-3，Dashboard 4-5，prompt 模板动态插值

### 🔐 安全/隐私增强
- **AI 反幻觉规则**：systemPrompt 新增规则 7「禁编造：在条目不足以填满请求的话题数时，绝不要编造新闻话题；只涵盖可用内容」
- **AI prompt 标题隔离**：sanitizeTitle 在注入 prompt 前剥离控制字符和【】/ [# 结构定界符，防止外部新闻标题恶意破坏 prompt 格式或注入指令
- **AI 隐私边界声明**：system prompt 明确标注用户提供的标题为不可信外部数据，禁止视为指令或提示词注入

### 🔧 改进
- **max_tokens 提升**：`initialMaxTokens` 1024→2048，`retryMaxTokens` 2048→3840（MiniMax 安全边际 5%），降低截断概率
- **clearCache 完整性**：`clearCache()` 新增清理 `popupLastTruncatedHash`/`dashboardLastTruncatedHash`/`consecutiveTruncationCount`

### 🔧 技术细节
- `NewsOrchestrator.swift`：新增 `popupLastTruncatedHash`/`dashboardLastTruncatedHash` 双哈希去重；`consecutiveTruncationCount`/`maxConsecutiveTruncations=3` 连续截断保护；`currentTruncatedHash`/`setTruncatedHash`/`clearTruncatedHash` context-aware helpers 遵循现有 `SummaryTarget` 模式；`generateSummary` 新增 `contentHash` 参数统一管理哈希
- `AISummaryService.swift`：`summarize` 签名增加 `trendTopicCount`/`dailyTopicCount` 参数（默认 2...3）；`promptTopicHint` 静态方法生成话题数提示文本；`systemPrompt()` 新增规则 7 反幻觉；`max_tokens` 2048/3840
- `DashboardAIBriefingPanel.swift`：`dashboardSummaryNeedsGeneration` 增加 `.truncated` 触发重试
- 测试覆盖：184/184 通过（原 165 + 新增 19），涵盖截断哈希去重、连续截断保护、clearCache 清理、dashboardSummaryNeedsGeneration 状态机、prompt 话题数生成

---

## v2.0.0 — 原生 Dashboard & 双分类 AI 简报 - 2026-07-27

### ✨ 新功能
- **原生 Dashboard 窗口**：独立 NSWindow（1180×860，最小 960×720），侧边栏热点趋势卡片（微博/B站，可折叠展开）+ AI 简报面板，右侧按来源分卡的 RSS 固定双列网格区域
- **双分类 AI 简报**：AI 摘要升级为「趋势概览」（仅微博/B站引用）和「每日精选」（所有源）两个板块，Dashboard 中通过 segmented Picker 切换；Popover 保持单分类旧格式
- **Dashboard RSS 按源分卡**：所有已订阅 RSS 源在 Dashboard 主区以独立卡片排列，每卡内固定双列 LazyVGrid 布局，列间距 12pt，图文卡片异步加载图片，按源着色
- **可配置 AI 日调用上限**：新增 aiDailyCap 设置，白名单 20/50/100 次，超出后自动停止 AI 请求
- **Dashboard 状态反馈栏**：显示手动刷新警告和 RSS 批量刷新进度
- **独立 Popup/Dashboard AI 摘要**：Popup 在刷新时生成精简摘要（默认 120 字），Dashboard 在打开时惰性生成详细摘要（默认 360 字），两者各有独立字数预设（Popup: 80/120/160/200；Dashboard: 240/360/480/600）并共享每日 AI 调用上限
- **Dashboard RSS 固定双列网格**：Dashboard RSS 卡片区域改为固定双列 LazyVGrid（GridItem(.flexible(), spacing: 12) × 2），原生列管理，不再依赖 onGeometryChange

### 🔐 安全/隐私增强
- **AI prompt 标题隔离**：sanitizeTitle 在注入 prompt 前剥离控制字符和【】/ [# 结构定界符，防止外部新闻标题恶意破坏 prompt 格式或注入指令
- **AI 隐私边界声明**：system prompt 明确标注用户提供的标题为不可信外部数据，禁止视为指令或提示词注入
- **per-dispatch 预算记账**：每次 HTTP 请求前检查 baseline + attempts ≤ cap，重试也计入 attempts，确保总请求数不超限
- **并发生成锁**：OSAllocatedUnfairLock 防止并发 AI 请求，defer 确保释放
- **手动再生冷却**：60s 冷却窗口，阻止频繁手动再生

### 🔧 技术细节
- `DashboardWindow.swift`：新增，独立 Dashboard 窗口，侧边栏（热点卡片 + AI 简报）+ 按源分卡 RSS 主区，状态反馈栏，工具栏刷新/设置按钮
- `DashboardVisualComponents.swift`：新增，DashboardHotTrendCard（可折叠热点卡片，排名前三彩色徽章）、DashboardAdaptiveRSSMasonryFeed（固定双列 LazyVGrid，GridItem(.flexible(), spacing: 12) × 2，原生列管理）、DashboardRSSMasonryCard（图文卡片，ImageCache 异步加载，hover 高亮）
- `DashboardAIBriefingPanel.swift`：新增，双分类 Picker（trendOverview/dailyEssentials），状态驱动 UI，引用快照回溯，兼容旧格式回落
- `AISummaryParser.swift`：新增 parseDualSummary 双分类解析，按引用编号过滤趋势源，无标签时回落旧格式
- `AISummaryService.swift`：新增 initBudget/consumeAttemptBudget/readGenerationAttempts 预算系统；tryAcquireGenerationLock/releaseGenerationLock 并发生成锁；regenerationCooldownRemaining/recordManualRegeneration 冷却机制；sanitizeTitle 标题消毒
- `AppSettings.swift`：新增 aiDailyCap 字段 + validAICaps 白名单（20/50/100）；aiPopupMaxWords + validAIPopupMaxWords（80/120/160/200）；aiDashboardMaxWords + validAIDashboardMaxWords（240/360/480/600）；recordAIRequests 按实际请求次数记账
- `NewsOrchestrator.swift`：新增 aiParsedSummary/dashboardParsedSummary 双缓存；generateSummary 支持 SummaryTarget（popup/dashboard）区分生成；setSummaryItems/setSummaryState/setParsedSummary 按目标路由；popupLastHash/dashboardLastHash 独立 hash 追踪；Dashboard 打开时惰性触发 generateDashboardSummary
- `AppDelegate.swift`：新增 openDashboard/closeDashboard 窗口管理，dashboardSize/dashboardMinimumSize 常量
- `DashboardWindow.swift`：Dashboard 中 RSS 按源分卡（DashboardRSSSourceCard），Popover 保持每源独立 RSSWaterfallView 行为；Dashboard 打开时触发惰性 AI 摘要生成
- `AITab.swift`：新增 Popup/Dashboard 独立字数预设 Picker + 日调用上限 Picker
- 测试覆盖：165/165 通过，涵盖 Dashboard 组件、双分类解析、预算系统、生成锁、冷却机制

### 🐛 Bug 修复
- **Dashboard RSS 长标题不再撑宽卡片**：修复长标题导致卡片宽度被撑开、列间间隙消失的问题。卡片内容改为 `.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)`，确保所有卡片等宽，列间距稳定保持 12pt

## v1.5.0 — RSS 增强 & 通知推送 - 2026-07-17

### ✨ 新功能
- **RSS 显示计数统一管理**：新增 unifiedDisplayCount 开关，开启后 Popover 与 Dashboard 共享全局文本/图片显示条数；关闭后支持按数据源和显示模式分别设置条数，并提供"恢复默认"一键重置为全局值
- **移除 RSS 上限**：不再限制 3 个 RSS 源，支持任意数量
- **RSS 双列图片卡片**：LazyVGrid 瀑布流布局，自动提取 RSS 配图，16:9 比例裁剪
- **macOS 通知推送**：每小时自动推送最新新闻 + 每日定时摘要推送
- **流式刷新进度**：RSS 源分批 6 并发刷新，BottomBar 显示完成进度
- **已订阅/未订阅分组**：设置页 RSS 源列表按订阅状态分组，清晰区分已订阅与未订阅源
- **拖拽实时预览排序**：已订阅源支持拖拽调整顺序，松开前实时预览目标位置
- **串行可取消推荐验证**：逐源串行验证推荐可用性，支持取消、进度显示、失败重试，完成后汇总通过/失败/已取消统计

### 🔐 安全增强
- **RSS 图片 SSRF 防护**：图片 URL 使用 validateRSSURL 校验，防止内网 IP 探测
- **图片加载隔离**：ephemeral URLSession，不共享 cookie，防止认证信息泄露
- **推荐添加安全验证**：添加推荐源前通过 SecurityPolicies.validateRSSURL 校验，拦截内网/本地地址，警告私有网段

### 🔧 改进
- **差异化刷新**：定时刷新仅更新超过 15min 未变化的源，减少不必要的网络请求
- **单源超时控制**：RSS 请求 10s 超时，防止慢源阻塞批次
- **Popover 宽度 360→400px**：更宽敞的阅读体验
- **图片缓存**：NSCache + ephemeral URLSession，滚动时不重复下载

### 🔧 RSS 显示优化
- **RSS 双模式显示**：文本流(单列紧凑列表 LazyVStack) / 图片流(双列卡片 LazyVGrid)，Picker 标签同步为"文本流"/"图片流"
- **图片流分页加载**：展开后每批加载 4 条，滚动到底自动加载更多，sentinel guard 防无限循环
- **文字优先渲染**：文字即时显示，图片异步加载完成后 spring 动画过渡(.scale.combined(with: .opacity))
- **源级自动降级**：图片流模式下无图片源自动降级为文本流，会话内锁存避免刷新闪烁
- **多源同时展开**：支持多个 RSS 源同时展开，sticky 收起条快速折叠
- **DisplayMode 枚举重命名**：single→text, scroll→image，Codable 自定义 init(from:) 向后兼容旧值(含未知值 silent fallback)
- **RSS 源排序**：设置页支持上下按钮调整 RSS 源顺序，主面板与 Dashboard 同步反映新顺序

### 🔧 技术细节
- `RSSRecommendations.swift`：严格直连策略，10 个出版商自托管 HTTPS 源，覆盖 4 分类（科技/综合/财经/国际）
- `NewsOrchestrator.swift`：新增 batchProgress 字段 + lastSourceRefresh 差异化刷新追踪
- `RSSService.swift`：RSSParserDelegate 新增 enclosure/media namespace/content:encoded 图片解析；fetch 增加 10s 超时
- `SecurityPolicies.swift`：新增 extractFirstImageURL 函数（不修改 forbiddenTags）
- `NewsItem.swift`：新增 imageURL Optional 字段（Codable 向后兼容）
- `NotificationService.swift`：新增，每小时 + 每日通知推送
- `ImageCache.swift`：新增，actor 隔离 NSCache + ephemeral URLSession
- `RSSWaterfallView.swift`：重构为双模式视图(文本流 LazyVStack + 图片流 LazyVGrid) + ImageLoadState 枚举 + 源级自动降级(会话锁存) + 分页加载 + RSSTextRow 组件
- `NotificationTab.swift`：新增，设置页第 5 个 Tab
- `AppSettings.swift`：新增 5 个通知相关字段；DisplayMode 枚举重命名 single→text/scroll→image + 自定义 Codable init(from:) 兼容旧值
- `AppDelegate.swift`：通知权限请求 + 退出时清理 pending 通知
- `RSSTab.swift`：Picker 标签改为"文本流"/"图片流"；新增源默认 .text；新增上移/下移排序按钮 + 无障碍标签
- `PopoverContent.swift` / `DashboardWindow.swift`：新增 expandedRSSSourceIDs/rssLoadedCounts 状态 + sticky 折叠条 + RSSWaterfallView 传参；收起条顺序改为匹配 rssSources 数组顺序
- `DisplayModeMigrationTests.swift`：新增，覆盖旧值/新值/未知值/数组完整性测试
- `RSSTab.swift`：移除 maxSelected 上限逻辑 + 推荐列表按分类分段 + 已订阅/未订阅分组 + 拖拽实时预览排序 + 串行可取消推荐验证面板（进度/重试/汇总）
- `RSSValidationService.swift`：新增，串行可取消推荐验证引擎，区分 blocked/invalidURL/cancelled/networkError/notRSSFeed/success 六种结果，支持重试与汇总统计
- `BottomBar.swift`：新增 batchProgress 进度显示
- `NewsSection.swift`：padding 16→14 适配 400px 宽度

---

## v1.4.2 — Provider 连接修复 & 错误诊断增强

### 🔐 安全修复

- **IOPlatformUUID 日志泄露修复**：移除系统日志中的机器 UUID 明文输出，防止 AES 密钥派生材料泄露

### 🐛 Bug 修复

- **测试按钮保存后变灰修复**：保存 API Key 后测试按钮仍可点击，支持直接测试已保存的 key
- **测试连接 key 优先级修复**：测试连接时优先使用用户当前输入的 key，而非缓存中的旧 key
- **测试输入清理**：测试连接时对输入 key 调用 sanitizeUserInput，与保存流程保持一致
- **启动时 cachedAPIKey 竞态修复**：异步加载未完成时 fallback 读取加密文件，防止首次刷新跳过 AI 摘要；regenerateAISummary 同步修复
- **Opencode 响应格式自适应**：Anthropic 格式解码失败时自动回退到 OpenAI 格式，兼容代理端点格式差异

### 🔧 改进

- **错误诊断增强**：测试连接和 AI 总结失败时细分网络/解码/重试耗尽错误，显示具体提示信息（含 HTTP 状态码和重试次数）
- **安全日志**：所有错误路径添加 NSLog 输出（统一使用 localizedDescription，不泄漏敏感数据）

---

## v1.4.1 — 平台兼容 & 健壮性增强

### 🐛 Bug 修复

- **1Password Apple Silicon 兼容**：支持 `/opt/homebrew/bin/op` 路径，修复 M1/M2/M3 Mac 上 1Password 集成不可用
- **AI 摘要动画竞态修复**：状态变更时取消旧动画 Task，防止快速切换导致文本混合显示

### 🔧 改进

- **更新校验纵深防御**：删除 SHA256 回退路径，统一使用 GitHub API digest 字段
- **Markdown 剥离修正**：重写粗体/斜体正则，正确清理逐字动画中的 Markdown 标记
- **RSS 警告视觉区分**：私有 IP 警告显示橙色而非红色
- **版本兜底值同步**：AppVersion 硬编码兜底更新至 1.4.0

---

## v1.3.6 — Bug 修复 & 健壮性增强

### 🐛 Bug 修复

- **API Key 启动同步加载**：确保定时器触发时 API Key 已就绪，防止首次定时刷新时因 Key 未加载而跳过 AI 摘要
- **Dashboard force unwrap 修复**：修复 Dashboard 窗口中 `orchestrator` 的强制解包，消除潜在的崩溃风险
- **AI 摘要逐字动画取消支持**：将 `Task.isCancelled` 检测改为 `try/catch` 模式，正确响应 Task 取消信号
- **AI 摘要状态数据一致**：新增 `aiSummaryItems` 属性追踪摘要所用的新闻条目，替代实时计算，避免数据不一致

### 🔧 改进

- **AI 摘要重试指数退避**：重试间隔改为指数增长（1s → 2s → 4s），捕获最后一次 HTTP 错误并输出详细信息
- **AISummaryService 错误诊断增强**：在重试全部失败时返回具体 HTTP 状态码，便于定位问题
- **NewsOrchestrator 日志增强**：获取数据源失败时增加 `NSLog` 输出，方便调试

---

## v1.3.5 — 安全加固 & 架构优化

### 🔐 安全增强

- **SHA256 代理验证修复**：修复代理验证逻辑，确保下载完整性校验
- **SSRF 防护加固**：增强服务端请求伪造防护，限制内网访问
- **HTML on* 事件属性纵深防御**：清理 HTML 内容中的危险事件属性，防止 XSS 攻击

### 🏗️ 架构优化

- **HTTPClient 提取**：将网络请求逻辑抽取为独立 HTTPClient 模块，提升可测试性
- **AISummaryParser 拆分**：AI 摘要解析器独立封装，职责单一化
- **并行刷新支持**：多数据源（微博/B站/RSS）可并行请求，提升加载速度
- **SHA256 hash 校验**：下载文件完整性验证机制
- **测试框架搭建**：引入单元测试基础设施

### 🐛 稳定性修复

- **@MainActor 线程安全修复**：确保 UI 更新在主线程执行
- **@Published 线程问题修复**：修复属性发布器的线程竞争问题
- **[weak self] 循环引用修复**：消除潜在的内存泄漏
- **缓存清除逻辑优化**：改进缓存过期和清理策略
- **applyCachedState 状态管理**：优化启动时缓存状态恢复

### ♿ 无障碍

- **无障碍支持增强**：提升 VoiceOver 兼容性
- **动画优化**：改进过渡动画流畅度
- **Magic Numbers 提取**：将硬编码常量提取为可配置参数

---

## v1.3.2 — 自动刷新正文消失修复

### 🐛 Bug 修复

- **修复自动刷新时 AI 摘要只显示标题、不显示正文的问题**：部分 AI 模型会将标题和正文输出在同一行（`【标题】正文内容`），解析器未能正确提取 `】` 后的正文文本，导致段落内容被丢弃、新闻源角标也随之消失。现已修复为正确提取同行内的正文。
- **防止空段落产生**：恢复段落内容空白检查，避免在标题后紧接引用行时产生只有标题没有正文的无效段落。

---

## v1.3.1 — AI 摘要模板框架 & 引用编号源链接

### ✨ 新功能

- **AI 摘要模板框架**：将 AI prompt 从脆弱的 `##` Markdown 格式升级为 `【标题】` 固定模板框架。AI 只需往预设结构中填充内容，不再依赖不稳定的 Markdown 解析。标题用原生 SwiftUI 粗体渲染，正文仅保留内联加粗，版面更稳定。
- **引用编号源链接角标**：每段 AI 摘要末尾标注 `[#N]` 引用编号，100% 确定性地映射到原始新闻。鼠标悬停段落时右上角浮现毛玻璃胶囊角标，点击即可跳转源新闻链接。替代了原有概率性关键词匹配，准确率从不确定提升至完全可靠。
- **段落间分隔线**：不同主题之间有视觉分隔，层次清晰。
- **双语 README**：中英双语项目说明，带状态徽章、AI 提供商对比表格、搜索关键词区段，提升 GitHub 可发现性。
- **MIT 开源协议**：随附完整 LICENSE 文件。

### 🐛 Bug 修复

- 修复截断摘要（摘要可能不完整）时逐字动画首帧空白的问题
- 修复摘要无法解析时回落路径直接显示原始 `[#N]` 引用标记
- 修复鼠标悬停时多来源角标横向溢出布局
- 修复旧 `##` Markdown 缓存数据在升级为 `【】` 模板后无法解析的向后兼容问题

### 🔧 改进

- `AISummaryService.swift`: prompt 升级为 `【标题】` + `引用：[#N]` 模板框架；AI 自主挑选 3–5 个最重要话题，总字数 ≤ maxWords 硬约束
- `AISummaryCard.swift`: `parseSections` 按行扫描 `【` 和 `#` 标记，同时兼容新旧格式；`SectionRow` 改用原生 SwiftUI 控件替代 Markdown 布局
- `DashboardWindow.swift`: 消除约 90 行重复解析代码，复用共享解析函数
- `AboutTab.swift`: 新增 GitHub 链接、AI 提供商列表、项目元信息和搜索关键词
- `PopoverContent.swift`: 传入新闻条目列表以支持引用编号映射

---

## v1.3.0 — Dark Mode Fix & UI Polish

### 🐛 Bug Fixes

- **Fix dark mode appearance setting not applying**: Settings → General → Appearance → Dark/Light now correctly applies to all windows (popover, dashboard, settings).
- **Fix "Follow System" option**: Detects current macOS appearance immediately; switches in real-time without app restart.

### ✨ Improvements

- Use `NSApp.effectiveAppearance` instead of `@Environment(\.colorScheme)` for accurate system appearance detection.
- Add `AppleInterfaceThemeChangedNotification` listener for real-time system appearance changes.
- Extract `AdaptiveColorSchemeModifier` to unify dark mode across 3 views via `.adaptiveColorScheme()`.

### 🔧 Technical

- `AppSettings.swift`: Add `resolvedColorScheme: ColorScheme?` computed property mapping `"system"/"light"/"dark"` to SwiftUI enum.
- `View+Glass.swift`: Add `AdaptiveColorSchemeModifier` + `.adaptiveColorScheme()` extension.
- Branch: `feature/v1.3.0`
