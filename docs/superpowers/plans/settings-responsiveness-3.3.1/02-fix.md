# v3.3.1 阅读研究关联响应性修复

## 目的

在保持现有阅读排序、文章卡片动作和两套视觉样式不变的前提下，收敛阅读研究关联的索引构建与 UI 刷新，避免设置关闭或阅读项不可见时继续读取/整理数据，并避免历史清除、事件更新和异步完成顺序导致旧关联复活。

## 已从源码确认的热点

- `WorkspaceReaderResearchMatcher` 整体标为 `@MainActor`。`performLoad(expectedRevision:)` 虽然异步从研究、工作台和事件 store 取快照，但随后在主 actor 建立 record/item/URL/subject/event 查表；`sortArticleLookups()` 会重新排序所有 item 与 URL 桶。单条记录刷新也会调用该全量排序。
- `NewsItemRow`、`RSSTextRow`、`RecommendationCardView` 和 `ResearchAssociationBadge` 各自订阅 `.researchRecordsChanged`、`.researchWorkspaceChanged`、`.newsEventsChanged`，多数行的回调会重新向 matcher 查询。传入 `matchOverride` 的 badge 也仍挂载监听器，只是在回调里提前返回。
- 阅读展示开关 `researchReadingEnabled` 目前控制 badge 的渲染/占位，但上述行的 `.task` 与通知回调不以开关为准；因此关闭展示后仍会触发匹配读取。具体窗口隐藏后是否仍保留这些视图，由现场阻塞栈和对应宿主生命周期再确认。
- `ReaderResearchPanelModel.refresh()` 在 `@MainActor` 模型中查询当前关联，并再次请求完整研究索引供“最近研究”列表使用。`ResearchStore` 自身是 actor；目前已确认的同步整理/排序发生在 matcher 主 actor，而不是 store actor。

以上是静态源码证据，不作为当前 P0 阻塞栈的最终归因。实现前会与现场栈逐项对照；若栈指向其他根因，收缩或调整本计划，不为优化而忽略真实故障。

## 实施范围

核心文件：

- `Sources/NewsBar/Services/Workspace/WorkspaceReaderResearchMatcher.swift`
- `Sources/NewsBar/Views/Workspace/ResearchAssociationBadge.swift`
- `Sources/NewsBar/Views/MenuBar/NewsItemRow.swift`
- `Sources/NewsBar/Views/MenuBar/RSSWaterfallView.swift`
- `Sources/NewsBar/Views/Dashboard/RecommendationCardView.swift`
- `Sources/NewsBar/Views/Dashboard/ReaderResearchPanelModel.swift`
- `Sources/NewsBar/Views/Dashboard/NewsReaderView.swift`

只在需要把广播监听提升到列表宿主并批量刷新可见项时，增加对 `NewsSection` / `RecommendationFeedView` 等宿主的最小改动；不修改 `Settings*`、`AppDelegate`，不修改选题、新闻源、研究排序或通知服务。若现场证据显示这些界面文件并非热点，则不改。

另对 `NewsOrchestrator.markResearchRead(recordID:)` 做一行事件载荷修正：单记录已读变化带现有 `recordID`，保持现有全量事件语义仅用于真正 bulk 清除/维护。

## 实施约束

1. 保留单一共享索引和按 `itemID`、规范 URL、record、event 的查表；把大批量映射/归并/排序移出主 actor，读路径保持 O(候选数) 且不逐次重建索引。
2. 同一版本只有一个装载/变更任务。重复研究/工作台/事件变化合并；首个变化启动有固定上界的合并窗口，不因持续事件反复重置。窗口结束后继续到达的变化进入下一批，不能丢掉加载期间的有效变更；过期结果不得覆盖新状态。
3. 单 record 更新只读取该 record 并修改受影响索引桶，插入/移除使用局部有序更新，不重新排序或扫描整份索引；清除历史或失去阅读资格时删除 ID 与 URL 两侧关联，并使先前异步请求失效。
4. 监听收敛到共享 matcher，不由每个文章行各自订阅同一组全局通知。每个可见文章持有按精确 itemID/规范 URL 注册的轻量展示信号；matcher 只给受影响且展示签名变化的信号派发新 match。未注册读者或展示开关关闭时只记脏状态，不读 store、不建索引；行销毁/身份切换时注销，避免 stale 回调。
   异步信号派发本身也保留单一可等待 flight，直到目标信号查询结束；并发刷新不能在投递期间因待处理键已摘出而提前返回，旧 generation 也不能注销同 ID 的新注册。
5. 不改变「研究」按钮/文章点击的目标与动作、不改变阅读顺序、推荐解释、卡片内容层级或既有主题视觉。

## 验收

- 修复后端匹配等待时，主 actor 不做全量查表建立或全桶排序；相同 revision 的并发请求共用一次装载。
- 单记录更新只影响对应 record/item/URL 桶；事件或工作台批量更新不会被装载中的旧 revision 覆盖。
- 展示关闭时不触发阅读关联查询；取消/不可见视图不留下后台刷新；重新开启后显示当前有效关联。
- 删除研究记录后，已在途旧查询不能让关联重新出现；报告、事件与原有文章点击/排序语义保持。
- 增加隔离 XCTest 回归，不操作桌面或用户运行实例；只跑本次 matcher/reader 关联相关测试，再做必要编译。
- 之后由发布协作者执行一次固定签名候选包验收；不跑全套测试或独立专项性能评测。

## 隔离回归用例

新增单独的 `WorkspaceReaderResearchMatcherTests.swift`，使用可计数、可挂起/放行的 fake store，不依赖真实磁盘、网络、时间阈值或桌面状态。至少覆盖：

1. 展示关闭时 matcher 不调用任何 store，且订阅注销后通知只标记脏状态；重新出现时使用最新数据。
2. 并发的多篇文章首查共用一次研究索引/subjects/events 加载；通知突发按有限合并窗口处理，热更新和窗口边界处到达的变化最终均不丢；等待者不能清除下一代 in-flight task。
3. 已无 badge 的文章在新 record 到达后能通过精确 itemID 或规范 URL找到报告；只标题相似不关联；同一 record 的进度字段更新只读该 record，不重新调用全量 `index()`，且不会唤醒无关行。
4. 新旧 revision 快速交替、筛选导致同一行切换文章时，旧匹配结果不得覆盖当前请求；record 清除/全量历史清除/注销后，先前等待的结果不得让关联复活。
5. 对适量大批量样本，断言首载次数、批处理次数、全量 index 调用数、增量 record 读取数和目标信号派发数的明确上界；局部进度不全局唤醒；不以墙钟耗时作为唯一通过条件。

若为了精确计数需要可见的诊断 seam，应只暴露内部、只读计数，不改变生产决策或用户数据路径。

## 现场证据待核

- 复现时的主线程/actor 阻塞栈、首个阻塞符号和是否有同步等待或锁持有；据此确认 matcher 是否为 P0 根因。
- 展示关闭及宿主关闭后是否仍在创建匹配任务，以及通知风暴是否来自设置/生命周期或其他调用点。
- 事件/研究变更通知能否携带足够稳定的变更 ID；如果不能，保留合并后的 revision 失效与单次重载作为正确性回退。

## 阶段 02 附加修复：通知页授权状态去重

### 范围

- `Sources/NewsBar/Views/Settings/ReminderTab.swift`
- `Sources/NewsBar/Views/Settings/EventMonitorNotificationSettingsSection.swift`
- `Tests/NewsBarTests/SettingsEventBudgetTests.swift`

### 行为与准入

- `ReminderTab` 是通知页授权状态的唯一读取者：页首次进入时只调用一次可注入的授权状态 action，并把只读 `authorized` 值传给 `EventMonitorNotificationSettingsSection`；子节不再直接查询系统授权状态。
- 用户从系统设置返回后，通知页在应用重新激活时刷新授权状态。刷新结果未变化时不写 SwiftUI 状态，避免无意义布局失效；初次查询尚未完成时忽略激活回调，避免首次进入重复查询。
- 子节继续显示现有权限提示、保留事件监控与提醒的独立开关、中心入口和只读预算摘要；预算继续经 controller 的轻量共享接口读取，不调用事件历史加载/归一化。

### 隔离验收

- 使用注入的授权 action 计数器与 fake event store；挂载完整通知页后，初次进入授权查询恰为 1 次，子节不额外查询。
- 500 条 fake 事件仍只触发一次共享预算读取，事件历史读取和持久化写入均为 0，controller 的事件数组保持为空。
- 注入授权变化并发送应用重新激活通知后，允许且只需额外查询一次；相同授权状态不得造成重复状态写入。测试不访问系统授权中心、不打开 App 或系统设置。
