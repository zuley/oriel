> 后续多窗能力见 [Spec 014 验收](014-multiple-windows.md)。下文单窗限制及新建置灰记录属于历史版本，已取消。

# 职责收窄验收 · 2026-11-07

菜单补验：状态栏「新建小窗」改为始终显示。原生 AX 验证无窗口时 enabled=true、已有窗口时 enabled=false、关闭后恢复 true；从该菜单成功创建小窗，再次显示为禁用。构建、签名、diff 检查通过，已重启新版进程 99444（17:13:53）。

按用户最新要求，主界面仅保留「工作台 / 设置」。工作台只管理小窗，不展示或操作便签、书架、自选股或页签。

- 删除内容管理视图、导航、内容打开命令与页签状态投影；行情视图和刷新归小窗。全局默认设置与数据备份保留。
- 标准 Xcode 构建通过；本轮 app **22 项测试通过**（移除仅用于已撤销管理页导入行为的测试）；签名验证、`git diff --check` 通过。日志：`/tmp/oriel-window-management-build.log`、`/tmp/oriel-window-management-tests.log`。
- 实机验证新建、隐藏、显示并解锁、锁定切换、关闭确认、关闭后重新创建通过。侧栏仅有工作台和设置；小窗原有内容入口保留。
- 默认和最小尺寸截图已检查：[当前工作台](management/window-only.png)、[最小尺寸](management/window-only-min.png)，无明显裁切。
- 已重启标准 Debug 新版，进程 **97935**，启动时间 17:10:16；主界面与一个空白小窗已打开，未写入业务内容样本。

以下为前一版历史验收，涉及主界面内容管理、五页面截图与此前独立审阅的结论不再代表当前功能范围。

---

# 主界面验收 · 2026-11-07

## 环境与范围
macOS 26.6.2 / Apple Silicon，Xcode 27.2。标准 Xcode 工程、本机签名调试构建。原生交互使用独立 `app.oriel.managementqa.20261107` 测试实例及测试数据；不向用户真实便签/书架写入样本。

本轮交付 Spec 013：工作台、便签管理、书架、自选股、默认设置及数据导出。保持一个小窗、多页签；未恢复沉浸模式。

## 自动化
- App target 测试 **23 项通过**：默认设置持久化、范围校正后重载、恢复默认；数据导出副本、无覆盖、递归路径/符号链接拒绝、无效参数清理；多可见行情视图；阅读首次出现不覆盖打开请求；导入不标记已读；翻章发布共享进度；既有便签及布局回归。
- OrielCore **33 项通过**。
- OrielReading **24 项通过**，包括导出书架可以独立重新打开、删除副本不影响源；OrielReaderUI **2 项通过**。
- 合计本轮 **82 项**。不把未重跑的终端模块测试计入此数。

## SDD / TDD 证据
| 行为 | 失败记录 | 通过记录 |
|---|---|---|
| 默认值保存与重载 | `/tmp/oriel-main-settings-red.log` 缺少公开类型 | `/tmp/oriel-main-settings-green.log` |
| 范围校正与恢复 | `/tmp/oriel-main-bounds-red.log` 缺少 reset | `/tmp/oriel-main-settings-stocks-green.log`；重载补验 `/tmp/oriel-main-bounds-reload.log` |
| 多行情视图 | `/tmp/oriel-main-stocks-red.log` 缺少 owner 接口 | `/tmp/oriel-main-settings-stocks-green.log` |
| 数据副本导出 | `/tmp/oriel-main-export-red.log` 缺少类型（当时同时有主界面接线未完的编译错误） | `/tmp/oriel-main-tests.log`；边界补验后全量通过 |
| 首次出现覆盖书籍打开请求 | `/tmp/oriel-main-reader-red.log` 目标书籍与阅读状态断言失败 | `/tmp/oriel-main-reader-green.log` |
| 导入保持未读 | `/tmp/oriel-main-import-red.log` 缺少导入后打开开关 | `/tmp/oriel-main-tests-final.log` |
| 书架进度同步 | `/tmp/oriel-main-progress-red.log` 翻章没有发布共享变化 | `/tmp/oriel-main-tests-reviewed.log` |

最后全量 app 23 项记录：`/tmp/oriel-main-tests-reviewed.log`。测试针对公开行为，不使用 30 ms 实际等待作为窗口行为预期。

## 原生验收
| 条目 | 结果与证据 |
|---|---|
| M01 / M08 启动、恢复 | 默认启动显示主界面；关闭开关后重启仅菜单栏；从菜单重新打开；关闭主界面后小窗与终端仍在。首次启动展示安排在 SwiftUI 场景配置后，避免窗口被初始化过程隐藏。 |
| M02 工作台 | 创建终端、自选股、空白页；连续新建空白页会增加页签数；真实标题与当前页签同步；锁定后显示并解锁可用。关闭终端页签出现结束会话确认，取消保留页签。 |
| M03 便签 | 从主界面新建，在小窗输入中文，主界面出现保存的记录；预览、置顶、移到废纸篓、恢复通过。测试样本仅写入 QA 数据域。 |
| M04 书架 | 原生文件选择器导入 TXT；从主界面打开后小窗显示正文。修复前首次出现误回书架，修复后通过。新文件仅导入保持「未读」。翻章后主界面即时更新 1/2、2/2；独立审阅复核通过。 |
| M05 自选股 | 搜索 AAPL、添加、清除搜索；主界面和小窗均出现同一条自选。复用现有腾讯财经报价、管理与刷新界面，不新增数据源。多视图暂停语义另由自动化覆盖。 |
| M06 / M07 设置 | 修改默认宽度至 420；显式应用后小窗宽度变为 420；透明度默认与当前设置区分，数值不显示在滑块旁；低透明度仍保留既有找回入口。边界及重载通过自动化。 |
| M09 导出 | 原生选择目录后生成唯一命名副本；读取确认中文便签、书架元数据/章节、宽度设置 420、说明文件存在；源数据未移动。递归目标、链接、参数失败由自动化覆盖。 |
| M10 布局 | 五个页面在内容区 860×620 和 720×500 均已截图检查，无明显遮挡与裁切；关闭、重开、最小化使用系统窗口控件。 |

截图见 [工作台](management/workspace.png)、[便签](management/notes.png)、[书架](management/books.png)、[自选股](management/stocks.png)、[设置](management/settings.png)，同目录 `-min` 为最小尺寸。截图窗口外黑色部分来自原生窗口截图的透明阴影区域。

## 独立审阅
`impeccable_finish_reviewer` 检查十张原生截图及主界面相关实现。初次 disposition 为 **fix**，唯一 P2 为小窗翻章后主界面阅读摘要不更新；修复后复核为 **resolved / ship**。对范围校正持久化的初步疑问经实际 `@Published` 行为验证撤回，并增加了校正后重载测试。

## 边界
没有宣称其他 macOS 版本、多显示器或完整辅助功能审计通过。本轮没有重复全部 M0 穿透/全屏矩阵，窗口行为单元测试及本机恢复链路已回归。数据副本按模块依次取快照，不承诺全局同一时刻，也不支持一键覆盖恢复。书架导入支持 TXT/EPUB；本轮管理页原生文件选择流程实测 TXT，EPUB 解析沿用已通过的阅读模块测试。未提交、推送或发布。

## 最终构建与启动
标准 Xcode 构建及测试成功；`build-local.sh` 回退构建通过；标准包 `codesign --verify --strict` 通过；`git diff --check` 通过。2026-11-07 17:06:10 已正常退出旧实例、启动标准 Debug 新版，确认进程 **95840** 路径 `.build/xcode/Build/Products/Debug/Oriel.app/Contents/MacOS/Oriel`，主界面工作台可见。QA 实例已退出，其测试数据归档至 `/tmp/OrielManagementQA.B0pBRL/app-support`，不留在用户正式数据域。

冷启动复核在同一执行段内等待初始化完成后读取：前台应用 Oriel，主窗口及「工作台」可访问；用户切回其他应用时窗口可能受系统窗口管理显示方式影响，不把后台瞬时截图缺失当作启动失败。
