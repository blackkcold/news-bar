# 阅读器受信任代理 Implementation Plan

**Goal:** 在软路由 Fake-IP 环境下，为阅读器提供显式授权的 HTTP CONNECT 代理；默认严格模式，不全局放行 Fake-IP。

**Architecture:** 使用 macOS 14+ 的 `WKWebsiteDataStore.proxyConfigurations`，作用于阅读器自己的 nonPersistent store；`ProxyConfiguration.allowFailover = false`。主页面与子框架仍执行 HTTPS/主机/下载限制，受信任会话的目标解析交给代理，明确不承诺应用可核验最终出口 IP。

**Tech Stack:** SwiftUI、Observation、WebKit、Network、既有 EncryptedKeyStore；macOS 15+，无第三方依赖。

**Spec:** 用户在本会话批准的“阅读器专用受信任代理模式”方案及提供的软路由审计报告。

## Global Constraints
- 全部主会话执行，不使用 subagent，不提交、不推送。
- 不修改软路由、系统代理、网关、DNS；不读取现有口令。真实路由认证由用户在设置中输入。
- HTTP 代理认证在局域网链路上不由 TLS 保护；必须显式说明并授权，不标记为安全隧道或端到端公网目标保证。
- 只将代理入口视为可信，不能将其 LAN 地址变成可浏览目标白名单。
- 保存端点和模式；账号密码仅放独立的加密账户。授权仅内存、本次网络/进程有效，网络事件或睡眠撤销授权，活动阅读器停止，不自动直连。

## Tasks
1. **配置与授权策略**：新增 ReaderProxyController / endpoint / credentials / session。测试入口验证、严格默认、重启不恢复授权、凭据不进入 UserDefaults、异步保存与网络/模式切换隔离。先 RED，再实现，再跑定向测试。
2. **阅读器与设置**：nonPersistent store 配置固定代理；严格模式沿用 DNS 校验，授权代理模式只跳过本机 DNS 的地址推断，不绕过 URL 策略。撤销授权立即销毁 WebView。设置页显式风险确认、加密保存、重新授权、关闭及 metadata 连接测试，沿用现有主题与中英切换。
3. **实际传输验证**：本机受控 CONNECT 服务记录域名和认证并返回错误；验证 WebKit 的 hostname CONNECT、认证、不可达/拒绝时不回退。fixture 不转发公网，无真实密钥。验证 Fake-IP 在严格模式仍拒绝及内网/下载规则保持。
4. **全量回归与打包**：Debug/Release 全套测试、原生截图、自审；明确真实旁路由尚待用户口令验收。沿用已批准的备份与 scripts/build.sh，不启动正式应用以免触发 AI 费用。

## Review Focus
- 代理认证只到 CONNECT 入口，不作为网站请求 Authorization；测试解析实际 CONNECT。
- 代理失败不能变成透明/direct 请求；测试 allowFailover 和实际失败导航。
- 网络变更、模式切换、保存尚未结束时不能恢复旧会话；测试状态和延迟凭据存储。
- 初始加载规则编译/导航 DNS 的 await 返回后仍需复核授权版本。
- 新增代理能力不得改变 AI/模型目录请求或打开内网 URL 的许可。

## Evidence
- 本机 SDK 确认 `ProxyConfiguration.applyCredential`、`allowFailover` 和 WKWebsiteDataStore 的代理属性可用；Network 头文件明确 false 表示禁止回退非代理连接。
- 既有 Debug/Release 各452项零失败（1项默认跳过）。单独实网爱范儿测试在 Fake-IP 环境失败，保留日志，不以跳过掩盖。
- 实测：真实 WebKit 向受控代理发送域名 CONNECT，并使用 Proxy-Authorization；受控 502 拒绝被正确映射为代理不可用。
- Ruling: 原始 transport 测试假设 loopback 也使用代理，但实测 WebKit 内置绕过回环地址，且从未尝试 CONNECT（不是代理失败后的 failover）。保留该窄范围行为刻画，并新增生产阅读器在任何连接前拒绝回环的集成测试；不以代理配置替代 URL/资源规则，不声称通用子资源防火墙。
