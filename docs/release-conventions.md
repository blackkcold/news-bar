# Release Conventions · 发版规范

> 统一发版流程和格式，确保一致性和可追溯性。

---

## 版本号格式

```
vX.Y.Z
```

- **X** (Major): 重大架构变更、不兼容 API 变更
- **Y** (Minor): 新功能、显著改进
- **Z** (Patch): Bug 修复、安全补丁、小幅优化

---

## GitHub Release 标题格式

```
NewsBar vX.Y.Z
```

**示例**:
- ✅ `NewsBar v1.3.3`
- ✅ `NewsBar v1.2.1`
- ❌ `v1.3.3 — 安全加固 & 架构优化` (副标题不应出现在标题)
- ❌ `Release v1.3.3` (必须包含产品名)

---

## Release Body 格式

```markdown
## vX.Y.Z — 副标题

### 🔐 安全修复
- **修复名称**：详细描述

### 🐛 Bug 修复
- **修复名称**：详细描述

### ✨ 新功能
- **功能名称**：详细描述

### 🔧 改进
- 文件名: 改动描述

### 🔧 技术细节
- 文件名: 改动描述

### 📦 安装
下载 `NewsBar-X.Y.Z.dmg`，拖入 Applications 即可。
```

**分类标签**:
| 标签 | 用途 |
|------|------|
| 🔐 安全修复 | 安全漏洞修复、加固 |
| 🐛 Bug 修复 | 功能缺陷修复 |
| ✨ 新功能 | 新增功能特性 |
| 🔧 改进 | 代码重构、性能优化 |
| 🔧 技术细节 | 架构变更、API 变更 |
| 📦 安装 | 安装说明（可选） |

---

## RELEASE_NOTES.md 格式

`RELEASE_NOTES.md` 作为**单一真实来源**，格式与 Release Body 一致：

```markdown
## vX.Y.Z — 副标题

### 🔐 安全修复
- ...

---

## vX.Y.(Z-1) — 副标题
```

**规则**:
- 新版本添加在文件顶部（最新版本在最前）
- 版本之间用 `---` 分隔
- 内容与 GitHub Release Body 保持同步

---

## 发版流程

```bash
# 1. 从 main 创建发版分支
git switch main
git pull --ff-only origin main
git switch -c release/vX.Y.Z

# 2. 更新 version.txt、RELEASE_NOTES.md、README.md 与相关项目文档
# RELEASE_NOTES.md 在顶部添加新版本，内容与 GitHub Release Body 保持同步

# 3. 测试并使用项目官方脚本打包
swift test
bash scripts/build.sh
# 验收：codesign --verify、hdiutil verify、SHA256 一致

# 4. 提交并推送 release 分支
git add <本次发版文件>
git commit -m "release: vX.Y.Z — 副标题"
git push -u origin release/vX.Y.Z

# 5. 创建 PR，等待全部 required checks 通过后合并
gh pr create --base main --head release/vX.Y.Z \
  --title "release: vX.Y.Z — 副标题" \
  --body "$(cat <<'EOF'
## vX.Y.Z — 副标题
### 变更摘要
...
EOF
)"

# 查看 CI；失败时在 release 分支修复并重新等待
gh pr checks --watch
gh pr merge --merge --delete-branch=false

# 6. 在合并后的 main 创建 annotated tag 并推送
git switch main
git pull --ff-only origin main
git tag -a vX.Y.Z -m "vX.Y.Z — 副标题"
git push origin vX.Y.Z

# 7. 在 tag 对应提交上再次使用官方脚本构建
bash scripts/build.sh

# 8. 使用项目脚本创建 GitHub Release 并上传 DMG/SHA256
bash scripts/release.sh

# 9. 验证远端 Tag、Release 标题、Release Body 与两个附件
gh release view vX.Y.Z
```

---

## 历史版本参考

| 版本 | 标题 | 副标题 |
|------|------|--------|
| v1.3.3 | NewsBar v1.3.3 | 安全加固 & 架构优化 |
| v1.3.2 | NewsBar v1.3.2 | 自动刷新正文消失修复 |
| v1.3.1 | NewsBar v1.3.1 | AI 摘要模板框架 & 引用编号源链接 |
| v1.3.0 | NewsBar v1.3.0 | Dark Mode Fix & UI Polish |
| v1.2.1 | NewsBar v1.2.1 | Keychain stability & API key privacy |
