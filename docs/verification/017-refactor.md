# 改造验收记录

对应 [改造方案](../plans/017-refactor-tasks.md)。每个任务完成后在此追加。

## R00 基线（2026-11-10）

**环境**：Mac16,10，Apple M4，32 GB 内存，macOS 26.6.2（25G83），Xcode 位于 `/Applications/Xcode.app`。

### 测试与构建

| 测试组 | 改造前 | 加入基线测试后 | 结果 |
|---|---|---|---|
| OrielCore | 54 | 54 | 全部通过 |
| OrielReading（含 OrielReaderUI） | 24 + 2 | 25 + 4 | 全部通过 |
| OrielTerminal | 6 | 6 | 全部通过 |
| OrielAppTests（xcodebuild） | 53 | 56 | 全部通过 |
| 合计 | 139 | 145 | |

`./scripts/build.sh` 构建成功。

新增的基线测试只报告耗时，不设速度断言：

- `OrielAppTests/PerformanceBaselineTests.swift`：P1–P3
- `Packages/OrielReading/Tests/OrielReaderUITests/ReaderPerformanceTests.swift`：P4–P5
- `Packages/OrielReading/Tests/OrielReadingTests/ShelfMemoryBaselineTests.swift`：P6

它们让应用测试多用约 21 秒、阅读包测试多用约 15 秒。只跑某一项：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Oriel.xcodeproj -scheme Oriel -destination 'platform=macOS' -derivedDataPath .build/xcode test -only-testing:OrielAppTests/PerformanceBaselineTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test -c release --package-path Packages/OrielReading --filter 'ReaderPerformanceTests|ShelfMemoryBaselineTests'
```

### 性能数值

| 编号 | 场景 | 结果 | 每次 |
|---|---|---|---|
| P1 | 1 MiB 便签保存一次（已有文件：读回校验、备份、原子写入） | 5 ms，波动 3.6% | 5 ms |
| P2 | 1 MiB 便签经真实编辑器代理连续输入 200 字 | 3.49 s，波动 0.9% | **约 17 ms/键** |
| P3 | 500 张便签（各约 2 KB）：带关键字过滤一次 + 全量列出一次 | 23 ms，波动 1.4% | 约 12 ms/次 `list` |
| P4 | 1 MiB 章节，仅改高度 30 次 | 2 ms | < 0.1 ms |
| P5 | 1 MiB 章节，改宽度 30 次 | 3.43 s（Release 3.47 s） | **约 115 ms/次** |
| P6 | 30 MiB TXT（2258 章）解码全部章节 | 94 ms；常驻 +47 MiB，两份 +95 MiB | |
| P7 | 1 个与 5 个小窗开启边缘唤醒，鼠标静止 60 秒的唤醒次数 | **未测**，见下 | |

P1–P3 为 Debug 构建；P4–P5 Debug 与 Release 数值相同，耗时在系统 TextKit 内；P6 为 Release。P5 用的是非实时缩放，每一步都会完整重排。

### P7 未测原因与手动步骤

需要在运行中的应用里新建小窗并打开边缘唤醒，本次会话没有能操作菜单栏小窗的工具。按代码推算：每个开启的小窗有一个 250 ms 兜底定时器，静止时约 4 次/秒，5 个小窗约 20 次/秒。

手动测量：

1. 打开 Oriel，新建 1 个小窗，点眼睛图标开启边缘唤醒，鼠标移到别处静止。
2. 运行 `top -l 2 -s 60 -stats pid,command,idlew -pid $(pgrep -x Oriel)`，记第二次采样的 IDLEW。
3. 再新建 4 个小窗都开启边缘唤醒，重复第 2 步。

### 结论与对方案的影响

1. **便签保存本身不慢**（P1 5 ms）。R01 的读回校验和硬链接备份仍值得做，但“移到后台队列”收益小、风险在数据可靠性上，改为只在更慢的磁盘上实测超过 16 ms 时再做。
2. **便签逐键输入是真问题**（P2 每键约 17 ms，已占满一帧）。R02 优先级上调。
3. **便签列表**（P3 每次约 12 ms）在每次按键都触发列表刷新时会叠加到 P2 上，R02 的“只在标题或状态变化时通知”同样必要。
4. **阅读器只有宽度变化慢**（P5 每次 115 ms，P4 可忽略）。R20 去掉“高度变化不重排”这一半，集中在宽度与实时缩放；步骤 B 的门槛（16 ms）已明显超过，可能需要做。
5. **书籍内存不需要改存储格式**（P6 单本 47 MiB < 150 MiB）。D5 结论：R21 只做缓存共享，步骤 B 不做。

## R02 便签逐键开销（2026-11-10）

### 剖析结论

R00 的 P2 每键 17 ms，拆分后与方案预想不同：上限检查只占 0.5 ms，主要开销是 `NoteDocument.edit` 里用 Swift `!=` 比较新旧全文（约 11 ms）。编辑器给出的是桥接 `NSString`，Swift 对它做 Unicode 规范等价比较，走慢路径。真实页面里 `NotesEditor.updateNSView` 每次刷新还会再比较一次，于是补测了挂真实 `NotesView` 的 P2b，基线为每键 32 ms。

尝试过先转成原生 UTF-8 再比较，单是转换就要约 19 ms，已放弃。

### 改动

- `NoteDocument.sameText`：用 `NSString` 逐码元比较。同一对象或长度不同时 O(1)，否则做码元比较。这是精确相等，规范等价但字节不同的文字现在会被当作修改并保存（原先会被忽略）。
- `edit` 与 `isDirty` 改用它；`isDirty` 先比较修改时间、置顶、删除状态，正文放最后。草稿的 `isDirty` 改为遇到第一个非空白字符即返回，不再复制全文。
- `NotesEditor.Coordinator` 记住最近与模型同步的文字，`updateNSView` 只在文字来自外部（恢复、接受保存结果）时才读取编辑器。
- `NotesWorkspace` 只在标题或保存状态变化时发出变更通知，正文中间输入不再刷新便签列表和各小窗的页签标题。

方案中的“增量字节计数”与“编辑器作为文字来源、延迟拉取全文”没有做：前者只占 0.5 ms，后者改动保存路径但已无必要。

### 测试

| 测试组 | 结果 |
|---|---|
| OrielCore | 54 通过 |
| OrielReading | 29 通过 |
| OrielTerminal | 6 通过 |
| OrielAppTests | 61 通过（新增 R02 测试 4 项、P2b 1 项） |

新增测试：规范等价但字节不同视为修改并能存盘；桥接字符串未变时不触发保存；工作区只在草稿首次有内容、标题变化、已保存便签变脏时通知；外部替换文字后编辑器跟随更新。原有便签测试（输入法组合不被自动保存打断、超限拒绝、撤销重做、保存失败保留正文等）全部通过。

`./scripts/build.sh` 与 `./scripts/build-local.sh` 均构建成功，已正常退出旧进程并启动新构建（12:51）。

### 性能对照（Debug）

| 编号 | 改造前 | 改造后 |
|---|---|---|
| P2 编辑器代理路径，每键 | 17.4 ms | 1.6 ms |
| P2b 真实便签页面，每键 | 32.0 ms | 1.3 ms |
| P1 保存 | 5 ms | 5 ms（未改） |
| P3 列表 | 12 ms/次 | 13 ms/次（未改；输入时已不再触发） |

### 尚未实机验证

- 1 MiB 便签实机输入的手感。
- 中文输入法连续选词（Spec 012 N06），自动化测试已覆盖“自动保存不打断组合”。
- 正文输入时便签列表不刷新：列表与正文不同时显示，但极小窗口下的列表浮层需要实机确认。

## R01 便签保存减负（2026-11-10）

- `NotesStore` 改为类，记住每个原件最近一次读写时的大小与修改时间。原件未被外部改动时，保存前不再读回并解码；被改动过的仍会先校验，损坏时抛错且不覆盖备份。
- 备份改为“硬链接到临时名 → `rename` 覆盖 `.backup`”，原件全程存在；硬链接失败时退回原来的整份拷贝。随后原子写入使原件成为新文件，备份保留上一版。
- 方案第 3 点（后台队列写盘）按 R00 结论暂缓。

新增测试 3 项：三次保存后备份是上一版且与原件不是同一个文件、没有残留临时链接；本进程写过或加载过的文件不再读回；原件被外部写坏后保存会重新校验并抛错、备份不变。原有便签与导出测试全部通过。

P1：5 ms → 3 ms（降约 40%，未达方案写的一半；剩余主要是 1 MiB 的 JSON 编码与原子写入）。

## R03 阅读位置保存节流（2026-11-10）

- `NovelLibrary` 把同一章内的滚动位置先记在内存，1 秒尾部延迟后写入 UserDefaults；换章、首次打开、切换书籍仍立即写入。
- 立即写入的时机：返回书架、关闭小说页签（`NovelSession.dispose`）、小窗隐藏或锁定、应用退出。
- 读取一律经 `NovelLibrary.place(for:)`，先查内存，书架进度与其他页签看到的是最新位置。`ReadingPlace` 补了公开初始化方法。

新增测试 2 项：同一章内 100 次位置变化在延迟前不写入、读取得到最新值、延迟后写入一次；换章、返回书架、关闭页签、手动刷新各自立即落盘。原有 5 项小说会话测试全部通过。

未实机验证：滚动阅读后立刻退出应用再打开，续读位置是否准确。
