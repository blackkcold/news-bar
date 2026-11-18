# 阶段 1：阅读增强、共享检索与可选进度

## 目标

让推荐/RSS/阅读器现有入口能显示并打开可信关联的研究报告；让 Dashboard 本地搜索与工作区报告索引相互可达；提供可关闭的轻量临时报告窗口，保留底层阅读位置。研究进度默认折叠，仅在用户展开时读取并显示已有任务阶段与计数。

## 文件范围

- 关联与检索：新增 `Services/Workspace/WorkspaceReaderResearchMatcher.swift`；修改 `Services/Workspace/WorkspaceSearchIndex.swift`、`WorkspaceSearchService.swift`、`Views/Workspace/ResearchWorkspaceModel.swift`。
- 阅读器与 Dashboard：`Views/Dashboard/ReaderResearchPanelModel.swift`、`ReaderResearchPanel.swift`、`NewsReaderView.swift`、`QuickSearchContent.swift`。
- 菜单栏和推荐卡：`Views/MenuBar/NewsItemRow.swift`、`RSSWaterfallView.swift`、`Views/Dashboard/RecommendationCardView.swift`。只加不改变原文点击目标的研究提示及报告打开回调，不增加 Dashboard/菜单栏入口。
- 共用提示：新增 `Views/Workspace/ResearchAssociationBadge.swift`，只为有可信报告或正在运行任务的文章绘制可点提示；角标在现有行/卡片内占用原有元信息空间。
- 显示偏好：在 `Views/Settings/ResearchSettingsSection.swift` 增加独立的阅读研究显示总开关；视图侧用 `@AppStorage("researchReadingEnabled")` 读取，避免与自动研究/通知通道和进度折叠设置混用。
- 临时报告窗口与入口：新增 `Views/Workspace/TransientResearchReportView.swift`；修改 `AppDelegate.swift`、`DashboardWindow.swift` 维护并路由到一个可复用的非模态报告窗口，并暴露 `openTransientResearch(recordID:eventID:)` 与 `isResearchTargetVisibleAndAppActive(eventID:recordID:)` 给通知阶段调用。
- 报告内容复用 `Views/Workspace/WorkspaceReportBody.swift`。如需新文案，追加至现有本地化资源，不改用户现有设置、摘要通道或搜索提交语义。

## 关联准入与行为

1. 读者可见的研究关联仅接受精确 `NewsItem.id`、规范化 URL，或已持久化的 Workspace event/report 成员关系；标题指纹只可用于候选发现，不得单独产生角标或“有深研”。
2. 搜索查询复用本地 Workspace 索引中的报告/证据，并与现有新闻、阅读历史和答案结果合并。新闻标题命中保留在前面；多个同事件报告版本按现有版本关系可展开。网页与 AI 搜索仍只在用户原有显式动作后执行。
3. `openTransientResearch(recordID:eventID:)` 打开/复用单一非模态阅读窗口；同一事件切换到最新可用报告，关闭仅关闭该窗口，底层 Dashboard、Reader、搜索词和选择保持原位。原 Workspace 管理窗口和入口不变。
4. 进度默认折叠且记住用户选择。阶段/计数仅在展开后显示，沿用现有 `ResearchRecord.run` 与上一份可用报告；关闭窗口只解绑视图，不取消研究任务。
5. 阅读研究显示总开关只影响文章标记、阅读器研究侧窗与读者本地搜索中的报告/证据命中；原文、工作台管理和通知通道各自维持原行为。
6. 通知阶段的可见性查询同时检查临时窗口和 Dashboard 当前选中的精确关联文章，并要求 `NSApp.isActive`；通知 delegate 只保留独立扩展位置。
7. 搜索结果继续让精确文章标题与原文动作排在最前。只有已索引结果的 `subjectID`、`recordID` 和报告/证据成员关系能证明同一身份时，才把报告版本、证据命中与可确定的转载合并为一条可键盘及 VoiceOver 操作的「研究记录」披露行；披露内容读取本地索引命中及 active 任务已有阶段，不默认展开或显示普通后台状态。读者侧窗和 Workspace 管理搜索共用小型分组/披露与身份规则；无可靠关联的命中保持独立，Workspace 的原始命中仍全部可从披露行访问。

## 验收

- 原推荐排序、RSS 顺序、标题打开原文、返回/搜索提交行为和卡片行高不变。
- 相同标题、同机构或仅背景引用不会显示研究提示；精确身份或确认成员关系可以打开对应报告。
- 阅读器当前页研究概览显示结论、核验时间和依据入口；active 任务的阶段/计数需用户展开才显示。
- 本地搜索可同时找到新闻与报告；新闻命中优先，报告点击打开临时窗口，关闭后原搜索状态仍在。
- 临时报告窗口同事件复用，显示可追溯来源，且不会打开/抢占 Workspace 管理窗口。
- 不修改选题、来源路由或通知服务；本阶段不运行测试/专项评测/构建，留一次 `swift build` 给主代理统一执行。
