# 多小窗验收 · 2026-11-07

## 环境
macOS 26.6.2 / Apple Silicon / Xcode 27.2。本机原生 AX 操作；测试实例使用独立 bundle `app.oriel.multiqa.20261107`，未向用户真实数据写入样本。

## 自动化与构建
- Core 35 项通过；App 22 项通过。本轮合计 57 项，不计未重跑模块。
- 创建多窗口红绿：`/tmp/oriel-multi-create-red.log`（缺少公开集合接口）→ `/tmp/oriel-multi-create-green.log`。
- 指定窗口的显隐、锁定、自动隐藏、几何、恢复、关闭与旧事件隔离：`/tmp/oriel-multi-isolation-red.log`（缺少对应命令）→ `/tmp/oriel-multi-isolation-green.log`。
- 最终标准构建：`/tmp/oriel-multi-final-build.log`；App 测试：`/tmp/oriel-multi-final-tests.log`；备用脚本构建：`/tmp/oriel-multi-fallback.log`。均成功，标准应用签名校验通过。

## 原生行为
- W01：状态栏连续创建两个窗口后新建仍 enabled=true；工作台再创建第三个。窗口 ID、编号不同，关闭后编号不复用。
- W02/W04：隐藏小窗 1、锁定小窗 2、关闭小窗 2，仅改变对应窗口；小窗 1 与 3 保留。开启小窗 4 自动隐藏后，其状态变为已隐藏，小窗 1 仍显示；恢复对应行成功。
- W04：默认宽度 420 创建小窗 4；将默认宽度改为 360，明确选择小窗 4 并应用，实测窗口 4 宽 360，窗口 1 仍宽 280。无目标时应用按钮禁用。
- W05：小窗 1 编辑并保存测试便签；小窗 3 打开便签列表并选择同一便签，焦点回到小窗 1 的编辑器。关闭小窗 3 后文字保留，追加文本再撤销回到原文。
- W06：小窗 4、5 同时显示行情；从 5 移除一个测试自选项，4 同步更新。关闭 5 后，4 可刷新并显示行情。独立 visibility owner 的自动化测试验证关闭一个所有者不会停止剩余所有者的请求。
- 工作台默认与最小尺寸已检查，行操作无重叠；设置最小尺寸可滚动。

截图：[工作台](multiple-windows/workspace.png)、[最小工作台](multiple-windows/workspace-min.png)、[最小设置](multiple-windows/settings-min.png)。

## 边界
本轮未重复验证跨屏、Space、全屏、真实键盘焦点和底层应用穿透；不据此宣称全系统兼容。多窗长期资源压力、多个终端同时运行尚未实测。窗口数量、位置、终端会话不跨重启恢复。

## 正式实例重启
已正常退出旧正式实例与独立 QA 实例；标准 Debug 新版启动进程 **10633**。实际创建两个空白首页小窗，状态栏「新建小窗」仍 enabled=true。保留正式应用与两个小窗供用户体验，未导入测试数据。QA 数据移至 `/tmp/OrielMultiQA.HBX585/app-support`，测试偏好域已清理。

## 显隐按钮合并 · 2026-11-07
工作台的恢复、隐藏合并为「显示 / 隐藏」状态按钮。标准构建与签名通过（`/tmp/oriel-toggle-build.log`），重启进程 13507。原生点击验证：隐藏 → 行状态已隐藏、按钮显示；再点击显示 → 行状态已显示、按钮隐藏。每行仅保留一个显隐按钮与关闭按钮，布局截图 `/tmp/oriel-toggle.png` 已检查。此次仅调整按钮接线，未重复运行无变化的行为模块测试。

## 工作台精简 · 2026-11-07
按用户要求移除工作台的锁定穿透与边缘唤醒开关，并移除其整行空间。工作台只保留新建、窗口状态、显示／隐藏和关闭。标准构建、签名、diff 检查通过；重启进程 15580，原生 AX 确认工作台无上述开关，小窗工具栏仍保留两项功能。截图 `/tmp/oriel-workspace-simple.png`。本次仅删除重复 UI，无行为模块变更，未重复运行单元测试。

## 工作台悬停定位 · 2026-11-07
- 公开窗口集合接口新增临时强调状态。红绿记录：`/tmp/oriel-hover-red.log` → `/tmp/oriel-hover-green.log`（跨行、旧退出、不修改窗口快照）；`/tmp/oriel-hover-lifecycle-red.log` → `/tmp/oriel-hover-lifecycle-green.log`（隐藏、关闭、无效目标及清除）。Core **37 项通过**。
- 标准构建 `/tmp/oriel-hover-build.log`、App **22 项测试通过** `/tmp/oriel-hover-app-tests.log`；签名与 diff 检查通过。
- 原生进程 **17702**：两个空白小窗分开放置，悬停第一、第二行分别高亮目标绿色轮廓并提高清晰度；CGWindow alpha 实测其他窗为 0.22，移出行恢复 1。背景/内容配置不写入。
- 切换到设置页恢复两个窗口 alpha=1。隐藏小窗 1 后悬停该行，小窗 1 保持隐藏、小窗 2 alpha=1。关闭悬停目标后剩余窗恢复；重新创建仍正常。
- 已检查截图 `/tmp/oriel-hover-first.png`、`/tmp/oriel-hover-second.png`、`/tmp/oriel-hover-restored-one.png`。正式新版保留两个空白小窗供体验。悬停不调用激活或键盘焦点 API；本轮未重复验证跨应用真实输入焦点、全屏、多屏。

## 窗口重命名 · 2026-11-07
- 名称旁铅笔入口，20×20 pt 点击区域；单行名称可截断，提示展示完整名称。
- 标准构建 `/tmp/oriel-rename-final-build.log`、签名、diff 检查通过。重启最终进程 **21088**。
- 原生验证：保存「阅读」后工作台、AX 窗口标题、状态栏恢复子菜单、设置目标列表均更新；重开编辑预填当前名称。空名称、33 字符名称保存按钮禁用；取消保留「阅读」。早期菜单名称未刷新已通过独立观察窗口名称的菜单视图修复并复验。
- 已检查工作台截图 `/tmp/oriel-rename.png`。未新增持久化和业务内容样本；未重复运行未修改的窗口行为模块测试。

## 小窗内显示名称 · 2026-11-07
标准构建 `/tmp/oriel-visible-name-build.log`、App 22 项测试 `/tmp/oriel-visible-name-tests.log`、签名及 diff 检查通过，已重启进程 26035。AX 验证新窗标题「小窗 1」可见，改名后正文工具栏名称立即更新；默认宽 280 pt 长名称正确省略，无按钮重叠（`/tmp/oriel-visible-name.png`）。120×90 pt 时隐藏名称以保留控制（`/tmp/oriel-visible-name-narrow.png`）。从名称中部拖动，窗口由 [1296,54] 移至 [1196,114]，确认名称不会阻断拖动。最终保留名称「阅读」的小窗供体验。

## 双击名称改名 · 2026-11-07
- 标准构建 `/tmp/oriel-double-rename-final-build.log`、签名、diff 检查通过；App 22 项测试通过 `/tmp/oriel-double-rename-tests.log`。已重启进程 46004。
- 原生双击顶部名称打开弹窗，预填并选中当前名称；空白时保存禁用，保存「阅读」后标题与工作台同步更新。输入其他文字后 Escape 取消保留原名。
- 从名称区域拖动仍将窗口从 [1296,54] 移到 [1196,114]。
- 开启边缘唤醒后双击，确认开关仍为 1；鼠标移到小窗外时改名弹窗仍可见，取消后小窗按原规则隐藏。再次恢复后从工作台隐藏正在改名的小窗，弹窗取消、再显示名称未变。
- 原生弹窗截图 `/tmp/oriel-double-rename-sheet.png` 已检查。正式应用保留可见「阅读」小窗。

## 审查修复 · 2026-11-07
- 关闭窗口/页签只保存其拥有的便签 UUID，退出仍全量检查；保存失败定位也限制在本次文档集合。局部保存保留其他文档的自动保存期限。
- TDD：`/tmp/oriel-scoped-close-red.log`（缺少隔离接口）→ `/tmp/oriel-scoped-close-green.log`；`/tmp/oriel-scoped-timer-red.log`（其他便签未自动保存）→ `/tmp/oriel-scoped-timer-green.log`。最终 App **25 项通过**：`/tmp/oriel-fixes-final-tests.log`；构建 `/tmp/oriel-fixes-final-build.log`、签名与 diff 检查通过。
- 标题扫描遇到首个非空行即停止，保留空白、CRLF、Unicode 字符及 40 字截断语义；标题变化改为每窗单个订阅并合并同一轮刷新。实际源码优化构建微基准中，同一份 1,000,007 字节/25 万行正文单次读取标题由约 29.3 ms 降至 0.01 ms 以下（`/tmp/oriel-review-title-bench.swift`，`/tmp/oriel-review-title-bench-fixed`）。此数字不是完整输入延迟测量。
- 隔离实例 `app.oriel.fixqa.20261107`：将便签 A 的备份路径改为目录以注入确定性写入失败，输入新文字后显示「未保存」。空白窗口 B 可关闭，A 所在窗的空白页签可关闭；A 自身关闭仍弹保存保护，选择保留后正文不丢。移除故障后关闭 A 成功，检查落盘正文等于最新输入。
- 另外实测两个便签页签编辑后标题更新，原有页切回后标题仍随编辑更新。测试数据只在独立域，退出 QA 后移至 `/tmp/OrielFixQA.1q0pyO/app-support`，未写入用户真实便签。
- 正式新版已重启，进程 51172；工作台与一个空白首页小窗已打开供体验。没有提交或推送。
