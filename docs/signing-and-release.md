# 签名与 Sparkle 更新

NewsBar 用**固定自签证书**签名，用 **Sparkle 2** 做原地升级。没有 Apple
Developer Program 账号，也不做公证。这份文档说明为什么这样可行、密钥放在哪、
以及一次发版要经过哪些步骤。

## 为什么自签够用

Sparkle 的安全链主锚是 **EdDSA 签名**，不是 Apple 代码签名。Sparkle 2.10.1
的 `SUUpdateValidator` 里写得很清楚：

- 旧 App 带 `SUPublicEDKey`，且下载包的 EdDSA 校验通过 → 更新被接受；
- Apple 代码签名只是 EdDSA 失败时的备选链（用于更换证书的过渡）；
- 唯一的硬约束是「旧版有签名 → 新版也必须签名」，自签也算签名。

而 `SUCodeSigningVerifier` 在宿主没有 Team ID 时直接跳过 XPC 连接校验。自签证书
没有 Team ID，所以 Sparkle 的安装器、XPC 服务都能正常工作。

固定证书真正解决的是 **身份漂移**：ad-hoc 签名的 designated requirement 含
cdhash，每次构建都变，于是每次升级 TCC、通知授权、登录项批准全部重来。换成固定
证书后，DR 变成 `identifier "com.newsbar.app" and certificate leaf = H"…"`，只要
证书不换，升级就不会重置权限。

## 做不到的事

| 限制 | 说明 |
|---|---|
| 首次安装会被 Gatekeeper 拦 | macOS 15 起没有「右键 → 打开」的捷径，需要「系统设置 → 隐私与安全性 → 仍要打开」 |
| `spctl` 永远 rejected | 构建门禁因此改用 `codesign --verify --deep --strict` + 证书指纹断言 |
| 无法公证 | 公证要求 Developer ID，没有账号就做不到 |
| 用户删掉重装要再批准一次 | 首次批准记录按签名身份保存，Sparkle 自动更新不带 quarantine，不会再拦 |

将来如果拿到 Developer ID，可以直接换签名：Sparkle 允许「EdDSA 不变、只换代码
签名身份」，更新链不会断。

## 证书

- 名称：`NewsBar Code Signing`
- 类型：自签 Code Signing，RSA 3072，SHA-256，有效期 10 年
- 扩展：`keyUsage=digitalSignature`、`extendedKeyUsage=codeSigning`
- 存放：`~/.config/newsbar/signing/`（目录 0700，私钥文件 0600）

**证书永不重建。** 重建会换掉 leaf hash，也就是换掉 App 的 designated
requirement —— TCC、通知、登录项会全部重置一次。备份只做拷贝，不要重新生成。

`build.sh` 每次构建会把 `.p12` 导入一个临时钥匙串，签完立即删除；登录钥匙串里
不安装任何东西，所以构建不会弹钥匙串密码框。

换机器或恢复备份后，先跑一次：

```bash
bash scripts/signing-check.sh
```

它会检查三份材料的权限与格式、打印证书指纹和有效期，并确认 `codesign` 能找到
`NewsBar Code Signing`。

## Sparkle 密钥

- 私钥：Ed25519 的 32 字节 seed，base64 后单行保存（Sparkle 的 `-x` 导出格式）
- 公钥：写在 `scripts/lib/app-config.sh` 的 `SU_PUBLIC_ED_KEY`
- 使用：`generate_appcast --ed-key-file -`，私钥从 stdin 进入，不落盘

## 1Password 条目

Vault：`Personal`。三份材料互相独立，缺一不可。

| 条目 | 类型 | 字段 | 用途 |
|---|---|---|---|
| `NewsBar Signing Cert` | Document | `NewsBar.p12` | 代码签名证书 |
| `NewsBar Signing Cert Password` | Password | `password` | `.p12` 导出密码 |
| `NewsBar Sparkle EdDSA` | Password | `password` | Sparkle EdDSA 私钥（base64 seed） |

换机器时按下面的顺序恢复，再跑一次自检：

```bash
mkdir -p ~/.config/newsbar/signing
chmod 700 ~/.config/newsbar/signing
op document get "NewsBar Signing Cert" --vault Personal \
  --output ~/.config/newsbar/signing/NewsBar.p12
printf '%s' "$(op read 'op://Personal/NewsBar Signing Cert Password/password')" \
  > ~/.config/newsbar/signing/NewsBar.p12.password
printf '%s' "$(op read 'op://Personal/NewsBar Sparkle EdDSA/password')" \
  > ~/.config/newsbar/signing/sparkle_ed_key
chmod 600 ~/.config/newsbar/signing/NewsBar.p12 \
  ~/.config/newsbar/signing/NewsBar.p12.password \
  ~/.config/newsbar/signing/sparkle_ed_key
bash scripts/signing-check.sh
```

发版时可以让 `appcast.sh` 直接从 1Password 取 Sparkle 私钥，不落盘：

```bash
export NEWSBAR_SPARKLE_KEY="op://Personal/NewsBar Sparkle EdDSA/password"
scripts/appcast.sh
```

`appcast.sh` 在 `NEWSBAR_SPARKLE_KEY` 存在时用 `op read`，否则回退到
`~/.config/newsbar/signing/sparkle_ed_key`。构建脚本读取本地签名目录，所以
`.p12` 与密码仍需先恢复到本地；1Password 是备份源，不是每次构建的在线依赖。

## 构建

```bash
# 正式构建：分支、tag、干净工作树三重门禁 + 固定证书签名 + DMG
scripts/build.sh

# 本地签名构建：跳过 tag/分支门禁，仍然用固定证书，用于测试升级链
scripts/build.sh --local-signed

# 无证书的本地构建：ad-hoc，仅用于没有签名材料的机器
scripts/build.sh --adhoc

# 只出 App，不出 DMG
scripts/package-local.sh --force
```

签名顺序（顺序错会让 framework 的封印对不上）：

```
XPCServices/Downloader.xpc → Installer.xpc → Updater.app → Autoupdate
→ Sparkle.framework → newsbarctl → NewsBar.app
```

不启用 Hardened Runtime。自签证书没有 Team ID，开启后 library validation 会拒绝
加载 Sparkle；而 Hardened Runtime 的唯一作用是公证，自签方案本来就不公证。

## 发版

```bash
# 1. 更新 version.txt / RELEASE_NOTES.md，提交，打 tag
# 2. 构建
scripts/build.sh

# 3. 生成签名 appcast（会顺带生成 delta）
scripts/appcast.sh

# 4. 上传 DMG、SHA256、appcast.xml 和 delta
scripts/release.sh
```

`appcast.xml` 作为 release 资产上传，App 里的 `SUFeedURL` 指向：

```
https://github.com/blackkcold/news-bar/releases/latest/download/appcast.xml
```

因此**不能把 release 勾成 pre-release**：`releases/latest` 会跳过预发布，feed
就停在旧版本。

`release.sh` 会在发布后拉取 `releases/download/v<version>/appcast.xml` 再校验
一次版本号、enclosure 签名和 feed 签名。

## 首次迁移

现有用户（包括本机）装的是 ad-hoc 的 v3.0.0，没有 `SUPublicEDKey`，Sparkle
无法自举。升级到第一个签名版本必须手动装一次：

1. 下载 DMG，拖进 Applications；
2. 首次打开被拦 → 系统设置 → 隐私与安全性 → 仍要打开；
3. 之后所有版本由 Sparkle 原地升级。

同时因为签名身份变了，升级后要复查一次「登录项」与「通知」授权。

## 排障

```bash
# 当前签名身份
codesign -dv --verbose=4 /Applications/NewsBar.app

# Sparkle 的完整日志
log stream --predicate 'subsystem == "com.newsbar.app"' --level debug

# 强制下一次启动就检查更新
defaults delete com.newsbar.app SULastCheckTime

# 让 Sparkle 忘掉「跳过此版本」
defaults delete com.newsbar.app SUSkippedVersion
```

| 现象 | 原因 |
|---|---|
| 更新窗口不出现 | App 仍是 `.accessory` 激活策略时 Sparkle 窗口不会抢前台；`SparkleUpdater` 会在显示前切 `.regular` |
| 提示 feed 签名无效 | appcast 被手改过；重新跑 `scripts/appcast.sh`，不要手动编辑 |
| 下载后安装失败 | 检查 DMG 里 App 的签名是否被破坏（`codesign --verify --deep --strict`） |
| 提示「应用已损坏」 | 用户的下载被 quarantine 且未按首次安装流程批准 |
