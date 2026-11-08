# 微博关注监控：落版方案

- 基线：`v2.16.3`（`main`，`e9ab878`）
- 状态：方案定稿，待实现
- 范围：macOS 本地，单机；不做手机推送、不做外部服务依赖
- 关联：现有微博热搜、阅读器登录态、UserNotifications、Dashboard

---

## 0. 决策摘要

| 项 | 决策 |
|---|---|
| 数据源 | 登录态 `weibo.com/ajax/statuses/mymblog` 为主；`m.weibo.cn` 与 HTML 为降级 |
| 调度 | 独立 due 队列；P0 120s / P1 300s / P2 900s，全抖动 + 令牌桶 |
| 通知 | 仅 macOS 本地通知；P0 全推，P1 关键词，P2 只进关注流 |
| 存储 | Application Support 下 JSON；每账号 200 条 / 30 天 |
| 手机 | **不做**。无 Bark / ntfy / Telegram / webhook |
| 外部服务 | **不接** RSSHub、第三方爬虫、代理池 |
| 应用退出 | 不做后台守护；只做登录项，退出即停 |
| 评论抓取 | P2 可选，不进入 P0/P1 关键路径 |
| 多账号 | 不支持。vault 里只有一份微博登录态 |

---

## 1. 背景与目标

### 1.1 场景

数码闲聊站这类博主会在盘中/深夜发关键信息，例如「一家厂商不做 Ultra 系列」，评论区再补充厂商名。这类信息价值高、时效短，靠手动刷主页必然漏。

NewsBar 已经是菜单栏常驻应用，且用户在阅读器里登录过微博，Cookie 已加密存进 `ReaderCookieVault`。这套方案只做一件事：**用这份登录态，低频、拟人地轮询指定博主，发现新帖就推 macOS 通知，并把帖子留在应用里可读。**

### 1.2 目标

1. 维护一份监控名单，支持优先级（P0/P1/P2）与通知模式（全部/关键词/仅关注流）。
2. 应用运行期间，P0 博主的新帖在 3 分钟内被发现并通知。
3. 轮询节奏不呈现固定周期，不制造并发尖峰，尽量降低限流与账号风险。
4. 登录态失效时自动降级并提示，不静默失败。
5. 新帖可在 Dashboard 的「关注」流里阅读，点击通知直接落到阅读器。
6. 所有数据留在本机，不上传、不接第三方。

### 1.3 成功标准

- 3 个 P0 账号连续跑 24 小时：新帖发现延迟 p95 ≤ 3 分钟，重复通知 0 条。
- 8 个 P0 + 20 个 P1：平均请求 ≤ 10 次/分钟，硬上限不超过 15 次/分钟。
- 置顶微博误报 0 次；首次添加账号补推 0 条。
- 收到 429/418 后，该账号 1 小时内不再发请求；全局熔断生效。
- 应用重启后监控基线不丢，启动首分钟请求不超过 3 次。

---

## 2. 非目标

- **不做手机推送**，不接 Bark、ntfy、Telegram、飞书、企业微信。
- **不做服务端**，不引入云端轮询或跨设备同步。
- **不做全站关键词监控**，只监控名单内账号。
- **不做历史回溯**，最多补抓 page 2；更早的帖子不追。
- **不追踪编辑/删除**，微博改稿或删帖不会触发通知。
- **不做 IP 轮换、多账号池、TLS 指纹伪造**。收益小、风险大。
- **不承诺不漏**。这是「尽力而为」的本地轮询，不是微博官方推送。
- P0/P1 不做评论抓取；评论区内容通过点击通知进阅读器查看。

---

## 3. 现状复核

### 3.1 可直接复用

| 设施 | 位置 | 用途 |
|---|---|---|
| 60 秒全局 tick | `AppDelegate.schedulerTick`（`AppDelegate.swift:113-125`） | 监控调度挂载点 |
| Cookie 真源 | `ReaderCookieVault.cookies(matching:)` / `cookies(forInjectionHosts:)`（`ReaderCookieVault.swift:244,261`） | 读取 `.weibo.com` 登录态 |
| Cookie 门面 | `BrowserDataController.cookiesForInjection(host:)`（`BrowserDataController.swift:238`） | 避免多实例缓存互相覆盖 |
| Cookie→Header | `ReaderImageFetchPolicy`（`ReaderImageFetchPolicy.swift:35-57`） | 现成的 `HTTPCookie.requestHeaderFields(with:)` 用法 |
| 通知授权/分类 | `NotificationService`（`NotificationService.swift:48-81,114-122`） | 新增 category 与投递 |
| 点击路由 | `NotificationClickRouter.route`（`NotificationClickRouter.swift:29-67`） | 纯函数，加一个 case 即可 |
| 设置持久化 | `AppSettings` 各属性 `didSet` 写 `UserDefaults` | 新增监控偏好 |
| 原子写盘 | `PrivateFile` | `monitor.json` / `posts/*.json` |
| 测试隔离 | `Support/TestIsolation.swift` | 重定向 App Support 与 UserDefaults |
| 微博请求形态 | `HTTPClient.Config.weibo`（`HTTPClient.swift:14-23`） | UA/Referer 参考，**不复用 session** |

### 3.2 必须新建

- 微博用户时间线客户端（仓库目前只有热搜，无 `uid` 维度）。
- 每账号状态与帖子存储。
- 事件驱动的通知入口（现有三条链路都是摘要/日历/研究完成）。
- 模糊调度器与请求预算。
- 监控设置页与 Dashboard 关注流。
- 登录项（`SMAppService`）。现有 `launchAtLogin` 只是设置项，没有实现。

### 3.3 硬约束

1. **应用不运行就没有轮询**。macOS 本地通知无法在进程退出后由我们自己触发。
2. **本地通知不保真**。专注模式、勿扰、权限被拒都会吞；`.timeSensitive` 需要 entitlement，本方案不改签名能力。
3. **vault 只有一份微博登录态**。换账号会覆盖，不能同时监控两个账号视角。
4. **Cookie 域不通用**。`.weibo.com` 的 `SUB` 不自动对 `m.weibo.cn` 生效。
5. **后台 timer 会被 App Nap 压**。调度必须以 `nextDueAt` 为准，tick 只负责「看一眼」。

---

## 4. 总体架构

```
AppDelegate（60s tick，tolerance 5s）
   │
   ├─ NewsOrchestrator（现有热搜/RSS，不改）
   │
   └─ WeiboMonitorScheduler.tick(now)
        ├─ WeiboPollPlanner          // 纯函数：due / 抖动 / 夜间 / 自适应
        ├─ WeiboRequestBudget        // 令牌桶 + 硬窗口
        ├─ WeiboUserFeedService      // 抓取 + 解析 + 降级
        │    └─ BrowserDataController → ReaderCookieVault
        ├─ WeiboRiskSignal           // 响应分类
        ├─ WeiboMonitorStore         // monitor.json + posts/<uid>.json
        ├─ WeiboAlertPolicy          // 分级 + 聚合 + 静音 + 上限
        │    └─ NotificationService.sendWeiboAlert
        └─ NotificationCenter .weiboMonitorChanged
             └─ Settings / Dashboard
```

职责边界：

| 组件 | 只做 | 不做 |
|---|---|---|
| `WeiboPollPlanner` | 算下一次 due、抖动、夜间、自适应 | 不发请求、不读写盘 |
| `WeiboRequestBudget` | 令牌桶、硬窗口、全局熔断 | 不关心账号 |
| `WeiboUserFeedService` | 单账号抓取与解析 | 不去重、不通知 |
| `WeiboRiskSignal` | 把响应/异常分类 | 不决定退避时长 |
| `WeiboMonitorStore` | 账号与帖子持久化 | 不做业务判断 |
| `WeiboMonitorScheduler` | 编排、状态机、退避 | 不解析 JSON |
| `WeiboAlertPolicy` | 决定「推不推、推几条、什么时候推」 | 不投递 |
| `NotificationService` | 投递与分类注册 | 不做业务过滤 |

---

## 5. 数据源

### 5.1 分层

| 层 | 端点 | 依赖 | 用途 |
|---|---|---|---|
| T0 主 | `GET https://weibo.com/ajax/statuses/mymblog?uid=<uid>&page=1&feature=0` | `.weibo.com` 登录态 | 首选；返回 `data.list[]` |
| T1 备 | `GET https://m.weibo.cn/api/container/getIndex?type=uid&value=<uid>&containerid=107603<uid>` | `.weibo.cn` 登录态或匿名 | 增量 `since_id`；移动端 |
| T2 兜底 | `GET https://m.weibo.cn/u/<uid>` | 匿名 | 解析 HTML 内嵌 JSON |
| — | 不接外部 RSSHub / 爬虫 | — | 见 §5.4 |

长文单独补：`GET https://weibo.com/ajax/statuses/longtext?id=<mid>`，仅对 P0 或命中关键词的帖子执行一次。

### 5.2 端点探针（实现第 0 步）

在写产品代码前，用 30 分钟验证 4 组组合，产出脱敏 fixture：

1. T0 + 登录 Cookie。
2. T0 无 Cookie。
3. T1 + `.weibo.cn` Cookie。
4. T1 无 Cookie。

记录：状态码、`ok` 字段、`data.list`/`data.cards` 结构、是否有置顶字段、长文标记、风控文案、响应时间。每组最多 3 次请求，间隔 ≥ 2 秒。

**探针结果决定主路径**。如果 T0 在登录态下稳定，T1/T2 只做降级；如果 T0 也返回 `ok:0`，先解决登录态，不要硬上。

### 5.3 Cookie 域

- T0 只使用 domain 匹配 `.weibo.com` 的 Cookie；`SUB`、`SUBP`、`SSOLoginState` 必须完整。
- T1 只使用 domain 匹配 `.weibo.cn` 的 Cookie。用户只在 `weibo.com` 登录过时，T1 视为匿名。
- 不做 Cookie 域重写。伪造域会让服务端看到不一致的会话，反而更容易被风控。
- 每批请求前从 vault 读一次快照；检测 `SUB` 是否存在，决定 `loggedIn` / `anonymous`。

### 5.4 不采用的外部方案

| 方案 | 不采用原因 |
|---|---|
| 自建 RSSHub | 需要常驻 Docker；公共实例不稳；延迟 5–30 分钟，达不到 3 分钟目标 |
| 外部 Python 爬虫 + 文件桥 | 多一套运行时；定时任务延迟 5–15 分钟；实时性最差 |
| 关注流合并轮询 | 理论可把 N 个请求压成 1 个，但依赖「最新微博」接口的排序与完整性，留作 P2 探针验证 |
| 手机推送 | 明确不做 |

---

## 6. 轮询调度：模糊与预算

### 6.1 原则

**混淆时间，不混淆身份。**

- 不轮换 UA、不加随机 query 参数、不伪造 TLS 指纹——这些是爬虫特征。
- 同一个 UA、同一条长连接、同一个账号，只是访问时刻不规律。
- 所有随机都来自可注入的 RNG，测试可复现。

### 6.2 分层模糊

| 层级 | 手段 | 默认参数 |
|---|---|---|
| 账号相位 | `hash(uid)` 决定首次偏移 | `U(0, base)` |
| 周期间隔 | 基准 × `U(0.8, 1.3)` | P0 120s → 96–156s |
| 全局节拍 | 令牌桶 + 串行间隔 | 软 10/min，硬 15/min；请求间 400–1200ms |
| 队列顺序 | 每轮 shuffle（同优先级内） | — |
| 空转 | P1/P2 随机跳过一轮 | 5–8% |
| 夜间 | 分时段降频 | 00:30–07:30：P0 600s，P1/P2 暂停 |
| 自适应 | 无更新降频 / 新帖加密 | 7 天无帖 → ×4；新帖 → 90s × 10 分钟 |
| 退避 | 全抖动指数退避 | 2/5/15/60 分钟 × `U(0.8, 1.2)` |
| 熔断 | 全局风控信号 | 3 个账号命中 → 暂停 30–60 分钟 |
| 唤醒 | 逾期打散 | 20s/账号，上限 5 分钟 |

### 6.3 公式

```
base = interval(priority)                  // 120 / 300 / 900 秒
     × nightFactor                         // P0 5.0；P1/P2 暂停
     × lowPowerFactor                      // 2.0
     × dormantFactor                       // P1/P2 4.0，封顶 1800s；P0 2.0，封顶 600s
delay = base × U(0.8, 1.3)
nextDueAt = now + max(90s, delay)
```

热窗口：

```
if 最近 10 分钟内发现过新帖:
    base = min(base, 90s)
    额外请求不超过 6 次
```

### 6.4 请求预算

- 令牌桶：容量 6，补充 10 次/分钟（约 0.1667 次/秒）。
- 硬窗口：任意 60 秒内不超过 15 次。
- 预算不足时：按 P0 → P1 → P2 顺序保；P1/P2 顺延 30–60 秒；P0 最多顺延 5 分钟。
- 不并发：单账号串行，全局同一时刻最多 1 个在途请求。

典型预算：

| 名单 | 基准请求量 |
|---|---|
| 8 个 P0 @120s | ≈ 4.0 次/分钟 |
| 20 个 P1 @300s | ≈ 4.0 次/分钟 |
| 10 个 P2 @900s | ≈ 0.7 次/分钟 |
| 合计 | ≈ 8.7 次/分钟（夜间 ≈ 0.8） |

### 6.5 特殊场景

| 场景 | 行为 |
|---|---|
| 首次启动 | 30–120 秒随机暖机；首分钟最多 3 次请求 |
| 系统唤醒 | 逾期账号 shuffle；前 3 个立即，其余按 20s/账号打散，5 分钟内打完 |
| 应用从后台转前台 | 同唤醒处理，不立刻全量补 |
| 低电量模式 | 所有间隔 ×2 |
| 离线 | 暂停；网络恢复后按唤醒打散 |
| 手动「立即检查」 | 绕过 due，但仍扣预算；同一账号距上次请求 ≥60 秒 |
| 用户正在看关注流 | 不改变调度；只影响通知是否弹横幅 |

### 6.6 调度状态机

```
idle → due → budgetWait → fetching → success/failure
                              │
                              ├─ success → scheduleNext
                              ├─ network → backoff
                              ├─ rateLimited → pause 1h
                              ├─ authExpired → anonymous + prompt
                              └─ parseChanged → disable tier + banner
```

所有状态落盘，重启不重置 `nextDueAt`、`lastSeenMid`、`consecutiveFailures`。

---

## 7. 抓取与解析

### 7.1 请求配置

| 项 | 值 |
|---|---|
| Session | `URLSessionConfiguration.ephemeral`，`httpCookieStorage = nil`，`httpShouldSetCookies = false` |
| 连接数 | `httpMaximumConnectionsPerHost = 1` |
| 超时 | 12 秒（请求）/ 20 秒（资源） |
| 等待网络 | `waitsForConnectivity = false` |
| UA | macOS Safari 17 桌面 UA，固定不轮换 |
| Accept | `application/json, text/plain, */*` |
| Accept-Language | `zh-CN,zh;q=0.9` |
| Referer | `https://weibo.com/u/<uid>` |
| X-Requested-With | `XMLHttpRequest` |
| Origin | `https://weibo.com` |
| Cookie | 从 vault 读取；先按 domain/path 过滤，再用 `HTTPCookie.requestHeaderFields(with:)` 拼接 |

不使用 `HTTPClient.sharedSession`：它显式禁用 Cookie，且是全局共享会话。

### 7.2 解析字段

| 字段 | 用途 |
|---|---|
| `idstr` / `mid` | 去重主键 |
| `bid` | 生成 `https://weibo.com/<uid>/<bid>` |
| `text_raw` | 通知正文与列表展示 |
| `created_at` | 新帖判定 |
| `isTop` | 置顶排除 |
| `isLongText` | 是否补长文 |
| `retweeted_status` | 纯转发识别 |
| `pic_ids` / `pics` | 图片（只存 URL，不预下载） |
| `user.screen_name` | 首次添加时补全昵称 |

`created_at` 解析失败时，用 `mid` 的时间戳兜底（微博 mid 高位包含时间），不要直接丢弃。T0 的时间格式是 `EEE MMM dd HH:mm:ss Z yyyy`，用 `en_US_POSIX` + 固定时区解析；T1 只有 `MM-dd`，按当前年份补全，跨年时用 `mid` 时间戳校正。

### 7.3 长文、转发、图片

- **长文**：`isLongText == true` 且（P0 或命中关键词）才补 `longtext`；结果缓存在帖子记录里，不重复请求。
- **纯转发**：`text_raw` 为空且只有 `retweeted_status` → 默认跳过；带评论的转发按普通帖处理。
- **图片**：只存 `imageURLs`，阅读器打开时再加载。不把图片写进通知附件。

### 7.4 T2 HTML 兜底

- 请求 `https://m.weibo.cn/u/<uid>`，匹配 `var $render_data = ...` 或 `window.$render_data`，取其中的 `statuses`。
- 解析失败标记 `parseChanged`，不反复重试。
- T2 只用于「看得到就行」，不保证字段完整。

---

## 8. 去重、基线与补抓

### 8.1 新帖定义

```
isNew =
    mid ∉ seenMids
    && createdAt > lastCheckedAt - 10 分钟
    && !(isTop && createdAt < lastCheckedAt - 10 分钟)
```

三个条件缺一不可：

- 只用 `mid` 去重，防同一条多次出现。
- `createdAt` 窗口防置顶老帖和接口乱序。
- `isTop` 判断防「置顶了一条最近编辑过的老帖」。

`createdAt` 缺失时，退化为「`mid` 不在 seen 且 `mid` 大于 `lastSeenMid`」，并在日志里记一次 `dateMissing`。

### 8.2 首次添加

- 抓 page 1，全部写入 `seenMids`，`lastSeenMid` 设为最新一条。
- **不通知**。
- 可选「补推最近 N 小时」默认关闭；开启时最多补 2 小时，且只对 P0 生效。

### 8.3 补抓

```
if now - lastCheckedAt > 30 分钟
   && lastSeenMid 不在 page 1:
       抓 page 2
       if 找到 lastSeenMid:
           取它之后的所有帖子，按新帖流程处理
       else:
           gapSuspected = true
           以 page 1 最新一条为新基线
           不补推
```

- 最多两页，绝不翻第三页。
- `gapSuspected` 在设置页显示「可能漏抓」，用户打开关注流后清除。
- 睡眠 8 小时后唤醒，按这个流程处理，不制造 8 小时的通知洪水。

### 8.4 保留

- 每账号 `seenMids` 保留最近 100 条。
- 每账号帖子保留 200 条 / 30 天，先到先删。
- `gapSuspected` 只保留最近一次。

---

## 9. 风控信号、退避与熔断

### 9.1 信号分类

| 信号 | 判定 | 动作 |
|---|---|---|
| 418 / 429 / 403 | HTTP 状态 | 该账号暂停 1 小时；全局冷却 15 分钟 |
| 正文含「访问过于频繁 / 请求过于频繁 / 请稍后再试」 | 文本匹配 | 全局熔断 30–60 分钟 |
| `ok:0` 且 `url` 含 `passport` / `login` | 登录失效 | 切匿名；一次性提示 |
| 返回 HTML 而非 JSON | 挑战页 | 全局冷却 30 分钟；记 `parseChanged` |
| 连续 3 次空 `data.list` | 可疑 | 降频到 2×；设置页黄灯 |
| 网络超时 / DNS 失败 | 网络 | 单账号退避；不熔断 |

### 9.2 退避

- 网络类：2 → 5 → 15 → 60 分钟，全抖动 `U(0.8, 1.2)`。
- 连续 5 次失败：暂停到应用重启或用户手动恢复，设置页红灯。
- 限流类：固定 1 小时 + `Retry-After`（如果有）取较大值，不加抖动以外的重试。
- **绝不立即重试**。失败后至少等 2 分钟。

### 9.3 全局熔断

```
10 分钟内 ≥3 个不同账号命中限流信号
  → circuitOpenUntil = now + U(30, 60) 分钟
  → 所有账号暂停
  → 冷却结束后只放 1 个请求试探
     成功 → 关闭熔断，恢复调度
     失败 → 熔断时长 ×2，重新计时
```

### 9.4 登录失效

- T0 返回 auth 信号 → 立即切 T1；T1 也失败 → 切 T2。
- 匿名模式只允许 P1/P2 以 15 分钟间隔运行；P0 暂停并在设置页显示「需要重新登录」。
- 提示只发一次：应用内横幅 + 一条低优先级通知；24 小时内不重复。
- 不自动打开登录页，不自动扫码。用户点「去登录」才打开阅读器。

---

## 10. 存储

### 10.1 路径

```
~/Library/Application Support/com.newsbar.app/WeiboMonitor/
├── monitor.json
└── posts/
    ├── <uid>.json
    └── ...
```

不放 Caches：缓存清理会丢监控基线。

### 10.2 `monitor.json`

```json
{
  "version": 1,
  "updatedAt": "2026-11-07T10:00:00+08:00",
  "users": [
    {
      "uid": "1234567890",
      "screenName": "数码闲聊站",
      "avatarURL": "https://...",
      "priority": "p0",
      "notifyMode": "all",
      "enabled": true,
      "addedAt": "2026-11-07T09:00:00+08:00",
      "lastSeenMid": "5123456789012345",
      "lastSeenAt": "2026-11-07T09:58:00+08:00",
      "seenMids": ["5123456789012345"],
      "nextDueAt": "2026-11-07T10:01:30+08:00",
      "lastCheckedAt": "2026-11-07T09:59:30+08:00",
      "lastSuccessAt": "2026-11-07T09:59:30+08:00",
      "consecutiveFailures": 0,
      "lastErrorKind": null,
      "pausedUntil": null,
      "gapSuspected": false,
      "stats": {
        "posts7d": 12,
        "lastPostAt": "2026-11-07T09:58:00+08:00"
      }
    }
  ]
}
```

### 10.3 `posts/<uid>.json`

```json
{
  "version": 1,
  "uid": "1234567890",
  "posts": [
    {
      "mid": "5123456789012345",
      "bid": "P1xYz",
      "text": "……",
      "createdAt": "2026-11-07T09:58:00+08:00",
      "fetchedAt": "2026-11-07T10:00:03+08:00",
      "isLongText": false,
      "isRetweet": false,
      "retweetText": null,
      "imageURLs": [],
      "url": "https://m.weibo.cn/detail/5123456789012345",
      "read": false
    }
  ]
}
```

### 10.4 写入

- 全部走 `PrivateFile` 原子写。
- 2 秒合并：同一轮多个账号的变更合成一次写。
- 文件权限 0600。
- 不存 Cookie、不存请求头、不存原始响应。
- 版本不匹配：备份为 `.bak`，尝试迁移；迁移失败则以空库启动并在设置页提示。

### 10.5 损坏恢复

- 读取失败 → 重命名为 `.corrupt-<timestamp>` → 用 `posts/` 重建 `seenMids` 与 `lastSeenMid`。
- 重建后第一轮按首次添加处理，不通知。

---

## 11. 通知

### 11.1 分类与动作

新增 `newsbar.weibo` category，注册时必须把现有 `newsbar.news`、`newsbar.research` 一起传给 `setNotificationCategories`（覆盖式）。

动作：

| Action | 行为 |
|---|---|
| `newsbar.weibo.open` | 打开阅读器 |
| `newsbar.weibo.mute1h` | 该博主静音 1 小时 |
| `newsbar.weibo.markRead` | 标记该条已读 |

### 11.2 标识

- `requestIdentifier = "weibo-<mid>"`，同一条不会重复投递。
- `threadIdentifier = "weibo.<uid>"`，同一博主折叠。
- `userInfo = ["type": "weibo", "mid": ..., "uid": ..., "url": ...]`。

### 11.3 聚合

- 同一账号 45 秒窗口内多条 → 合并成一条：
  - 标题：`数码闲聊站 · 3 条新微博`
  - 正文：第一条前 80 字 + 「等 3 条」
- 单条：
  - 标题：`数码闲聊站`
  - 副标题：`新微博 · 16:52`
  - 正文：前 80 字（HTML 先消毒）
- 45 秒延迟对 2 分钟轮询几乎无感，但能避免连续爆料刷屏。

### 11.4 分级与上限

| 优先级 | 默认通知 |
|---|---|
| P0 | 每条都推 |
| P1 | 命中关键词才推；可在账号上改为「全部」 |
| P2 | 不发系统通知，只进关注流 |

- 单账号上限 6 条/小时；全局 20 条/小时。
- 超限后只更新菜单栏红点与关注流，不再发系统通知；下一小时恢复。
- 静音时段：P1/P2 在 23:30–08:00 不推；P0 照推。
- 系统专注模式可能吞掉通知，这是已知边界，不做绕过。

### 11.5 点击路由

`NotificationClickRouter` 新增：

```swift
case weibo(mid: String, uid: String, url: URL?)
```

处理：

1. 打开 Dashboard。
2. 用 `NewsNavigationRouter` 打开阅读器。
3. URL 优先用 `https://m.weibo.cn/detail/<mid>`；`bid` 存在时用 `https://weibo.com/<uid>/<bid>`。
4. 标记该条已读，刷新关注流未读数。

### 11.6 菜单栏与前台

- 菜单栏图标叠加红点 + 未读数；数量为 0 时恢复模板图。
- 打开关注流后清零。
- 前台且 Dashboard 正在显示关注流 → 不弹横幅，只插入列表。
- 权限被拒：设置页显示警告与「打开系统设置」按钮；不静默失败，日志记录 `authorizationDenied`。

### 11.7 不做的通知能力

- 不改 entitlements，不使用 `.timeSensitive` / `.critical`。
- 不使用 `content.badge`（`LSUIElement` 应用没有 Dock 图标）。
- 不做声音选择，统一 `.default`。

---

## 12. UI

### 12.1 设置 → 微博监控

新增 `SettingsPane.weiboMonitor`，布局：

```
┌ 微博监控 ─────────────────────────────┐
│ 总开关 [ ]   登录状态：已登录 / 匿名   │
│ [去登录]  [立即全部检查]               │
│                                        │
│ 账号列表                               │
│ ┌────────────────────────────────────┐ │
│ │ 数码闲聊站  P0 ▾  全部 ▾  ● 正常   │ │
│ │ 上次 09:59 · 下次 10:01 · 7天 12 条│ │
│ │ [立即检查] [静音1h] [删除]          │ │
│ └────────────────────────────────────┘ │
│                                        │
│ [+ 添加账号]  输入 UID 或主页链接       │
│ 高级：间隔 / 夜间 / 关键词 / 上限       │
└────────────────────────────────────────┘
```

状态灯：

| 颜色 | 含义 |
|---|---|
| 绿 | 最近一次成功，无异常 |
| 黄 | 连续失败 1–2 次 / 可能漏抓 / 匿名模式 |
| 红 | 连续失败 ≥3 次 / 登录失效 / 被限流暂停 |

添加账号：

- 支持 UID、`https://weibo.com/u/<uid>`、`https://m.weibo.cn/u/<uid>`。
- 昵称搜索不在 P0；P2 可选。
- 添加后立即抓一次做基线，不通知。

### 12.2 Dashboard → 关注

- 侧边栏新增「关注」，带未读数。
- 列表按账号分组，未读加粗；顶部筛选：全部 / 未读 / 只看 P0。
- 点击条目 → 右侧阅读器打开原帖。
- 顶部操作：全部已读、暂停监控 1 小时。
- 空状态：说明「在设置 → 微博监控里添加账号」。

### 12.3 Popover

P1 可选：一行 chip「关注 3」，点击打开 Dashboard 关注流。P0 不做，避免挤占现有布局。

---

## 13. 设置项与默认值

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `weiboMonitorEnabled` | Bool | false | 总开关 |
| `weiboMonitorNotifyEnabled` | Bool | true | 关掉后只进关注流 |
| `weiboMonitorP0Seconds` | Int | 120 | 最小 90 |
| `weiboMonitorP1Seconds` | Int | 300 | 最小 180 |
| `weiboMonitorP2Seconds` | Int | 900 | 最小 600 |
| `weiboMonitorNightEnabled` | Bool | true | 夜间降频 |
| `weiboMonitorNightStartMinute` | Int | 30 | 00:30 |
| `weiboMonitorNightEndMinute` | Int | 450 | 07:30 |
| `weiboMonitorPerAccountHourlyCap` | Int | 6 | 单账号通知上限 |
| `weiboMonitorGlobalHourlyCap` | Int | 20 | 全局通知上限 |
| `weiboMonitorKeywordNotifyEnabled` | Bool | true | P1 关键词通知 |
| `weiboMonitorKeywordList` | [String] | [] | 与新闻关键词分开 |
| `weiboMonitorBackfillHours` | Int | 0 | 首次添加补推，最大 2 |
| `weiboMonitorLoginItemEnabled` | Bool | false | 开机自启 |
| `weiboMonitorAuthAlertAt` | Date? | nil | 登录失效提示去重 |

账号列表不写 `UserDefaults`，只写 `monitor.json`。

---

## 14. 改动清单

### 14.1 新增

| 文件 | 职责 | 预估 |
|---|---|---|
| `Models/WeiboMonitorUser.swift` | 账号模型、优先级、通知模式、状态 | 120 行 |
| `Models/WeiboPost.swift` | 帖子模型、URL 构造 | 90 行 |
| `Services/WeiboPollPlanner.swift` | 纯函数调度：due、抖动、夜间、自适应 | 180 行 |
| `Services/WeiboRequestBudget.swift` | 令牌桶、硬窗口、全局熔断 | 120 行 |
| `Services/WeiboRiskSignal.swift` | 响应分类 | 100 行 |
| `Services/WeiboUserFeedService.swift` | T0/T1/T2 抓取与解析 | 320 行 |
| `Services/WeiboMonitorStore.swift` | JSON 持久化、合并写、恢复 | 220 行 |
| `Services/WeiboMonitorScheduler.swift` | 编排、状态机、退避 | 260 行 |
| `Services/WeiboAlertPolicy.swift` | 分级、聚合、静音、上限 | 160 行 |
| `Views/Settings/WeiboMonitorTab.swift` | 设置页 | 320 行 |
| `Views/Dashboard/WeiboMonitorFeedView.swift` | 关注流 | 280 行 |
| `Views/MenuBar/MenuBarBadge.swift` | 菜单栏红点合成 | 60 行 |

测试：

- `Tests/NewsBarTests/WeiboPollPlannerTests.swift`
- `Tests/NewsBarTests/WeiboUserFeedParserTests.swift`
- `Tests/NewsBarTests/WeiboMonitorStoreTests.swift`
- `Tests/NewsBarTests/WeiboAlertPolicyTests.swift`
- `Tests/NewsBarTests/WeiboRiskSignalTests.swift`
- `Tests/NewsBarTests/WeiboMonitorSimulationTests.swift`

### 14.2 修改

| 文件 | 改动 |
|---|---|
| `AppDelegate.swift` | tick 调用调度器；通知 delegate 加 `.weibo`；启动注册 category；登录项 |
| `NotificationService.swift` | 新增 category；`sendWeiboAlert` |
| `NotificationClickRouter.swift` | 新增 `.weibo(mid:uid:url:)` |
| `AppSettings.swift` | 新增 §13 的设置项与 `didSet` |
| `SettingsWindow.swift` | 新增 `.weiboMonitor` pane |
| `DashboardWindow.swift` | 侧边栏「关注」与详情切换 |
| `DashboardBrowseCatalog.swift` | 新增 `.weiboMonitor`（若采用 catalog 方案） |
| `Localized.swift` | 中英文案 |
| `scripts/build.sh` / `package-local.sh` | 如需 `SMAppService`，确认签名与 `Info.plist` |

不新增第三方依赖，不改 entitlements。

---

## 15. 可观测性

- `Logger(subsystem: "com.newsbar.app", category: "weibo-monitor")`。
- 每轮记录：账号数、请求数、成功/失败、预算剩余、熔断状态、耗时。
- 单条记录：`uid`、`tier`、`status`、`latencyMs`、`postCount`、`errorKind`。
- 不记录 Cookie、请求头、帖子全文。
- 设置页显示最近 20 条事件，便于用户自查。
- `RefreshLog` 增加一行本轮监控摘要，不写正文。

---

## 16. 测试计划

### 16.1 单元测试

| 测试 | 断言 |
|---|---|
| `WeiboPollPlannerTests` | 固定种子下 due 可复现；夜间因子正确；热窗口生效；休眠账号降频 |
| `WeiboRequestBudgetTests` | 10/min 软限、15/min 硬限；P0 优先；熔断半开 |
| `WeiboUserFeedParserTests` | T0/T1/T2 字段；置顶；长文；纯转发；缺字段；`ok:0`；HTML 挑战页 |
| `WeiboMonitorStoreTests` | 往返；版本迁移；损坏恢复；保留策略 |
| `WeiboAlertPolicyTests` | P0/P1/P2 分级；关键词；45 秒聚合；小时上限；静音时段 |
| `WeiboRiskSignalTests` | 418/429/403；风控文案；passport；空列表 |
| `NotificationClickRouterTests` | `.weibo` 路由；缺 `url` 时用 `mid` 兜底 |

### 16.2 24 小时仿真

用注入时钟和固定种子跑：

- 8 个 P0 + 20 个 P1 + 10 个 P2。
- 断言：平均 ≤10 次/分钟；任意 60 秒 ≤15 次；无同秒齐发；唤醒 5 分钟内打完；夜间请求量下降 ≥80%。
- 注入 429、超时、空列表，断言退避与熔断。

### 16.3 手动验收

1. 未登录：添加账号 → 匿名模式 → 提示登录。
2. 登录后：添加 3 个 P0 → 发一条测试微博 → 3 分钟内通知。
3. 置顶一条老微博 → 不通知。
4. 连续发 3 条 → 45 秒内合并为一条通知。
5. 点击通知 → 阅读器打开正确帖子。
6. 退出应用 → 无通知；重新打开 → 基线不丢。
7. 断网 10 分钟 → 恢复后不惊群。
8. 系统专注模式 → 通知被吞 → 菜单栏红点仍可看到。

---

## 17. 灰度与回滚

### 17.1 灰度

1. `weiboMonitorEnabled` 默认 false，只在设置页可见。
2. 第 1 天：1 个 P0，观察请求量、失败率、Cookie 状态。
3. 第 2 天：3 个 P0，确认延迟与误报。
4. 第 3 天：扩到完整名单。

### 17.2 回滚

- 关闭总开关：调度器停止，保留数据与已投递通知。
- 移除设置页入口：不影响现有功能。
- 删除 `WeiboMonitor/` 目录：完全重置。
- 无数据库迁移，无需回滚脚本。

---

## 18. 分期与工作量

| 阶段 | 内容 | 预估 |
|---|---|---|
| P0 | 模型 + 存储 + 调度器 + 抓取 + 通知 + 设置页 + 登录项 | 2 天 |
| P1 | Dashboard 关注流 + 关键词规则 + 夜间/自适应 + 红点 + 测试 | 1.5 天 |
| P2 | 关注流合并轮询（待探针）、评论抓取、昵称搜索 | 1 天 |
| 合计 | — | 4.5 天 |

P0 完成即可日常使用；P1 是体验补全；P2 是优化，不阻塞发布。

---

## 19. 风险与边界

| 风险 | 影响 | 缓解 |
|---|---|---|
| 微博接口变更 | 全部抓取失败 | T0/T1/T2 分层；探针 fixture；设置页红灯 |
| 账号被限流 | 延迟上升或暂停 | 低频、串行、抖动、熔断；只读 GET |
| Cookie 过期 | 降级匿名，P0 暂停 | 响应推断；一次性提示；不自动重登 |
| TLS 指纹与浏览器不同 | 可能被识别 | 不伪造；靠低频与真实会话降低概率 |
| App Nap | timer 漂移 | `nextDueAt` 为准；`beginActivity(.background)` |
| 通知权限被拒 | 收不到通知 | 菜单栏红点 + 关注流；设置页警告 |
| 应用退出/重启 | 停止监控 | 登录项；重启后暖机打散 |
| 置顶/编辑/删除 | 误报或漏报 | 置顶三重判断；不追踪编辑删除 |
| 多账号 | 只能一份登录态 | 明确不支持；换号覆盖 |
| 时区/夏令时 | 夜间窗口错位 | 用 `Calendar` 计算本地时间 |

**边界声明**：这是本地尽力而为的轮询，不是微博推送。应用不在运行时，不会产生任何新数据；系统专注模式可能吞通知；接口变更可能导致当天完全失效。这些都不属于 bug。

---

## 20. 验收标准

- [ ] `swift build` 通过，`swift test` 全绿。
- [ ] 设置页可添加/删除/暂停账号，状态灯正确。
- [ ] 3 个 P0 账号，新帖 p95 ≤ 3 分钟。
- [ ] 24 小时平均请求 ≤10 次/分钟，任意 60 秒 ≤15 次。
- [ ] 置顶老帖 0 误报，首次添加 0 补推。
- [ ] 同一条微博 0 重复通知；45 秒内多条合并。
- [ ] 点击通知打开正确帖子；菜单栏未读数正确。
- [ ] 429 后 1 小时内不再请求该账号；全局熔断生效并可半开恢复。
- [ ] Cookie 失效只提示一次，P0 暂停，P1/P2 降级匿名。
- [ ] 重启后 `nextDueAt`、`lastSeenMid` 保留，首分钟请求 ≤3 次。
- [ ] 日志不含 Cookie、请求头、帖子全文。

---

## 附录 A：端点与字段

### A.1 T0 `mymblog`

```
GET https://weibo.com/ajax/statuses/mymblog?uid=1234567890&page=1&feature=0
```

响应（截断）：

```json
{
  "ok": 1,
  "data": {
    "list": [
      {
        "id": 5123456789012345,
        "idstr": "5123456789012345",
        "mid": "5123456789012345",
        "bid": "P1xYz",
        "text_raw": "……",
        "created_at": "Fri Nov 07 09:58:00 +0800 2026",
        "isTop": 0,
        "isLongText": false,
        "pic_ids": [],
        "retweeted_status": null,
        "user": {
          "id": 1234567890,
          "screen_name": "数码闲聊站"
        }
      }
    ]
  }
}
```

### A.2 T1 `getIndex`

```
GET https://m.weibo.cn/api/container/getIndex?type=uid&value=1234567890&containerid=1076031234567890
```

响应（截断）：

```json
{
  "ok": 1,
  "data": {
    "cards": [
      {
        "card_type": 9,
        "mblog": {
          "id": "5123456789012345",
          "mid": "5123456789012345",
          "text": "……",
          "created_at": "11-07",
          "isLongText": false,
          "pics": []
        }
      }
    ],
    "cardlistInfo": {
      "since_id": "5123456789012345"
    }
  }
}
```

### A.3 长文

```
GET https://weibo.com/ajax/statuses/longtext?id=5123456789012345
```

响应取 `data.longTextContent`，做 HTML 消毒后入库。

### A.4 T1 的两个坑

- `created_at` 只有 `MM-dd`，没有年份；解析时按当前年份补全，跨年用 `mid` 时间戳校正。
- `since_id` 可能在 `data.cardlistInfo.since_id`，也可能在 `data.since_id`；两处都取，缺失时回退到 `lastSeenMid`。

---

## 附录 B：调度伪代码

```swift
func tick(now: Instant) async {
    guard settings.weiboMonitorEnabled,
          !systemSleeping,
          networkAvailable else { return }

    let due = store.users
        .filter { $0.enabled && $0.pausedUntil <= now && $0.nextDueAt <= now }
        .sorted { priorityRank($0) < priorityRank($1) }
        .shuffledWithinPriority(using: &rng)

    for user in due {
        guard budget.tryAcquire(now: now) else {
            user.nextDueAt = now + .seconds(rng.int(in: 30...60))
            continue
        }

        if user.priority != .p0 && rng.chance(0.06) {
            user.nextDueAt = planner.nextDue(for: user, now: now)
            continue
        }

        await fetchAndProcess(user)

        let gap = rng.int(in: 400...1200)
        try? await Task.sleep(for: .milliseconds(gap))
    }

    await store.flushIfNeeded(now: now)
}

func nextDue(for user: User, now: Instant) -> Instant {
    var base = settings.interval(for: user.priority)

    if isNight(now) {
        if user.priority == .p0 {
            base *= 5
        } else {
            return nextMorningStart(after: now)   // P1/P2 夜间暂停
        }
    }

    if lowPowerMode { base *= 2 }
    if user.isDormant { base = min(base * 4, 1800) }
    if user.inHotWindow { base = min(base, 90) }

    return now + .seconds(max(90, base * rng.double(in: 0.8...1.3)))
}
```

---

## 附录 C：存储示例

### C.1 目录

```
WeiboMonitor/
├── monitor.json
└── posts/
    ├── 1234567890.json
    └── 9876543210.json
```

### C.2 写盘策略

- 每轮结束统一 flush。
- 变更超过 2 秒未写 → 立即写。
- 应用退出前强制 flush。
- 写失败：保留内存状态，下轮重试；连续 3 次失败在设置页提示磁盘错误。

---

## 附录 D：术语

| 术语 | 含义 |
|---|---|
| P0 | 最高优先级，默认每条新帖都通知 |
| P1 | 标准优先级，默认只推关键词命中 |
| P2 | 低频，只进关注流 |
| 热窗口 | 发现新帖后的 10 分钟加密期 |
| 熔断 | 全局暂停抓取，避免越限越糟 |
| 基线 | 首次添加时记录的「已见」位置，不补推 |
