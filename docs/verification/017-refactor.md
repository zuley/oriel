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
