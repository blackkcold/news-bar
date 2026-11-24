# 关注评论互动：一次抓包清单

> 目的：点赞/回复的写接口、表单字段和响应结构目前**没有任何仓库内证据**。在拿到一次真实桌面请求之前，不写点赞/回复实现，也不猜端点。
>
> 抓包只读取你自己浏览器里已经发生的请求。**不要**把 Cookie、`SUB`、`XSRF-TOKEN`、密码或完整账号 UID 贴到仓库、issue 或聊天里；只保留结构和脱敏值。

## 准备

1. 用桌面浏览器登录 `https://weibo.com`。
2. 打开一条**评论较多、最好带图片评论**的博文，例如 `https://weibo.com/{uid}/{bid}`。
3. 打开 DevTools → Network，勾选 **Preserve log**，清空当前请求。
4. 过滤框输入 `comments`（评论列表/点赞/回复通常都在这个路径下）；如果过滤后看不到，改用 `like` 或 `create`。

## 抓取 A：评论点赞 + 取消赞

1. 在评论上点一次「赞」，等请求完成。
2. 再点一次取消赞，等请求完成。
3. 分别右键请求 → **Copy → Copy as cURL**，或 **Save all as HAR with content**。
4. 记录：

| 字段 | 要记录什么 |
|---|---|
| URL | 完整路径（域名 + path + query） |
| Method | POST / GET |
| Status | 200 / 403 / 418 / 429 / 其他 |
| `Referer` | 完整值 |
| `Origin` | 完整值 |
| `X-Requested-With` | 是否有，值是什么 |
| `x-xsrf-token` | **只记录是否存在、长度、是否 percent-encoded；不要贴值** |
| `Content-Type` | 表单还是 JSON |
| 表单字段 | 字段名 + 脱敏示例值；特别确认点赞/取消赞是否用同一个字段的不同值 |
| 响应 JSON | 顶层 key、`ok` 值、`data` 形状、赞数是否返回、是否返回 `Set-Cookie`（只记 cookie 名） |

## 抓取 B：回复

1. 在博文评论区回复一条**无关紧要的测试内容**（例如“测试，稍后删除”）。
2. 记录请求 URL、方法、表单字段（`comment` / `mid` / `uid` / `reply` / `cid` 等实际出现的字段名）、状态码。
3. 记录响应：
   - 是否返回新评论对象；
   - 如果返回，评论对象的 key 和 `id`/`cid` 字段名；
   - 如果不返回，顶层 `ok` / `data` 是什么。
4. 抓完后可在微博里删除这条测试回复（不需要抓删除请求）。

## 抓取 C：评论图片 payload

1. 找一条**带图片的评论**，刷新评论列表。
2. 保存返回评论列表的那个请求（通常是 `comments/buildComments` 或类似路径）的响应 JSON。
3. 只确认评论对象里是否出现以下字段，以及它们的形状：

```text
pic_ids: ["..."]?
pic_infos: { "<id>": { "largest": { "url": "..." } } }?
pics: [{ "url": "..." }]?
```

4. 如果当前没有带图评论，记录“桌面评论列表未返回 `pic_ids` / `pic_infos` / `pics`”，不要用博文图片字段代替。

## 交付方式

把下面任意一种放到 `docs/` 之外的安全位置，或只把**脱敏后的结构**贴给实现者：

- 一份 HAR（删除无关请求；`Cookie`、`Set-Cookie`、`x-xsrf-token` 的值全部替换为 `REDACTED`）；
- 或每个请求一段最小 JSON：`{url, method, status, headers(脱敏), formFields, responseShape}`。

**不要提交 HAR 到仓库。** 抓包文件应放在临时目录，验收后删除。

## 验收标准（实现前）

- [ ] 点赞与取消赞的端点、方法、字段差异已确认。
- [ ] 回复端点、表单字段、响应是否含新评论已确认。
- [ ] `Set-Cookie` 是否轮换 `XSRF-TOKEN` 已确认。
- [ ] 403 / 418 / 429 / 200-HTML 的实际响应形状已确认。
- [ ] 评论列表是否返回 `pic_ids` / `pic_infos` / `pics` 已确认。

以上任何一项缺失，对应用户故事保持「未验证」，不进入生产代码。
