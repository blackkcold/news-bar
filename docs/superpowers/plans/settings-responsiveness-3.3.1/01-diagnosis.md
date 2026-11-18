# 设置页响应诊断 — v3.3.1

## 范围与边界

诊断设置窗口选择状态和右侧 pane 更新两个环节。仅使用隔离 XCTest、自建 `NSHostingView`/`NSWindow` 与测试进程内存视图层级；不投递全局鼠标事件，不注入或控制用户桌面。禁止采样个人运行、打开或切换本机 App、读取新闻内容/凭据/偏好值、重置历史或输出完整 AX 树/截图。

## 已知事实

- 源码基线为 v3.3.0 `f62a9ac`，当前分支 `codex/fix-settings-responsiveness`。
- 只读核验显示安装包版本 `3.3.0`、bundle id `com.newsbar.app`、bundle `/Applications/NewsBar.app`；不对该进程做现场操作或采样。
- `SettingsWindow` 用共享的可观察 pane selection；左栏 `List(selection:)` 与 detail 共用该选择，detail 用它切换八个 tab。AppDelegate 复用窗口时通过 NotificationCenter 请求 AI pane。仅这些源码结构不是卡顿证据。
- 已安装包的屏幕诊断被主任务明确改为严格代码测试；后续不打开、点击、切换或安装本机 app。

## 自动化诊断与因果门槛

在 XCTest 的自有、未展示宿主中挂载真实 `SettingsWindow`，以 `NSTableView.row(at:)` 检验 sidebar 行位置，再调用测试表格的 `selectRowIndexes` 与真实 delegate 回调驱动 SwiftUI `List(selection:)`。分别核对“共享选择状态 + `selectedRowIndexes` 到位”以及实际 header 与 content 子树的呈现快照；按现代/retro 主题及连续八个 pane 覆盖提醒页。左栏选择/高亮的每主题 8 样本 p95 断言不超过 200ms；右侧从同一选择输入到 header+detail 呈现单独记录，并以独立 1 秒挂起保护限制。另以 `.switchToAITab` 验证已打开设置窗的 NotificationCenter 路由。此方法验证应用内选择和视图更新链，不代表操作系统鼠标投递或真实桌面表现。定位异常时检查失败断言覆盖的同步代码路径；不从 `@MainActor`、NotificationCenter 的存在或启动后台任务本身推断根因。

只有可稳定复现的断言失败、命中错误，或可指认的选择链同步重活才触发产品改动；否则报告“代码自动化未复现”，不臆测真实桌面行为。
