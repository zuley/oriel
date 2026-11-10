# 透明度设置 · 原生模糊材质

2026-11-10。对应 Spec 005 的 T05-M01；仅更换透明度设置浮层的背景材质，不属于 017 的剩余架构任务。

**当前结论：首轮 `NSVisualEffectView.menu` 没有达到实际模糊要求，用户反馈「没效果」属实。已改为 macOS 26 原生 `NSGlassEffectView`，并通过同图案背景及完整应用的真实合成复验；186 项测试和两种构建通过。用户授权后，修正后的正式应用已于 23:18 正常重启，PID 76321。**

## 首轮实现（已由下文修正）

- `WindowSettingsController` 根视图改为 `NSVisualEffectView`，使用 `.menu`、`.behindWindow`、`.active`；浮层在非激活小窗中仍保持可用的材质外观。
- 删除 `WindowSettingsPanel.show` 每次显示时绘制的不透明白底，避免覆盖原生窗后模糊。
- 保留 224×72 pt、8 pt 圆角、原生窗口阴影、两个连续滑杆及现有值/回调。没有降低整个浮层或控件的 alpha，没有引入自定义模糊滤镜。
- 材质由系统渲染，随背景与系统辅助功能设置改变。没有切换用户的「减少透明度」设置，未实测其开关；实现不强行覆盖系统材质回退。

## 红绿测试与构建

新增 `WindowSettingsPanelTests` 三项，测试目标补编译 `WindowSettingsPanel.swift`：

1. 原生菜单材质、窗后合成、激活外观、尺寸与圆角；没有不透明填充，控件 alpha 仍为 1。
2. 显示/关闭/重新打开保留材质，浮层本身不透明度为 1，子窗关系与关闭回调正确。
3. 两个滑杆的初值、可访问标签、连续更新和数值回调不变。

修复前材质相关两项失败，滑杆项通过（`.build/material-red.log`）；修复后三项通过（`.build/material-green.log`）。

| 全量测试 | 结果 |
|---|---|
| OrielCore | 54 通过 |
| OrielReading / OrielReaderUI | 25 + 6 通过 |
| OrielTerminal | 7 通过 |
| OrielAppTests | 94 通过（91 → 94） |
| 合计 | **186 通过，0 失败** |

`./scripts/build.sh` 与 `./scripts/build-local.sh` 成功；正式产物签名、工程 plist、`git diff --check` 均通过。日志：`.build/material-{core,reading,terminal,app,build,local}.log`。

## 原生检查

使用独立 bundle `app.oriel.materialqa.20261110`，先运行旧构建对照实例 50239，再运行新构建实例 70061；没有输入便签或在正式用户目录写测试数据。新版 QA 的 `Oriel.debug.dylib` 与正式构建通过 `cmp` 字节一致。

- 原生打开设置浮层，CoreGraphics 与辅助功能树均确认其为 **224×72 pt**，两行标签与滑杆存在，初值均为 0.75。
- 查看实际父窗合成截图：浮层不再是纯白底，显示半透明原生菜单材质、圆角和阴影；文字与滑杆保持清晰。[截图](005-native-material/native-material.png)、[父窗快照](005-native-material/native-material.json)、[浮层控件快照](005-native-material/settings-controls.json)。
- 关闭再打开后浮层和两个控件仍存在；数值与回调由上述测试验证。
- 原生工具在 `set-value` 调整浮层滑杆时返回 `window_not_found`；未把该操作记为成功，也没有声称本轮完整实测了滑杆拖动、Esc、外部点击、减少透明度或多屏边界。
- 部分单独浮层截图被工具错误缩放为整个父窗缩略图，不作为有效视觉证据；保存的是已实际查看的父窗合成截图。

## 首轮结束状态

两个独立 QA 实例均通过正常退出关闭，正式旧实例不受 QA 操作影响。首次正常重启正式应用的执行被权限系统以 `Interfere With Workloads` 拦截，未绕过。随后用户明确授权「允许重启」，于 2026-11-10 23:01 CST 正常退出旧进程 32729 并启动首轮材质版本，PID **71651**；复查旧 PID 已退出、新进程存活，没有强制结束进程。日志 `.build/material-restart.log`。该版本随后被用户确认为没有预期模糊效果。

## 用户反馈后的修正（2026-11-10 23:15）

### 复现与原因

- 系统为 macOS 26.6.2，`accessibilityDisplayShouldReduceTransparency` 与 `accessibilityDisplayShouldIncreaseContrast` 均为 false，没有修改用户的辅助功能设置。
- 将生产的 `WindowSettingsPanel` / `WindowSettingsController` 直接编译到临时原生对照程序，在同一窗后绘制高对比彩色细条纹与大字。不是以离屏 `draw` 模拟模糊，而是将真实子窗显示在真实背景窗之上，再捕获 WindowServer 合成结果。
- 首轮四列对照显示：旧 `.menu` + 原裁切、`.menu` 去裁切、`.popover` 去裁切均近似灰色实底；只有 `NSGlassEffectView` 的 `.regular` 可见背景颜色与大字，并对细条纹/字边缘进行模糊。[四材质现场](005-native-material/glass-correction/four-materials.png)。这排除了“仅由 layer 裁切导致”的猜测。
- **首轮验证不充分**：只检查了 `NSVisualEffectView` 的枚举与浅色底上的外观，不能证明背景真的透出。先前对实机成功的描述已被此次证据推翻，不再作为 T05-M01 通过依据。

### 修复

macOS 26 及以后改为 `NSGlassEffectView(style: .regular)`，使用原生 `cornerRadius = 8`；标签和滑杆放入其 `contentView`，不向玻璃任意叠加子视图，不设置实色 tint，不降低整体 alpha。macOS 14–15 通过可用性分支保留旧菜单材质，不引入私有 API 或截图式背景模糊。尺寸、浮层定位、关闭生命周期和数值回调不变。

更新 3 项测试，要求当前系统实际创建玻璃根视图，控件位于玻璃 `contentView` 中，检查尺寸/圆角/无填色/alpha/重开和连续回调。修复前 3 项均失败（`.build/glass-red.log`），修复后 3 项通过（`.build/glass-green.log`）。四组共 **186 项、0 失败**，标准与备用构建、签名及 diff 检查均通过，日志 `.build/glass-{core,reading,terminal,app,build,local}.log`。旧系统分支编译通过，但未在旧版系统上运行，不能宣称旧版实机验证通过。

### 真实合成复验

1. [同图案、同尺寸新旧对比](005-native-material/glass-correction/same-backdrop-before-after.png)：左为旧菜单材质，右为直接使用修正后生产控制器的浮层。两边都是相同蓝白条纹与 BACKGROUND 大字；右侧确实透出蓝色与模糊后的大字，细条纹不再清晰可辨，前景标签和滑杆保持清晰。未使用降低窗体透明度来制造效果。
2. 完整应用独立 bundle `app.oriel.glassqa.20261110`、PID 74359，`Oriel.debug.dylib` 与正式构建逐字节一致。小窗打开便签、输入仅用于测试的重复背景文字，再打开设置：[实际应用截图](005-native-material/glass-correction/actual-app-text-blurred.png)中浮层后面的正文透出并模糊，浮层自己的标签和滑杆仍清晰。纯白无内容背景上效果会自然更弱，不能再用该场景单独证明或否定模糊。
3. 对照程序和完整 QA 实例已正常退出；没有向正式用户便签目录写样本，也没有改变系统显示偏好。此次未重试完整拖动/键盘关闭/多屏验收，回调由自动化测试覆盖。

### 当前交付状态

修正已实现并有真实图案与完整应用证据。首次尝试正常重启加载修正时被执行权限以 `Interfere With Workloads` 拦截，未绕过。随后用户明确授权「允许重启」，于 2026-11-10 23:18 CST 正常退出首轮进程 **71651**，启动玻璃修正版，正式进程 **76321**；复查旧 PID 已退出，新进程持续运行，没有强制结束进程。日志 `.build/glass-restart.log`。未提交或推送。
