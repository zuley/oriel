# Oriel · 半窗

一个常驻菜单栏的 macOS 小窗工具，可在独立页签使用终端、看自选股、读本地或在线小说。小窗支持锁定穿透、边缘唤醒和透明度调整。

## 开发

需要 macOS 14+、支持 Swift 6 的完整 Xcode。打开 `Oriel.xcodeproj`，选择 Oriel scheme，或在仓库目录运行：

```sh
./scripts/build.sh
open .build/xcode/Build/Products/Debug/Oriel.app
```

脚本只为当前进程选择 Xcode，不更改系统的 `xcode-select` 配置。若 Xcode 安装在其他位置：

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ./scripts/build.sh
```

运行行为测试：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path Packages/OrielCore
swift test --package-path Packages/OrielReading
swift test --package-path Packages/OrielTerminal
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Oriel.xcodeproj -scheme Oriel -destination 'platform=macOS' test
```

只有 Command Line Tools 时，`./scripts/build-local.sh` 可尝试生成 `.build/local/Oriel.app`，仅用于本地验证；不能替代标准 Xcode 构建验证。

## 使用

1. 点击菜单栏 **Oriel → 新建小窗**。
2. 新建默认显示内容展示首页。顶部设置仅包含 **背景透明度**、**内容透明度** 两个实时滑杆；向左调至完全透明，向右调至完全清晰。顶部按钮随背景透明度变化；内容透明度统一控制文字、插画、内容图标及装饰，设置浮层保持可见。
3. 开启 **锁定穿透**，鼠标点击和滚动将交给下面的应用。
4. 开启 **边缘唤醒**，离开窗口后隐藏，触碰原位置的边缘显示；进入内部保持显示。
5. 窗口隐藏或锁定时，选择 **Oriel → 恢复小窗**，即可显示、解锁并关闭自动隐藏。
6. 点击小窗左上角的红色按钮关闭小窗。**退出 Oriel** 释放窗口并退出菜单栏应用。

菜单栏始终提供 **退出 Oriel**。应用的标准 **小窗** 命令菜单提供完整管理操作，支持键盘与辅助访问。

窗口初始为 280 × 360 pt（紧凑布局），同时只创建一个。未锁定时，拖动顶部空白区移动窗口，拖动四边或四角调整大小；最小 120 × 90 pt。缩窄后隐藏浏览图标；设置始终只有两项透明度，首页空间不足时只显示居中图标；网页仍可在小视口内滚动。边缘唤醒区域跟随新位置与尺寸。位置与尺寸暂不保存到下次启动。

顶部眼睛切换边缘唤醒，锁图标切换锁定穿透，减号收起到菜单栏并停用自动隐藏，关闭按钮移除窗口。锁定后不能直接拖动或缩放，仍通过菜单栏“恢复小窗”恢复。

锁定时，**锁图标高亮，其他图标置灰**；再次点击锁图标恢复操作，保留边缘唤醒设置。只有锁图标区域接收鼠标，其余区域继续穿透。窗口隐藏时先触碰边缘唤醒，或通过系统菜单栏 **Oriel → 恢复小窗** 恢复（同时关闭自动隐藏）。

点击顶部工具栏的 **＋** 或按 **⌘T** 新建首页，点击页签切换。**Ctrl+Tab / Ctrl+Shift+Tab** 切换到下一页或上一页，**⌘1–8** 跳到指定位置，**⌘9** 跳到最后一页。空间不足时，从当前页的下拉列表选择全部页签。鼠标移入页签后，点右侧出现的 **×** 关闭该页，或按 **⌘W** 关闭当前页。关闭最后一页后回到新首页。各页签分别保留自己的阅读视图或终端会话。

点击首页的 **终端** 可在小窗内使用本机登录 Shell，初始目录为个人主目录。按 **⌘[** 返回首页，再点终端会继续原会话。输入 `exit` 返回首页，关闭小窗或退出 Oriel 会结束会话。窗口缩小时，首页保留终端、小说和自选股三个入口。

点击 **自选股** 查看腾讯财经行情。按代码、名称或拼音搜索，点「＋」添加，点「我的自选」可移除。自选列表保存在本机。可见时每 30 秒刷新，短时间重新唤醒可复用刚更新的报价。搜索中点刷新会重试当前关键词。

### 小说

- **导入本地书**。将 TXT 或无 DRM 的文字 EPUB 拖到首页或书架，也可进入「小说」按 **⌘O** 选择文件。单本直接打开，多本加入书架。导入后可移动原文件。
- **在线找书**。书库内置十五部中文作品。输入书名或作者可筛选，按回车或点「搜索全部中文藏书」会查询 Project Gutenberg 的中文目录。点击作品后下载整部源版本，之后可以断网阅读。
- **续读与找回原文**。书架按最近阅读排序。小窗记住章节和段落位置，**⌘F** 查找正文，**⌘D** 添加书签。阅读设置里可以调字号、切换简体或开启专注阅读。
- **翻页**。滚动或按空格向后翻页，**⇧空格** 向前翻页。到章末后再次按空格进入下一章。**← / →** 切换章节，底部目录可以直达指定章节。极小尺寸时从省略号菜单操作。

书籍与进度保存在本机。单份导入上限为 32 MiB，EPUB 按正文顺序提取文字。在线原文与版本说明可从阅读设置查看。[小说规格](docs/specs/010-novel-reader.md) · [实机验收与性能记录](docs/verification/010-novel-reader.md) · [书源目录](https://www.gutenberg.org/ebooks/offline_catalogs.html)

终端模块使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.10.1。EPUB 读取使用 [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) 0.9.20。首次构建需要联网解析 Swift Package 依赖。

边缘热区内外各 12 pt。开启边缘唤醒时，鼠标移动事件在 25 ms 内合并采样，静止时每 250 ms 复核；事件监听安装失败时回退到 30 ms 采样。终端或小说、股票搜索框拥有键盘输入焦点时，移出鼠标仍保持显示。除了直接命中边缘，同一窗口相邻两次实际采样从外扩保持区外进入区内时，也会补发唤醒，覆盖采样直接落到中央的情况。

没有采样历史时，首次落在中央不会唤醒；两次采样都在保持区外也不会显示，即使两点间的线段穿过窗口。关闭、恢复或切换自动隐藏会清除历史，旧窗口的采样不会影响新窗口；自动隐藏开关读取的位置只决定当下显隐，不作为连续采样历史。

2026-11-05：根据用户实测的卡顿、不灵敏和偶发漏触发反馈修订上述规则。修复后用户确认慢速、快速唤醒均正常；当时的记录保留在 M0 验收文档中。2026-11-07 的小说验收补测了锁定状态下边缘唤醒后的跨应用键盘输入。

## 实现与验收

- `Packages/OrielCore`：公开窗口行为控制接口、状态快照与 XCTest。
- `OrielApp`：菜单栏与 AppKit/WebKit 适配。自动唤醒不请求应用激活或 key window。
- [规格与验收条目](docs/specs/001-single-window-behavior.md)
- [参考图外观规格](docs/specs/002-reference-window-appearance.md)
- [拖动与缩放规格](docs/specs/003-move-resize.md)
- [T01–T10 任务计划](docs/plans/001-m0-tasks.md)
- [当前验证结果与限制](docs/verification/m0-acceptance.md)

自动化测试验证行为决策；真实鼠标穿透、焦点和全屏表现必须以实机记录为准。隐藏网页不等于暂停全部网页任务。M0 不含外部网页输入、持久化、多窗、表单输入或发布能力。
