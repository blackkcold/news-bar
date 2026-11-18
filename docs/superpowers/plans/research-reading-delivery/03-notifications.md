# 阶段 3：研究主动送达

## 目标

复用现有 macOS 通知权限、事件通知策略、小时/每日摘要、研究版本与工作台关联；让事件快讯、研究报告和更正使用同一事件身份协调，记录实际提交状态，支持启动恢复、前台阅读抑制和可选摘要合并。点击通知分别回到原文、临时报告或报告版本差异。保留旧通知 payload 和微博通知行为。

## 文件范围

- 通知内容、提交与状态：`Services/NotificationService.swift`、`Models/NotificationDigest.swift`、`Services/NotificationClickRouter.swift`；新增通知投递账本/研究送达策略，保存稳定请求 ID、语义键、通道、状态与有限重试次数，并在启动时与系统待发/已送达请求核对。
- 事件与研究协调：`Services/Workspace/WorkspaceNotificationCoordinator.swift`、`Services/Workspace/WorkspaceAutomationService.swift`、`Services/Events/NewsEventController.swift`。复用 `NewsEvent.notificationKeys/lastNotifiedFingerprint`、`WorkspaceResearchCausalToken` 和 `WorkspaceReportVersion`；事件身份以 ingest 后持久化 `eventID` 为准。事件候选仍先过既有证据/兴趣策略，官方来源资格只读取 `verificationBasis == .officialOriginalFields`，不据此扩张其他主张。
- 摘要阅读与点击：`Services/NewsNavigationRouter.swift`、`Views/Dashboard/NewsDigestSheet.swift`、`AppDelegate.swift` 的通知 delegate 段。摘要沿用既有 1–3 条上限和点击手势；旧 `news` / `newsEvent` / `research` / `burst` payload 继续解析。
- 报告更正阅读：`Views/Workspace/TransientResearchReportView.swift` 与 `AppDelegate.openTransientResearch(...)`。外部更新只产生“新版已就绪”提示，旧版正文与滚动位置保留；用户主动查看变化或点更正通知时再定位新旧版本。所有异步解析完成后先校验 revision，再写入 record/event/version ID。
- 偏好：新增独立的 `researchNotificationsEnabled` 与默认关闭的 `researchNotificationDetailedPreviewEnabled` 存储/UI，放在研究提醒设置扩展文件中；不复用“自动研究”或旧 `researchNotificationShowsSummary` 作为新锁屏披露授权，不改并行阶段正在编辑的 `AppSettings.swift`、`NewsOrchestrator.swift`。

## 投递规则

1. 每次投递先持久化唯一意图和稳定请求 ID；系统接受后写为 accepted，明确失败标 failed 并仅在通道仍启用、事实仍新鲜且重试预算内重试。状态为 submitting 的重启恢复需先查询系统待发/已送达 ID；查到即确认，查不到则标 unknown，不盲目重发。用户已读单独记账，不等同系统接受。
2. 事件去重沿用 `eventID + change + NewsEventSemanticFingerprint`。研究仅在 ready/partial 报告含可定位 HTTPS 来源、逐字核验引文且支持或反驳关联主张时有资格送达；与已归档版本的主张状态无变化时跳过。实质变化只取状态或关键主张变化；“更正”必须精确对应此前已提交版本的同一主张支持↔反驳转换，不因无关的 refutes 条目升级。研究去重沿用 `eventID/recordID + WorkspaceResearchCausalToken`；同一报告造成的事件进展和研究完成合并为一次。先检查 `newsEventNotificationsEnabled`、研究提醒偏好、归档和当前版本，再提交系统请求。
3. 实质更正优先即时提醒。普通快讯/首份深研/背景补充进入当前已启用的小时或每日摘要；新闻与研究合计仍不超过 `pushCount`（1～3 项），先放更正、将影响下一决策的实质变化和首份有价值报告，再用普通新闻补位。同一事件若新闻已占一位，研究操作附在该新闻行，不重复占位。无摘要通道时，只有对应事件或研究提醒仍开启才发送单条；关闭一个通道不得借另一通道补发同类提醒。
4. 混合摘要仍使用现有摘要 sheet；每个研究项携带 eventID、recordID、报告版本和原文 URL，支持从列表直接打开报告或原文。单条普通新闻直达原文，研究通知直达报告，更正通知直达可比较的版本。前台正在读同一 event/report 且 app active 时抑制 banner/声音；现有报告视图接收版本更新并显示行内提示。
5. 默认通知只显示安全主题和通用的“有新的核验结果”。详细结论通过新的独立默认关闭开关明确开启；旧 `researchNotificationShowsSummary` 的默认真值不视为允许扩大的锁屏披露。高风险主题使用通用标题/正文，内容先清理 HTML 并限制长度。
6. 活动任务进度仍不通知。临时报告展开进度后，复用 `ResearchRun.progressFacts` 中有 URL 的已定位来源、可定位原句与已支持主张；没有经验证据的普通阶段计数不提升为通知事实。

## 验收

- 同一语义版本最多获得一次有声投递资格；快讯与报告乱序到达也能按因果 token 合并，更正使用独立且可追溯的版本键。
- 明确失败、成功接受和重启后的未知结果可区分；恢复不会把未知结果盲目发第二次，旧 request ID 能在系统列表中对账。
- 研究通知关闭、事件提醒关闭、摘要分别开/关、权限拒绝、归档和 app 前台正在读的组合均遵守对应通道，不互相回退补发。
- 原小时/每日摘要按原配置合计 1～3 项；新闻与研究合计计数，多条研究项在原摘要 sheet 中逐项进入原文或临时报告。同事件新闻行提供研究/更正入口而不重复计数。事件去重数、系统接受的请求数、已读数、摘要请求数分别统计。
- 默认正文不含报告结论；只有新详细预览开关显式开启后才显示经核验且范围受限的一句结论。旧通知仍能解析，旧新闻点击与微博类别/动作不变。
- 研究通知准入仅计入引用主张的可定位、逐字核验来源；同一主张状态未变的背景补充不进入摘要，只有已提交旧主张的真实反转能进入更正通道。自动研究的兼容 notifier 走同一门槛和总开关。
- 新版发布不替换读者正在看的旧版内容；行内“查看变化”与更正通知可打开新旧版本比较，关闭报告回到原来窗口位置。
- 不在本阶段修改选题、来源路由或 `AppSettings.swift` / `NewsOrchestrator.swift`；不运行测试、专项评测或构建，由主代理统一编译。
