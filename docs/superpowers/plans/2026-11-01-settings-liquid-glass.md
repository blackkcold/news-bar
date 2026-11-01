# 设置页液态玻璃：按 Apple 文档重做

状态：待实施（产品代码零改动）
依据：Apple Developer 文档与官方示例，非自拟

---

## 0. 依据

| 原文 | 出处 |
|---|---|
| "Reduce your use of custom backgrounds in controls and navigation elements. Any custom backgrounds and appearances you use in these elements might overlay or interfere with Liquid Glass or other effects that the system provides, such as the scroll edge effect… Prefer to remove custom effects and let the system determine the background appearance." | Adopting Liquid Glass |
| "Liquid Glass applies to the topmost layer of the interface, where you define your navigation. Key navigation elements like tab bars and sidebars float in this Liquid Glass layer." | Adopting Liquid Glass |
| "Consider using split views to build sidebar layouts with an inspector panel. [Split views] are optimized to create a consistent and familiar experience for sidebar and inspector layouts… use standard system APIs." | Adopting Liquid Glass |
| "Extend content beneath sidebars and inspectors. A background extension effect creates a sense of extending a background under a sidebar or inspector, without actually scrolling or placing content under it… mirrors the adjacent content… applies a blur." | Adopting Liquid Glass |
| "Liquid Glass forms a distinct functional layer for controls and navigation elements — like tab bars and sidebars — that floats above the content layer." / "Don't use Liquid Glass in the content layer." / "Use the regular variant … such as alerts, sidebars, or popovers." | HIG · Materials |
| Landmarks 示例：`NavigationSplitView` + 工具栏系统玻璃 + 图片上的 `backgroundExtensionEffect()` + 自定义玻璃只用于徽章 | Landmarks: Building an app with Liquid Glass |

---

## 1. 之前错在哪

| 维度 | 我之前的做法 | 文档要求 |
|---|---|---|
| **背景色** | 自绘 `.regularMaterial` 铺满窗口；详情列再铺一层 `windowBackgroundColor`；侧栏还要一个 `underPageBackgroundColor` | 不画。窗口背景由系统决定，自定义背景会盖住或干扰玻璃与 scroll edge effect |
| **布局** | 侧栏固定 194 + 内缩 8 的圆角浮板 + 8pt 沟槽 | 用 split view 的标准列；列宽可拖、可折叠，内缩与沟槽都不是规范里的东西 |
| **层叠** | 透明窗口 → 桌面 → 玻璃卡 → 内容，四层两套坐标系 | 窗口背景 → 内容层 → 系统玻璃 chrome，三层 |
| **显示效果** | 1pt 分隔线、自绘阴影、靠透明窗口折射桌面 | scroll edge effect + 系统边缘处理 + background extension |

补充两条自我更正：

1. 上一轮测到"系统侧栏 1.01、几乎纯白"，我判定为"没有玻璃、要自绘"。**这是误判**：玻璃采样的是内容层，我们的内容是纯白 Form，玻璃自然接近白。Apple 自家设置窗在纯白内容上就是这个观感。截图里的戏剧性来自图片内容，不来自材质参数。
2. 上一轮 4 号变体（透明窗 + 自绘玻璃卡）桌面透了进来，我判为"最像液态玻璃"。**这是反向的**：它让桌面参与了本该只由内容层构成的画面，正是文档要避免的自定义背景。

---

## 2. 正确结构

```
NSWindow（不透明，系统窗口背景，标题栏保留）
└── content
    ├── NavigationSplitView
    │   ├── sidebar:  List(.sidebar)          ← 系统绘制玻璃，不铺任何底
    │   └── detail :  Form(.grouped)          ← 内容层，实色，系统表单度量
    └── （可选）背景延伸：把有画面的头部放到 content 的 leading edge，
        对"图像"本身（不是文字层）加 .backgroundExtensionEffect()
```

三条硬规则：

- 导航元素上**不写任何 `.background(...)`**，包括 `.regularMaterial`、`underPageBackgroundColor`、自定义阴影与描边。
- 内容层**不出现玻璃**。
- 玻璃只由系统产出；我们只在"内容层里的浮起控件"上写 `.glassEffect`（本项目仅 AI 吸顶 chips 与 toast）。

### 代码骨架

```swift
NavigationSplitView {
    List(selection: $pane) {
        ForEach(SettingsPane.allCases) { item in
            Label(L10n.string(item.titleKey), systemImage: item.symbol).tag(item)
        }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
} detail: {
    VStack(spacing: 0) {
        paneHeader            // 纯内容，无背景、无分隔线
        Form { /* 现有 7 个 tab */ }
            .formStyle(.grouped)
    }
}
.navigationSplitViewStyle(.balanced)
```

---

## 3. 背景与颜色

- **窗口**：不设 `backgroundColor`，不设 `isOpaque = false`。保留标题栏。
- **内容**：`Form` 用系统 `grouped` 背景；删掉 `Settings/*.swift` 里的 `.scrollContentBackground(.hidden)`（它把这层系统背景藏了，是侧栏发白的另一半原因）。
- **窗口级自绘底**：设置窗不再走 `AppThemeBackground` 的 `.regularMaterial`。其它窗口（弹窗、Dashboard）暂不动，避免连带。
- **retro 主题**：仍走纸面，但它属于"内容层自绘"，与玻璃无关；retro 下整套玻璃分支 early-out。

---

## 4. 布局规范

| 项 | 取值 | 来源 |
|---|---|---|
| 侧栏宽度 | 系统默认，`min 180 / ideal 220 / max 280` 可拖 | split view 标准能力 |
| 侧栏行高与字号 | **不写死**，交给 `.sidebar` 列表样式跟随系统"边栏图标大小" | HIG · Sidebars（macOS） |
| 侧栏与内容分隔 | 无 `Divider`，无描边 | 系统提供边缘处理 |
| 侧栏底部 | 不放关键操作 | HIG · Sidebars（macOS） |
| 圆角 | 子元素与容器同心，不写固定 14/16 | Adopting Liquid Glass · concentric |
| 页头 | 不加 1pt 底线，滚动边界交给 scroll edge effect | Adopting Liquid Glass |

`SettingsPane` 的 7 个分组不变；`switchToAITab` 那个没有观察者的旧问题单独记一笔，不在本方案内。

---

## 5. 显示效果

- **滚动边界**：详情列的 `Form` 用系统默认 scroll edge effect；若需要更强，26 上 `.scrollEdgeEffectStyle(.soft, for: .top)`。删掉 `editorialMasthead()` 里那条 1pt 线。
- **内容延伸**：`backgroundExtensionEffect()` 只对**有图像的区域**有意义（它会镜像并模糊相邻内容）。设置页目前没有可延伸的画面，**不强加**；将来 About 页若加插画，再对插画本体加，不要对标题文字加。
- **工具栏**：若把"退出 NewsBar"从底部挪到工具栏，直接进 `.toolbar`，系统给玻璃；不再自绘按钮底。
- **自定义玻璃**：仅两处，各自放进 `GlassEffectContainer`：
  - AITab 吸顶 chips（`.glassEffect(.regular.interactive(), in: .capsule)`）
  - ActionToast（`.glassEffect(.regular, in: .capsule)`）

---

## 6. 降级

| 档 | 行为 |
|---|---|
| 26 | 系统侧栏玻璃 + 系统工具栏玻璃；自定义玻璃走 `glassEffect` |
| 15–25 | 系统 vibrancy；自定义玻璃退 `.thinMaterial` + 1pt 描边 |
| 降低透明度 | 系统自动转实色；自定义玻璃换 `controlBackgroundColor` + 描边 |
| 提高对比度 | 描边加深，次级文字提 `.primary.opacity(0.7)` |
| retro | 全部 early-out |

版本判断只写在 `GlassSurface` 一处（`#if compiler(>=6.2)` + `#available`），调用点没有 `#available`。

---

## 7. 测试

沿用 `SettingsWindowLayoutTests` 的 harness，不新造。

| 编号 | 用例 | 断言 |
|---|---|---|
| T1 | `testNoCustomBackgroundOnNavigation` | 源码扫描：`Views/Settings` 内 `.background(.regularMaterial)`、`underPageBackgroundColor`、`.scrollContentBackground(.hidden)` 出现 0 次 |
| T2 | `testSettingsSnapshotMatrix` | 7 pane × {light, dark} × {modern, retro}，820×580 / 860×620 / 1180×820 |
| T3 | `testDetailPaneIsOpaque` | 根视图下垫洋红，详情列洋红像素 = 0 |
| T4 | `testSidebarIsNotASlab` | 浅色下侧栏亮度 ≥ 0.75（现状 0.30） |
| T5 | `testGlassTierResolution` | 16 组表驱动 |
| T6 | `testNoRawGlassOutsideGlassSurface` | 源码扫描 |

harness 边界（写进注释）：离屏渲染不出材质，系统侧栏在离屏里两种外观都是 `#FFFEFF`。T2 只验布局；材质结论只来自真机。

---

## 8. 实施顺序

1. **F0**：删 `SettingsWindow.swift:94/96/106-110`（3 行，独立 PR）
2. 删设置页所有自定义背景与 `.scrollContentBackground(.hidden)`（T1）
3. `HStack + Divider` → `NavigationSplitView`，保留标题栏、保留侧栏开关
4. 页头去线，接 scroll edge effect
5. 自定义玻璃收敛到 `GlassSurface`，只留 chips 与 toast
6. 补 T2–T6 与真机矩阵（3 壁纸 × 明暗 × 辅助功能四档）

## 9. 未决

- 退出按钮是否移到工具栏（当前在底部，HIG 不建议把关键操作放在侧栏底部，但它在详情列底部，属于可接受范围）。
- 设置页是否保留 retro 主题的纸面底（内容层自绘，与玻璃不冲突）。
