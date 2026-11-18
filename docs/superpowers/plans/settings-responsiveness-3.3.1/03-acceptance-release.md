# v3.3.1 自动验收与交付

## 验收方式

只做隔离代码自动化，不控制本机用户桌面、不打开或安装候选 App。新增 `SettingsWindow` XCTest 宿主，使用测试专属选择状态与测试环境注入，不触碰真实 `UserDefaults`、Keychain、订阅、偏好或历史：

1. 实例化真实 `SettingsWindow`，用自有未展示 `NSWindow` 承载 `NSHostingView`。
2. 对现代与 retro 两种主题，以 `NSTableView.row(at:)` 验证测试窗口内目标行命中，再在自有表格执行一次真实 `selectRowIndexes`。先观察该操作是否已更新绑定；只有未更新时才手动触发一次表格 delegate 回调，避免重复模拟同一次选择。不发送全局或系统鼠标事件，也不分别构造不同 `initialPane` 冒充切换。
3. 将左栏 `selectedPane` 与右栏 `presentedPane` 分开。测试必须断言列表选择同步提交，真实 `NSTableView.selectedRowIndexes` 与 binding 到位；detail 内容只在下一主循环按最新选择提交。每次新选择递增 generation 并取消/使旧提交失效，旧闭包晚到不能恢复旧 detail。
4. 连续选择八个 pane（含通知页）。分别记录“选择输入→左栏高亮”（表格行和绑定状态都到位）与“同一输入→右侧 header+detail 呈现”。每主题 `n=8` 左栏选择/高亮 p95 必须 `≤200ms`（XCTest 断言）；右页单独观察并有自己的一秒挂死保护，不使用 200ms 目标，也不与左栏 p95 混算。所有指标都标明是隔离 test-host 样本，不表述为真实桌面实测。
5. 用确定性 scheduler gate 推迟 detail 提交：连续选择不同 pane 时左栏立即更新；放行队列后只构造最后选中的 detail；随后重放旧提交仍不得复活旧页。该断言验证分轮与过期代次，不用任意 sleep。
6. 覆盖“已打开设置窗再由 AppDelegate 跳转 AI”的 NotificationCenter 路由，要求左栏选择和真实 header/detail 子视图回报都变化；该断言必须能在修复前失败。
7. 并发顺序回归：用纯内存 `ResearchPersisting` fake 挂起一次 `index()` 读取；AI pane 完成选择/呈现后批量写入 fake 的本地更新计数并发送 `.researchRecordsChanged`，在 fake 仍挂起时继续选择通知 pane，分别断言左栏 selection+高亮和右侧标题/内容容器更新；右页使用独立的一秒保护，最后释放 fake 并有界等待任务结束。此项只验证状态/事件顺序，不做跑分。
8. 提醒页通过测试注入 `.authorized` 状态，确保不访问系统通知权限。诊断只记录 pane key、表格行号、选择匹配、header/detail 呈现匹配和耗时，不保留 AX 树全文或截图。测试不覆盖 OS 鼠标投递、窗口焦点与真实桌面的可视表现。

必要时用自有窗口的 `hitTest(_:)` 与 `NSTableView.row(at:)` 验证几何命中；不发送 CGEvent、不调用系统输入注入，也不 `makeKeyAndOrderFront`。若离屏 SwiftUI 无法提供 AX 树，使用真实 header/detail 子视图上的 test-only 呈现快照回报，不得宣称完成 OS 鼠标或 AX 验证。

## 变更与发布

- 仅依据自动化复现的证据修复设置控件/pane 更新链；只有证据指向窗口入口时才触及 AppDelegate。不做导航重写或广泛 actor 标注。
- 在 `codex/fix-settings-responsiveness` 上完成必要定向测试与一次全量 CI；从同一代码点准备 `release/v3.3.1`。
- 仅产出一个签名候选包。出包验收只检查签名、bundle 版本与制品完整性；不安装、不打开、不操作本机 App。
- 自动化不通过则不合并；通过后按项目保护规则完成 PR/CI 与合并。保留 v3.3.0 `f62a9ac` 及原正式制品为回退点，不改个人数据。
- 最终报告列出提交/合并 SHA、定向与全量测试、签名/版本/制品检查和仍未覆盖的桌面因素。
