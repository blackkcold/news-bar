# 微博热搜获取方案

## 当前实现：三级降级策略

```
用户触发刷新
    │
    ▼
Tier 1: GET https://weibo.com/ajax/side/hotSearch
    │ 移动端 UA + Referer + X-Requested-With
    │ 解析 data.realtime[].word / word_scheme
    ▼
  成功? ── 是 ──→ 取前 5 条 → [NewsItem] ✅
    │
    否 (网络错误/解析失败)
    │
    ▼
Tier 2: GET https://s.weibo.com/top/summary （降级 HTML 解析）
    │ 正则提取 <a href="/weibo?q=...">标题</a>
    │ 过滤无效行（热搜榜标签等）
    ▼
  成功? ── 是 ──→ 取前 5 条 → [NewsItem] ⚠️ 降级模式
    │
    否
    │
    ▼
Tier 3: 使用缓存数据（NewsOrchestrator 自动处理）
    ✅ 缓存兜底
```

## 历史决策记录

| 日期 | 方案 | 状态 | 备注 |
|------|------|------|------|
| 2026-05-19 前 | `m.weibo.cn/api/container/getIndex` (JSON API) | ❌ 已移除 | 反爬增强，无 cookie 模式下不可用 |
| 2026-05-19 | `weibo.com/ajax/side/hotSearch` (JSON API) | ✅ 当前 Tier 1 | 网页版 API，无需登录 |
| 2026-05-19 | `s.weibo.com/top/summary` (HTML 解析) | ⚠️ 当前 Tier 2 | 降级方案，正则解析 |

## 安全约束

1. **Cookie 不持久化**：每次请求使用 URLSession 默认 Cookie 管理，不手动保存到磁盘
2. **不自动重试**：失败后直接走下一级降级路径，不反复请求同一 API
3. **超时控制**：所有网络请求超时 10s
4. **频率限制**：服从全局 RateLimiter（手动刷新每小时 3 次触发警告）
5. **输入消毒**：所有标题经 `SecurityPolicies.sanitizeUserInput()` 处理

## 参考

- `weibo.com/ajax/side/hotSearch` 返回格式：`{"data": {"realtime": [{"word": "...", "word_scheme": "..."}]}}`
- `s.weibo.com/top/summary` 结构：`<td class="td-02"><a href="/weibo?q=...">标题</a></td>`
- 原 crawl4weibo 参考：https://github.com/Praeviso/crawl4weibo （三层 Cookie 策略）
