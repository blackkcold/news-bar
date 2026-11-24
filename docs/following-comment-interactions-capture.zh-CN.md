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

## 实测结果（2026-11-24，桌面 weibo.com）

抓取方式：桌面网页已登录会话，在本人 2024 年旧博文下发一条测试评论，随后点赞、取消赞、删除。所有请求都带 `x-requested-with: XMLHttpRequest`、`x-xsrf-token`（取自 `XSRF-TOKEN` cookie）、`content-type: application/x-www-form-urlencoded`，`referer` 为博文详情页。

### 1. 评论点赞

```text
POST https://weibo.com/ajax/statuses/updateLike
object_id=<评论 id>&object_type=comment
=> {"can_follow_comment_author":false,"result":true,"ok":1}
```

与博文点赞共用端点；博文走 `setLike` / `cancelLike` + `id`，评论走 `updateLike` / `destroyLike` + `object_type=comment`。

### 2. 取消赞

```text
POST https://weibo.com/ajax/statuses/destroyLike
object_id=<评论 id>&object_type=comment
=> {"result":true,"ok":1}
```

`updateLike` 不是切换：连续调用两次仍是「已赞」，取消必须显式 `destroyLike`。

### 3. 回复

```text
POST https://weibo.com/ajax/comments/create
id=<博文 mid>&comment=<文本>&pic_id=&is_repost=0&comment_ori=0&is_comment=0&fp=<bot rid>
=> {"ok":1,"data":{ "id":5368788372427081, "rootid":5368788372427081, "rootidstr":"...", "floor_number":1, "text":"...", "like_counts":1, "user":{...}, ... }}
```

`fp` 由页面 `wbBotDetector.get()` 注入；是否可省略尚未验证，实现先不带，失败再评估。

### 4. 删除（清理测试评论）

```text
POST https://weibo.com/ajax/statuses/destroyComment
cid=<评论 id>
=> {"data":{...被删评论...}}
```

### 5. 评论列表

```text
GET https://weibo.com/ajax/statuses/buildComments?is_reload=1&id=<博文 mid>&is_show_bulletin=2&is_mix=0&count=10&uid=<作者 uid>&fetch_level=0&locale=zh-CN
=> {"ok":1,"data":[评论...],"total_number":1,"max_id":0}
```

评论对象含 `id / rootid / floor_number / text / liked / like_counts / pic_num / url_struct / user`。`liked` 是该会话下的点赞状态。

### 6. 评论图片：不是 pic_ids

桌面评论对象**没有** `pic_ids` / `pic_infos` / `pics`。带图评论只有 `pic_num: 1`，图片以链接卡片形式出现在 `url_struct`：

```text
url_struct[0].url_type     = 39
url_struct[0].url_title    = "查看图片"
url_struct[0].ori_url      = https://photo.weibo.com/h5/comment/compic_id/1022:<hash>
url_struct[0].short_url    = http://t.cn/...
```

所以「评论图片」不能按 `pic_ids` 实现；要显示原图需解析 compic 页面/接口，本期不做。

### 7. 未验证项

- 未触发 403 / 418 / 429，错误响应形状仍未验证。
- 未观察到 `Set-Cookie` 轮换 `XSRF-TOKEN`。
- 省略 `fp` 已验证可用：发评论、点赞、取消赞、删除四条请求在不带 `fp` 时都返回 200 + `ok:1`（2026-11-24 复测，测试评论已删除）。

### 验收勾选

- [x] 点赞与取消赞的端点、方法、字段差异已确认。
- [x] 回复端点、表单字段、响应是否含新评论已确认。
- [ ] `Set-Cookie` 是否轮换 `XSRF-TOKEN` 已确认（未观察到轮换）。
- [ ] 403 / 418 / 429 / 200-HTML 的实际响应形状已确认（未触发）。
- [x] 评论列表不返回 `pic_ids` / `pic_infos` / `pics`，图片走 `url_struct`。
