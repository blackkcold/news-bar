# 阶段 3：研究主动送达

## 目标

复用现有 macOS 通知权限、事件通知策略、小时/每日摘要、研究版本与工作台关联；让事件快讯、研究报告和更正使用同一事件身份协调，记录实际提交状态，支持启动恢复、前台阅读抑制和可选摘要合并。点击通知分别回到原文、临时报告或报告版本差异。保留旧通知 payload 和微博通知行为。

## 文件范围

- 通知内容、提交与状态：`Services/NotificationService.swift`、`Models/NotificationDigest.swift`、`Services/NotificationClickRouter.swift`；新增通知投递账本/研究送达策略，保存稳定请求 ID、语义键、通道、状态与有限重试次数，并在启动时与系统待发/已送达请求核对。
- 事件与研究协调：`Services/Workspace/WorkspaceNotificationCoordinator.swift`、`Services/Workspace/WorkspaceAutomationService.swift`、`Services/Events/NewsEventController.swift`。复用 `NewsEvent.notificationKeys/lastNotifiedFingerprint`、`WorkspaceResearchCausalToken` 和 `WorkspaceReportVersion`；事件身份以 ingest 后持久化 `eventID` 为准。事件候选仍先过既有证据/兴趣策略，官方来源资格只读取 `verificationBasis == .officialOriginalFields`，不据此扩张其他主张。
- 摘要阅读与点击：`Services/NewsNavigationRouter.swift`、`Views/Dashboard/NewsDigestSheet.swift`、`AppDelegate.swift` 的通知 delegate 段。摘要沿用既有 1–3 条上限和点击手势；旧 `news` / `newsEvent` / `research` / `burst` payload 继续解析。
- 报告更正阅读：`Views/Workspace/TransientResearchReportView.swift` 与 `AppDelegate.openTransientResearch(...)`。外部更新只产生“新版已就绪”提示，旧版正文与滚动位置保留；用户主动查看变化或点更正通知时再定位新旧版本。所有异步解析完成后先校验 revision，再写入 record/event/version ID。
- 增强提醒配额与自动补证择优：通知槽位保存在 `Services/NotificationDeliveryLedger.swift`；独立 `Services/Research/OfficialEvidenceCandidateScheduler.swift` 只接在 `NewsOrchestrator.handleAutomaticResearch` 的官方证据候选入口。手动研究不经过此入口。
- 偏好：新增独立的 `researchNotificationsEnabled` 与默认关闭的 `researchNotificationDetailedPreviewEnabled` 存储/UI，放在研究提醒设置扩展文件中；不复用“自动研究”或旧 `researchNotificationShowsSummary` 作为新锁屏披露授权，不改 `AppSettings.swift`。

## 投递规则

1. 每次投递先持久化唯一意图和稳定请求 ID；系统接受后写为 accepted，明确失败标 failed 并仅在通道仍启用、事实仍新鲜且重试预算内重试。状态为 submitting 的重启恢复需先查询系统待发/已送达 ID；查到即确认，查不到则标 unknown，不盲目重发。用户已读单独记账，不等同系统接受。
2. 事件去重沿用 `eventID + change + NewsEventSemanticFingerprint`。研究仅在 ready/partial 报告含可定位 HTTPS 来源、逐字核验引文且支持或反驳关联主张时有资格送达；与已归档版本的主张状态无变化时跳过。实质变化只取状态或关键主张变化；“更正”必须精确对应此前已提交版本的同一主张支持↔反驳转换，不因无关的 refutes 条目升级。研究去重沿用 `eventID/recordID + WorkspaceResearchCausalToken`；同一报告造成的事件进展和研究完成合并为一次。先检查 `newsEventNotificationsEnabled`、研究提醒偏好、归档和当前版本，再提交系统请求。
3. 实质更正优先即时提醒。普通快讯/首份深研/背景补充进入当前已启用的小时或每日摘要；新闻与研究合计仍不超过 `pushCount`（1～3 项），先放更正、将影响下一决策的实质变化和首份有价值报告，再用普通新闻补位。同一事件若新闻已占一位，研究操作附在该新闻行，不重复占位。无摘要通道时，只有对应事件或研究提醒仍开启才发送单条；关闭一个通道不得借另一通道补发同类提醒。
   - 研究/事件增强提醒另有独立的择优配额，不计入原生新闻候选，也不改变小时/每日新闻开关：滚动 60 分钟最多容纳 2 个不同事件/记录键；本地日历日先容纳 6 个普通重要事件，超出后只容纳重大进展或强时效更新，普通繁忙日最多 10 个不同键。严格准入的实质更正可突破小时与日上限。以 `eventID` 为键；事件 ID 缺失时用 `recordID`，两者都缺失时仅以稳定通知语义 ID 兜底。相同事件更新共享事件槽位，摘要中同事件只显示一个最高优先级落点。超额普通项目留在持久队列中，下一小时/每日摘要窗口仍可择优；报告仍可在工作台/阅读面板打开。该配额只限制增强提醒，不影响原生新闻推送配置。
   - 自动官方补证另在候选入口按滚动小时最多择优 2 个稳定事件键，允许少于 2 个或 0 个；按公共影响与现有候选优先级排序。额度在启动来源查询前持久占位，避免刷新频繁时重复拉取；未选中的候选留给后续时段。明确的手动研究不经过该调度器，也不受此限制。
   - 官方单源资格必须绑定到最近 24 小时内的 `officialOriginalFields` 证据和其明确关联、状态为 supported 的核心主张。通知标题/可选详情只显示该主张，并将点击 URL 设为该条官方证据 URL；不可把可能混有传闻的 `event.title`、聚合描述或 `alert.body` 归于官方证据。找不到新鲜且精确关联的主张时使用中性通知内容，不提升为已核验事实。
4. 混合摘要仍使用现有摘要 sheet；每个研究项携带 eventID、recordID、报告版本和原文 URL，支持从列表直接打开报告或原文。单条普通新闻直达原文，研究通知直达报告，更正通知直达可比较的版本。前台正在读同一 event/report 且 app active 时抑制 banner/声音；现有报告视图接收版本更新并显示行内提示。
5. 默认通知只显示安全主题和通用的“有新的核验结果”。详细结论通过新的独立默认关闭开关明确开启；旧 `researchNotificationShowsSummary` 的默认真值不视为允许扩大的锁屏披露。高风险主题使用通用标题/正文，内容先清理 HTML 并限制长度。
6. 活动任务进度仍不通知。临时报告展开进度后，复用 `ResearchRun.progressFacts` 中有 URL 的已定位来源、可定位原句与已支持主张；没有经验证据的普通阶段计数不提升为通知事实。

## 验收

- 同一语义版本最多获得一次有声投递资格；快讯与报告乱序到达也能按因果 token 合并，更正使用独立且可追溯的版本键。
- 明确失败、成功接受和重启后的未知结果可区分；恢复不会把未知结果盲目发第二次，旧 request ID 能在系统列表中对账。
- 研究通知关闭、事件提醒关闭、摘要分别开/关、权限拒绝、归档和 app 前台正在读的组合均遵守对应通道，不互相回退补发。
- 原小时/每日摘要按原配置合计 1～3 项；新闻与研究合计计数，多条研究项在原摘要 sheet 中逐项进入原文或临时报告。同事件新闻行提供研究/更正入口而不重复计数。事件去重数、系统接受的请求数、已读数、摘要请求数分别统计。
- 研究/事件增强提醒按 eventID（缺失时 recordID）计入独立滚动小时和本地日配额；普通日最多 6 个不同键，重大/强时效可扩展到 10 个，严格实质更正可再突破。配额溢出的普通项目不丢弃，后续摘要可再次择优，原生新闻 push switches 不受影响。后台官方补证每小时最多远程核验 2 个不同稳定候选键，少于两项时允许 0 项；显式手动研究不受此限。
- 官方单源的标题与可选详情仅能来自新鲜官方原始字段所支持的关联核心主张，点击落到同一证据 URL；无精确绑定时使用中性文案。
- 默认正文不含报告结论；只有新详细预览开关显式开启后才显示经核验且范围受限的一句结论。旧通知仍能解析，旧新闻点击与微博类别/动作不变。
- 研究通知准入仅计入引用主张的可定位、逐字核验来源；同一主张状态未变的背景补充不进入摘要，只有已提交旧主张的真实反转能进入更正通道。自动研究的兼容 notifier 走同一门槛和总开关。
- 新版发布不替换读者正在看的旧版内容；行内“查看变化”与更正通知可打开新旧版本比较，关闭报告回到原来窗口位置。
- 不在本阶段修改既有研究选题、内容来源路由或 `AppSettings.swift`；`NewsOrchestrator.swift` 只在自动官方补证调用点经过独立候选调度器，不更改显式手动研究路径。不运行测试、专项评测或构建，由主代理统一编译。
