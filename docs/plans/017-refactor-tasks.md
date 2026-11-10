# 架构、性能、UI 与交互改造方案

2026-11-10 起草。依据同日的源码评估；评估只读代码，没有构建、运行或实测，所以本方案把“先量再改”放在第一步。任务编号 R00–R51，可按阶段独立交付。

## 0. 范围与约束

**目标**

1. 把 `MiniPanel`（1284 行）拆到可维护的规模，新增一种页面不再需要改多处 `switch`。
2. 消除主线程上的同步 I/O 和逐键 O(n) 开销。
3. 补齐关闭终端的确认、编辑快捷键、颜色角色等一致性问题。
4. 可选：重启后恢复小窗与页签。

**沿用的既定决策（不在本方案内推翻）**

- 固定 Aqua 浅色外观、白灰中性配色（[DESIGN.md](../../DESIGN.md)）。**不做深色模式**；R40 只统一颜色来源，为以后留出口。
- 内容透明度作用于整个内容区（DESIGN.md「材质与行为」）。
- 没有发布要求（[PRODUCT.md](../../PRODUCT.md)）。签名与公证只列为附录。
- 数据保存失败必须可见，不能丢弃未保存文字。任何保存路径的改动都以此为硬约束。

**每个任务的固定流程**（与现有 plans 一致）

1. 行为有变化的，先改对应 spec，写明验收编号。
2. 先写会失败的测试，再实现。
3. 跑全部四组测试（见 R00），再 `./scripts/build.sh`。
4. 实机验证，结果记入 `docs/verification/017-refactor.md`。
5. 重启应用供体验。不自动提交或推送。

**新增源文件时必须同步三处**，否则构建会漏文件：

- `Oriel.xcodeproj/project.pbxproj`：`PBXBuildFile`、`PBXFileReference`、`OrielApp` 分组、应用的 Sources 阶段；有测试时还要加测试目标的 Sources 阶段。
- `scripts/build-local.sh` 的源文件清单（第 26 行起逐个列出）。
- 测试目标是直接编译应用源文件的，被测文件依赖的新文件也要加进测试目标。

## 1. 决策记录

2026-11-10 用户确认：

| 编号 | 问题 | 结论 | 影响 |
|---|---|---|---|
| D1 | 是否做重启后恢复？README 原写明“位置与尺寸不自动保存” | **做完整恢复**：窗口加页签，默认开启，设置里可关。锁定穿透与隐藏状态不恢复 | 阶段 4 全部执行，排在 R10、R11 之后 |
| D2 | 关闭带运行中任务的终端时是否确认？Spec 007 原规定直接挂断 | **加**：仅在有前台任务时询问，空闲 Shell 仍直接关闭；退出应用时汇总成一次询问 | 执行 R04，修订 Spec 007 |
| D3 | 便签 ⌘F 的含义？Spec 012 原定义为“列表/搜索” | **互换**：⌘F 查正文，⌥⌘F 打开列表搜索 | 执行 R06，修订 Spec 012 与 README |
| D4 | 是否给文字设 9 pt 下限？ | **设**，图标不受限 | 执行 R41，DESIGN.md 补一句规则 |
| D5 | 书籍存储是否改为分章文件？ | **暂不决定**：只做缓存共享；R00 测得单本内存超过约 150 MB 时再提出 | R21 只做步骤 A |

### R00 基线后的调整（2026-11-10）

数值见 [验收记录](../verification/017-refactor.md#r00-基线2026-11-10)。

- R01：保存一次仅 5 ms。做第 1、2 点；第 3 点（后台队列）暂缓，除非在更慢的磁盘上实测超过 16 ms。 已完成第 1、2 点，P1 5 → 3 ms。
- R02：每键约 17 ms，列为阶段 1 最优先。已完成：主要开销是桥接字符串的全文比较，改为码元比较后每键约 1.3 ms，未做增量计数与延迟拉取，详见验收记录。
- R20：仅改高度已可忽略，去掉对应步骤；宽度变化每次约 115 ms，步骤 B 预计需要做。
- R21 / D5：单本常驻 47 MiB，步骤 B 不做。
- R03：已完成，同一章内滚动改为 1 秒尾部写入。
- R04：已完成，四个关闭入口接入确认，待实机点验。
- P7 尚未实测，R14 开始前补测。

## 2. 阶段总览

| 阶段 | 内容 | 任务 | 风险 | 估算 |
|---|---|---|---|---|
| 0 | 基线测量 | R00 | 无 | 0.5 天 |
| 1 | 独立小改，直接见效 | R01–R06 | 低；R01 涉及数据可靠性 | 3 天 |
| 2 | 结构重构 | R10–R15 | 中；纯重构，靠测试与实机回归兜底 | 5 天 |
| 3 | 阅读器性能 | R20–R21 | 中；位置恢复精度 | 1.5 天 |
| 4 | 状态恢复 | R30–R32 | 中；新持久化格式 | 3 天 |
| 5 | UI 一致性 | R40–R42 | 低 | 1.5 天 |

估算是粗略的人日，未含实机验收等待时间。阶段 1 与阶段 2 的 R12 可并行；R10 之后再做阶段 4，页签恢复才有干净的接入点。

依赖关系：

```
R00 ─┬─ R01 ─ R02
     ├─ R03
     ├─ R04   R05   R06
     ├─ R12 ─ R10 ─ R11 ─┬─ R30 ─ R31 ─ R32
     │                   └─ R13 ─ R14
     ├─ R20 ─ R21
     └─ R40 ─ R41   R42
R15 可在 R13 之后任意时间做
```

## 3. 阶段 0：基线

### R00 记录测试与性能基线

**做什么**

1. 跑现有四组测试并记下各自的通过数：

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/OrielCore
   swift test --package-path Packages/OrielReading
   swift test --package-path Packages/OrielTerminal
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Oriel.xcodeproj -scheme Oriel -destination 'platform=macOS' test
   ```

2. 新增 `OrielAppTests/PerformanceBaselineTests.swift`，用 `measure {}` 记录：
   - P1 便签保存：1 MiB 便签调用 `NotesStore.save` 一次的耗时。
   - P2 便签输入：1 MiB 便签连续 200 次 `NoteDocument.edit` 的耗时。
   - P3 便签列表：500 张便签时 `NotesWorkspace.list(query:)` 的耗时。
3. 在 `Packages/OrielReading/Tests/OrielReaderUITests` 新增：
   - P4 阅读器布局：单章 1 MiB 文本，`NovelPageScroll` 宽度不变、高度变化 30 次的耗时。
   - P5 同上但宽度变化 30 次。
4. 实机用 Instruments 或活动监视器记录：
   - P6 打开一本接近 32 MiB 的书后的常驻内存；两个页签各开同一本时的内存。
   - P7 开启边缘唤醒的 1 个与 5 个小窗在鼠标静止 60 秒内的唤醒次数（`powermetrics` 或 Energy Log）。

**完成条件**：`docs/verification/017-refactor.md` 里有 P1–P7 的数值、机器型号和系统版本。后续任务用同一组测试对比。

**决策门槛**：P4 < 16 ms/次则 R20 只做步骤 A；P6 单本 < 150 MB 则 R21 只做缓存共享。

## 4. 阶段 1：独立小改

### R01 便签保存减负并移出主线程

**现状**：[NotesStore.swift:99](../../OrielApp/NotesStore.swift:99) 每次保存读回并解码旧文件、整份拷贝成备份、再原子写入，全部在主线程；停笔 300 ms 触发一次。

**设计**

1. **去掉重复校验**。`NotesStore` 增加 `verified: Set<UUID>`。加载成功或本进程写成功过的 id 记入其中；`save` 只对不在集合里的 id 做读回校验。校验失败的语义不变：不覆盖备份，抛错。
2. **备份改为硬链接**，省掉一次整文件读写：
   - `linkItem(at: primary, to: backup.tmp)`
   - `rename(backup.tmp → backup)`（POSIX `rename`，原子覆盖）
   - 原子写入 primary（写新 inode 再改名，备份仍指向旧内容）
   - 硬链接失败时回退到现有的拷贝方式。
   - 任一步骤失败后 primary 始终存在，不会出现“只有备份没有原件”的窗口，`load()` 不需要改。
3. **自动保存走后台串行队列**，关闭与退出仍然同步：
   - `NotesStore` 持有一个串行 `DispatchQueue`。
   - 计时器触发的 `save(commitEditing: false)`：主线程取出脏文档的 `NoteRecord` 快照 → 队列里写盘 → 回主线程，按“写入的那份 record”标记已保存。
   - `NoteDocument.saved()` 改为 `saved(_ written: NoteRecord)`，只把 `savedRecord` 设为实际写入的版本。写盘期间又有新输入时文档保持脏，并再排一次保存。
   - `saveAll()`、`saveForClosing(_:)`、`update(_:change:)` 用 `queue.sync` 同步执行，保证返回时已落盘。它们排在队列里，不会与进行中的后台写乱序。
4. [MiniPanel.swift:525](../../OrielApp/MiniPanel.swift:525) 切页签时的 `saveAll()` 保留，但 `save` 在没有脏文档时不再发 `objectWillChange`。

**先写的测试**（`NotesWorkspaceTests`、新建 `NotesStoreTests`）

- 连续保存两次后，备份文件内容等于第一次保存的内容。
- 原件被外部写坏后首次保存：抛错，备份保持原样。
- 同一 id 第二次保存不再读原件（给 store 注入可计数的文件读取闭包）。
- 后台写盘期间调用 `edit`：写完后文档仍为脏，磁盘上是旧版本，随后的保存写入新版本。
- 后台写盘期间调用 `saveForClosing`：返回时磁盘上是最新文字。
- 写盘失败：`errorMessage` 有值、文字保留、`isDirty` 为真。
- 现有 `NotesWorkspaceTests` 全部保持通过。

**完成条件**：P1 下降一半以上；Time Profiler 中输入时主线程不再出现 `NotesStore.save`；Spec 012 的 N04、N05、N14、N17 实机复测通过（含磁盘只读时的保存失败提示）。

**回退**：三处改动互相独立，可分别撤销。出现任何丢字迹象时先撤第 3 点。

### R02 便签逐键开销

**现状**：[NotesView.swift:328](../../OrielApp/NotesView.swift:328) 每次按键拼出完整候选字符串并数 UTF-8 字节；`textDidChange` 把整篇文字同步进模型；`NotesWorkspace` 每键发一次 `objectWillChange`，带动列表重排和各小窗刷新页签。

**设计**

1. `NoteDocument` 维护 `utf8Count`。`shouldChangeTextIn` 只算增量：`替换文字的字节数 − 被替换范围的字节数`，不再构造整篇候选串。
2. 编辑器成为输入期间的文字来源。`textDidChange` 只调用 `document.markEdited(firstLine:)`：更新 `updated`、脏标记，以及由首行算出的标题。整篇文字在以下时机才拉取：保存（含后台自动保存）、失焦、切换便签、复制、导出。
   - `NoteDocument` 增加 `pullText: (() -> String?)?`，由 `NotesEditor` 安装；有未确认的输入法组合时返回 `nil`，本次自动保存顺延，不打断选词。
   - `commitEditing` 语义不变，仍用于关闭和立即保存。
3. `NotesWorkspace` 只在标题、脏状态、置顶、删除状态变化时发 `objectWillChange`。`NoteStatus` 已单独观察文档，不受影响。

**先写的测试**

- 在 1 MiB 上限附近插入、替换、删除，`utf8Count` 始终等于 `text.utf8.count`；超限时拒绝并报错。
- 连续 `markEdited` 且首行不变时，workspace 不发变更通知；首行变化时发一次。
- 有输入法组合时自动保存顺延，组合结束后保存到正确文字。
- 关闭页签、关闭小窗、退出三条路径下，磁盘内容等于编辑器内容。

**完成条件**：P2 至少下降一个数量级；1 MiB 便签实机输入无可感延迟；中文输入法选词不被打断（Spec 012 N06）。

**依赖**：R01（保存路径已改为“写入的那份 record”）。

### R03 阅读位置保存节流

**现状**：滚动每变一次位置就写一次 UserDefaults（[ReadingPlaces.swift:27](../../Packages/OrielReading/Sources/OrielReading/ReadingPlaces.swift:27)）。

**设计**：`NovelLibrary.savePlace` 把位置记在内存字典 `pendingPlaces[bookID]`，1 秒尾部延迟后写入。以下时机立即写入：章节变化、`NovelSession.dispose()`、返回书架、小窗隐藏、`willTerminate`。`place(for:)` 先查内存再查 UserDefaults。

**先写的测试**（`NovelSessionTests`，注入独立的 `UserDefaults` 和可控时钟）

- 同一章内 100 次 `saveOffset`，延迟到期前 UserDefaults 写入 0 次，到期后 1 次且为最后的位置。
- 换章、`dispose`、返回书架各自立即落盘。
- 延迟期内另一个页签读取同一本书的位置，得到内存中的最新值。

**完成条件**：滚动期间 `defaults.set` 调用降到每秒至多 1 次；Spec 010 的续读验收复测通过。

### R04 关闭运行中的终端前确认

**现状**：`ShellTerminalView.hasForegroundJob` 已实现但没有任何调用。关闭页签、小窗和退出应用都直接挂断。

**设计**

1. 新增纯函数 `CloseGuard.busyTerminals(in:)`，输入各页签的终端状态，返回有前台任务的页签标题列表。
2. 三个入口调用：
   - `MiniPanel.closeTab`：该页签有前台任务时，在小窗上弹 sheet「终端中有任务正在运行」，按钮「结束并关闭」「取消」。
   - `MiniWindowSession.close`：列出本窗所有忙碌终端，一次询问。
   - `applicationShouldTerminate`：便签保存检查通过后，汇总所有小窗询问一次。这里是同步回调，用 `runModal`。
3. 主界面工作台的关闭确认已有 alert。有忙碌终端时把说明并进那一个 alert，不连弹两次。
4. Spec 007 表格中“关闭小窗或退出应用”一行补充确认条件。

**先写的测试**：`CloseGuardTests`——无终端、空闲 Shell、单个忙碌、多个忙碌、Shell 已退出五种输入。`OrielTerminalTests` 已有真实伪终端测试，补一条 `sleep` 期间 `hasForegroundJob == true`、结束后为 `false`。

**完成条件**：实机运行 `sleep 120` 后分别点页签 ×、小窗红点、⌘Q、工作台关闭，都出现一次确认；取消后任务仍在；确认后进程表里 Shell 和 sleep 均退出。空闲 Shell 关闭不询问。

### R05 文本框的编辑快捷键

**现状**：小窗是非激活面板，应用未激活时主菜单的键盘等价不生效。便签和浏览器各自手工转发了 ⌘A/C/X/V/Z，行情搜索框和小说搜索框没有。**此问题由代码推断，尚未实机确认。**

**步骤**

1. 先验证：让另一个应用保持激活，点小窗里的行情搜索框，试 ⌘V、⌘A、⌘Z。正常则本任务关闭并在验收记录中注明。
2. 确认有问题后，把 [MiniPanel.swift:651](../../OrielApp/MiniPanel.swift:651) 的转发从“仅浏览器页”改为“第一响应者是文本输入时一律转发”：⌘A、⌘C、⌘X、⌘V、⌘Z、⌘⇧Z 通过 `NSApp.sendAction(_:to:from:)` 发给响应链。
3. 终端页除外，SwiftTerm 自己处理。便签正文保留纯文本粘贴的专用实现。

**完成条件**：行情搜索、小说搜索、小说书内查找、便签搜索、浏览器地址栏、改名弹窗六处，在应用未激活时六个快捷键全部可用；终端里 ⌘C/⌘V 行为不变。

### R06 便签 ⌘F 改为正文查找

**设计**：`NotesTextView` 开启 `usesFindBar` 与 `isIncrementalSearchingEnabled`，⌘F 调 `performFindPanelAction`，⌘G / ⌘⇧G 找下一个和上一个；原“列表与搜索”改到 ⌥⌘F，菜单项「列表与搜索」的说明同步。内容区高度不足 68 pt 时查找栏放不下，⌘F 退回打开列表浮层。Spec 012 快捷键一节与 README 便签段落同步修改。

**完成条件**：常规尺寸下 ⌘F 出现查找栏并高亮匹配；⌥⌘F 打开列表并聚焦搜索框；Esc 关闭后焦点回正文；查找栏打开期间小窗不被边缘唤醒收起（`hasEditingFocus` 覆盖查找栏输入框）。

## 5. 阶段 2：结构重构

本阶段不改任何行为。每个任务结束时：四组测试通过、构建通过、按 `docs/verification/014-multiple-windows.md` 与 Spec 008 的清单做一遍实机回归。

### R12 拆出与页面无关的类（先做，纯移动）

从 `MiniPanel.swift` 原样移出，不改逻辑：

| 新文件 | 内容 |
|---|---|
| `OrielApp/PanelFrameViews.swift` | `PanelResizeEdge`、`BackgroundResizeCursor`、`PanelResizeHandle`、`PanelShadowView` |
| `OrielApp/LockRecoveryPanel.swift` | `LockRecoveryPanel` |
| `OrielApp/WindowSettingsPanel.swift` | `WindowSettingsPanel`、`OpacitySliderCell`、`WindowSettingsController` |

`private` / `fileprivate` 改为 `internal`；`MiniPanel` 中被手柄调用的 `startEdgeResize`、`dragEdge`、`endEdgeResize`、`hoveredResizeHandle` 同样放开。

**完成条件**：`MiniPanel.swift` 降到约 890 行；diff 里只有移动和可见性修改。

### R10 引入 `TabPage` 与 `PageFactory`

[PageKind.swift](../../OrielApp/PageKind.swift) 的注释已经写明这两个名字，本任务把它落地。

**接口**（`OrielApp/Pages/TabPage.swift`）

```swift
@MainActor
protocol TabPage: AnyObject {
    var kind: PageKind { get }
    var view: NSView { get }
    var title: String { get }
    var surface: PageSurface { get }              // .reading 或 .terminal

    /// 自动隐藏与折叠据此保持显示
    func hasEditingFocus(firstResponder: NSResponder?) -> Bool
    var keepsWindowVisible: Bool { get }

    func didActivate(in host: PageHost)           // 取得焦点等
    func willDeactivate()                         // 提交输入、暂停媒体
    func windowVisibilityChanged(_ visible: Bool) // 行情轮询
    func handleKeyEquivalent(_ key: String?, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> Bool

    var canGoBack: Bool { get }                   // 页面内后退，目前只有浏览器
    func goBack()
    func goForward()

    var isFinished: Bool { get }                  // Shell 已退出，返回首页时丢弃
    var noteID: UUID? { get }                     // 跨窗定位便签
    func dispose()
}

@MainActor
protocol PageHost: AnyObject {
    var window: NSWindow { get }
    var canManageTabs: Bool { get }
    var contentBounds: NSRect { get }
    func pageDidChangeTitle(_ page: TabPage)
    func pageDidFinish(_ page: TabPage)           // 终端 exit 后回首页
    func focusNoteElsewhere(_ id: UUID) -> Bool
    func noteIsOpenElsewhere(_ id: UUID) -> Bool
}

enum PageSurface { case reading, terminal }
```

`PageFactory.make(_ kind:, host:, environment:)` 是唯一按 `PageKind` 分支的地方。

**页签模型**：`Tab` 把 `terminal / browser / notes / novel / stocksView` 等字段换成 `pages: [PageKind: TabPage]` 加 `page: PageKind?`、`forwardPage: PageKind?`。回首页后页面对象保留，再次进入继续原会话，与现在一致。

**迁移顺序**（每迁一种就构建、测试、实机验证，再迁下一种）

| 步骤 | 页面 | 新文件 | 要搬的逻辑 |
|---|---|---|---|
| 1 | 自选股 | `Pages/StocksPage.swift` | `StocksView` 宿主、`StockChartHover`、`watchlistOwner` 与可见性上报 |
| 2 | 小说 | `Pages/NovelPage.swift` | `NovelSession`、导入面板、⌘O/⌘F/⌘D、`choosingFile` |
| 3 | 终端 | `Pages/TerminalPage.swift` | Shell 启动、`onExit`、标题跟随目录、配色 |
| 4 | 浏览器 | `Pages/BrowserPage.swift` | `BrowserView` 包装、⌘L/⌘R/⌘D/缩放、页内前进后退、暂停媒体 |
| 5 | 便签 | `Pages/NotesPage.swift` | `NotesSession`、跨窗定位、导出、⌘N/⌘F/⌘S、`observeNoteTitles` |

迁完后 `MiniPanel` 中这些位置的分支应当消失：`Tab.title`、`Tab.dispose`、`hasEditingFocus`、`keepsWindowVisible`、`activate`、`performKeyEquivalent` 的页面部分、`goBack` / `goForward`、`openPage` 与五个 `show*`。

**先写的测试**：`TabPageContractTests`——用一个假的 `PageHost` 逐一构造五种页面，断言 `kind`、初始 `title`、`dispose` 后不再回调宿主。便签页另测：已在别处打开的便签不会被选为初始文档。

**完成条件**

- `grep -n "case .terminal\|case .novel\|case .stocks\|case .notes\|case .browser" OrielApp/MiniPanel.swift` 无输出。
- 新增一种页面只需改 `PageKind`、新增一个 `TabPage` 实现、在 `PageFactory` 加一行。用一个临时的空白页面类型验证后删除。
- Spec 007–012、015 的实机清单各复测一遍。

**风险与对策**：便签页与窗口的耦合最深（保存失败时定位、跨窗互斥），放在最后迁；迁之前先把 `NotesWorkspaceTests` 中涉及页签的用例跑通作为护栏。

### R11 抽出页签控制器

**设计**：新建 `OrielApp/WindowTabs.swift`，不依赖 AppKit 窗口，持有页签数组、选中项和编号计数器：

```swift
@MainActor
final class WindowTabs {
    private(set) var tabs: [Tab]
    private(set) var selected: Tab
    func add() -> Tab
    func close(number: Int) -> CloseResult     // .notFound / .closedBackground / .selectNext(Tab) / .replacedWithHome(Tab)
    func tab(forShortcutDigit digit: Int) -> Tab?
    func neighbor(step: Int) -> Tab?
}
```

`MiniPanel` 保留“激活页签时对窗口做什么”（焦点、显示哪个视图），页签增删和快捷键映射交给 `WindowTabs`。

**先写的测试**（`WindowTabsTests`）：关闭选中页签选右邻，没有右邻选左邻；关闭最后一个得到新首页；关闭后台页签不改选中项；⌘1–8 与 ⌘9 的映射；Ctrl+Tab 首尾循环；编号不复用。

**完成条件**：`MiniPanel.swift` 降到 450 行以内；Spec 008 清单复测通过。

### R13 统一依赖与数据目录

**现状**：`NovelLibrary`、`StockWatchlist` 是注入的；`NotesWorkspace.shared`、`BrowserBookmarks.shared` 是单例；数据目录在三处各拼一次。

**设计**

1. 新增 `OrielApp/AppEnvironment.swift`：

   ```swift
   @MainActor
   struct AppEnvironment {
       let dataDirectory: URL
       let preferences: AppPreferences
       let notes: NotesWorkspace
       let library: NovelLibrary
       let watchlist: StockWatchlist
       let bookmarks: BrowserBookmarks
       static func live() -> AppEnvironment
   }
   ```

2. `AppModel` 创建一次并传给 `MiniWindowSession` → `MiniPanel` → `PageFactory`。
3. 逐个替换 `.shared` 的调用点（`AppModel`、`OrielAppDelegate`、`MiniPanel`、`NotesView`、`BrowserView` 的默认参数）。全部替换后删除 `static let shared`。
4. `AppModel.dataDirectory`、`NotesWorkspace` 和 `NovelLibrary` 里的路径拼接统一读 `environment.dataDirectory`。

**完成条件**：`grep -rn "\.shared" --include='*.swift' OrielApp` 只剩系统 API（`NSWorkspace.shared` 等）和 `AppModel.shared`；测试可以用临时目录构造完整环境。

### R14 合并指针采样

**现状**：每个开启边缘唤醒或悬停展开的小窗各装一对全局与本地监听，外加一个 250 ms 定时器（[MiniWindowSession.swift:178](../../OrielApp/MiniWindowSession.swift:178)）。

**设计**：新建 `OrielApp/PointerSampler.swift`，由 `AppModel` 持有。

- `register(id:handler:)` / `unregister(id:)`。从 0 到 1 时安装一对监听和一个兜底定时器，回到 0 时全部移除。
- 25 ms 合并、250 ms 兜底、监听安装失败时退回 30 ms，这三条规则原样搬过来。
- 每次采样读一次 `NSEvent.mouseLocation`，分发给所有已注册的小窗。
- `MiniWindowSession.synchronize()` 只负责按快照决定注册还是注销。

**先写的测试**（事件源和时钟可注入）：注册与注销的监听安装次数；N 个注册者每次采样各收到一次且位置相同；采样回调里注销自己不崩溃。

**完成条件**：P7 中 5 个小窗的唤醒次数接近 1 个小窗的水平；README 末尾关于边缘唤醒的全部规则逐条复测（慢速、快速、越过边缘直接落到中央、编辑中不隐藏）。

### R15 把纯模型下沉到包（可后置）

把不依赖界面的代码移进本地包，测试目标改为 `import`，不再重复编译应用源文件：

| 移动内容 | 去向 |
|---|---|
| `StockSymbol`、`StockQuote`、`DailyCandle`、`TencentMarket`、`StockWatchlist` | 新包 `Packages/OrielMarket` |
| `NoteRecord`、`NotesError`、`NotesStore` | 新包 `Packages/OrielNotes` |
| `BrowserModel.swift` 中的地址解析、缩放、UA、收藏夹 | 新包 `Packages/OrielBrowsing` |
| `ChromeLayout`、`PageKind` | 并入 `OrielCore` |

每移一组：建包、加 `XCLocalSwiftPackageReference`、迁移对应测试、从测试目标的 Sources 阶段删掉原文件。`scripts/build-local.sh` 的包源目录清单同步更新。

**完成条件**：`OrielAppTests` 的 Sources 阶段只剩测试文件和确实需要视图的源文件。

## 6. 阶段 3：阅读器性能

### R20 阅读器按需重排

**现状**：`restore(_:)` 每次调用 `ensureLayout(for: container)` 重排整章，任何尺寸变化都会触发，拖动缩放时每帧一次（[NovelPageView.swift:153](../../Packages/OrielReading/Sources/OrielReaderUI/NovelPageView.swift:153)）。

**步骤 A（必做）**

1. `setFrameSize` 区分宽高：只有宽度变化才需要重排；仅高度变化时只校正滚动位置，不调用 `ensureLayout`。
2. `inLiveResize` 期间宽度变化只记录锚点，不重排；在 `viewDidEndLiveResize` 里做一次完整 `restore`。拖动过程中文字按旧排版显示并被裁切，松手后归位。
3. 字号变化仍然完整重排。

**步骤 B（P4/P5 仍超过 16 ms 时才做）**

1. `manager.allowsNonContiguousLayout = true`。
2. `restore` 改为 `ensureLayout(forCharacterRange:)`，范围是章首到目标位置后一屏。
3. 文档高度不再手工用 `usedRect` 设置，交给 `NSTextView` 自己随排版增长。
4. 重点回归位置恢复：长章节末尾的书签、查找命中、续读位置的偏差不超过一行。

**先写的测试**（`ReaderViewportTests`）：高度变化 30 次，排版次数为 0（给 layout manager 设代理计数）；实时缩放期间宽度变化 30 次排版 0 次，结束后 1 次；缩放前后锚点字符不变；恢复到 offset 0、章中、章末三个位置的首行字符正确。

**完成条件**：P4 接近 0；P5 在实时缩放场景下只剩松手时的一次排版；Spec 010 的翻页、续读、查找、书签清单复测通过。

### R21 章节内存

**步骤 A（必做）**：`NovelLibrary` 加 `NSCache<NSString, ChapterBox>`，按书 id 缓存已解码章节。多个页签打开同一本书共用一份；`remove` 和重新下载时清掉对应项。

**步骤 B（本轮不做；P6 单本超过约 150 MB 时再向用户提出）**：存储格式 v2。

- `book.json` 增加 `schema: 2` 与章节索引（标题、字符数）。
- 正文按章写入 `chapters/00001.txt`。
- `NovelShelf` 提供 `chapter(of:at:)`，`NovelSession` 只持有当前章和相邻两章。
- v1 的书在首次打开时迁移：写到暂存目录再整体替换，失败则保留 v1 继续可读。
- `exportSnapshot` 不需要改，整目录拷贝对两种格式都成立。
- 书内查找改为逐章流式扫描。

**先写的测试**：v1 书架迁移后章节数和每章文字逐字相同；迁移中途失败后 v1 仍可打开；两个会话打开同一本书只解码一次。

**完成条件**：步骤 A 后 P6 的“两个页签同一本书”内存接近单页签；步骤 B 后单本内存与书的大小基本无关。

## 7. 阶段 4：状态恢复

### R30 规格

新增 `docs/specs/017-session-restore.md`，至少写明：

| 项目 | 恢复 | 说明 |
|---|---|---|
| 小窗名称、位置、尺寸、两项透明度 | 是 | 位置超出当前屏幕时收回可见区域 |
| 边缘唤醒、悬停展开 | 是 | |
| 锁定穿透、隐藏状态 | 否 | 启动后一律显示且未锁定，避免“找不到窗口” |
| 页签顺序与选中项 | 是 | |
| 便签页 | 是 | 记便签 id；便签已不存在则回首页 |
| 小说页 | 是 | 记书 id；位置沿用现有的阅读位置存储 |
| 自选股页 | 是 | |
| 浏览器页 | 是 | 只记当前网址，不恢复历史与表单 |
| 终端页 | 部分 | 恢复为终端页签，选中时启动新 Shell；不恢复输出与进程 |

设置里加「启动时恢复上次的小窗」，默认开启。关闭时行为与现在相同。README「使用」一节里“位置与尺寸不自动保存”同步修改。

### R31 存储与模型

**设计**

- 文件：`<数据目录>/Session/windows.json`，原子写入。

  ```json
  { "schema": 1,
    "windows": [ { "name": "小窗", "frame": [x, y, w, h],
                   "backgroundOpacity": 0.75, "contentOpacity": 0.75,
                   "automaticHiding": false, "automaticFolding": false,
                   "selectedTab": 0,
                   "tabs": [ { "kind": "notes", "note": "<uuid>" },
                             { "kind": "browser", "url": "https://…" },
                             { "kind": "home" } ] } ] }
  ```

- 新增 `OrielApp/SessionStore.swift`：`SessionState`（`Codable`）、`load()`、`save(_:)`。未知 `schema` 或解码失败时返回空状态，并把原文件改名为 `windows.json.unreadable` 保留。
- 写入时机：小窗创建与关闭、移动缩放结束、页签增删切换、页面标题或网址变化、透明度变化后 1 秒尾部延迟；`willTerminate` 立即写。
- `TabPage` 增加 `var restorationPayload: TabPayload? { get }`，`PageFactory` 增加按 payload 构造的入口。这是把 R10 排在本阶段之前的原因。
- 不纳入「导出数据」，在 Spec 013 中注明。

**先写的测试**（`SessionStoreTests`）：往返编码；未知 schema 得到空状态且原文件保留；位置在屏幕外时被收回（把屏幕可见区域作为参数传入）；便签或书不存在时该页签降级为首页；恢复关闭时不读取也不写入。

### R32 接入启动与退出

- `AppModel.init` 之后、`applicationDidFinishLaunching` 中按存储重建小窗。恢复出的小窗数为 0 时行为与现在一致。
- `AppModel.create` 拆成 `create(frame:name:opacities:tabs:)`，现有的“新建小窗”走默认参数。
- 浏览器页恢复时延迟加载：只有被选中的页签立即加载，其余在首次切换到时加载，避免启动时同时拉起多个网页进程。

**完成条件**：实机建 3 个小窗（不同位置、名称、透明度，共 6 个页签含五种页面）→ ⌘Q → 重开，逐项与退出前对比；拔掉外接显示器后重开，原本在副屏的小窗出现在主屏可见区域；删除一张已打开的便签对应的文件后重开，该页签显示首页且不报错；强制结束进程后重开，恢复到最近一次写入的状态。

## 8. 阶段 5：UI 一致性

### R40 统一颜色来源

**现状**：除 `OrielPalette` 外，阅读器正文用 `NSColor.labelColor`，行情和小说用 `.primary`、`Color.gray`、`.quaternary`、`.regularMaterial`，涨跌色写在 `StocksView` 里。现在不出问题只是因为强制了浅色外观。

**步骤**

1. `OrielPalette` 增加角色：`rise`（0xDB2E3B）、`fall`（0x088C47）、`highlight`（查找命中底色）、`notice`（提示条底色）、`marketHK`、`marketUS`。色值取现有代码里的值，观感不变。DESIGN.md 的 frontmatter 与颜色表同步。
2. `NovelPageView` 在 `OrielReaderUI` 包内，看不到 `OrielPalette`：给初始化方法加 `textColor` 与 `highlightColor` 参数，由 `NovelView` 传入。
3. 逐文件替换 `StocksView`、`StockChart`、`NovelView` 中的系统语义色。
4. 加一个检查脚本 `scripts/check-colors.sh`，内容为：

   ```sh
   ! grep -rnE "labelColor|Color\.primary|\.primary\b|\.quaternary|regularMaterial|Color\.gray|Color\(red:" \
       --include='*.swift' OrielApp Packages/OrielReading/Sources
   ```

   终端 ANSI 配色和 `OrielPalette.swift` 自身不在检查范围内。

**完成条件**：脚本退出码为 0；替换前后对同一窗口截图逐像素对比无差异（行情、阅读、查找命中三张）。

### R41 文字下限 9 pt

**范围**：`StocksView` 的市场徽标（7 pt）改为 9 pt 并相应放宽徽标内边距；列标题的排序箭头（7–8 pt）是图标，不动。逐一检查 `grep -rnE "size: [5-8](\)|,)" --include='*.swift' OrielApp` 列出的位置，属于文字的改为 9。DESIGN.md 补一句“文字不小于 9 pt，图标不受限”。

**完成条件**：246 pt 最小列表宽度下行情行不换行、不截断名称以外的列；120 × 90 最小窗口布局不变。

### R42 便签的阻塞式弹窗改为 sheet

**范围**：[NotesView.swift:92](../../OrielApp/NotesView.swift:92) 的「查看错误」与 `showRecovery()` 使用 `runModal`，会阻塞所有小窗。改为在所属小窗上 `beginSheetModal`。小窗过小放不下 sheet 时（宽度 < 200 pt）保留现有方式。`NotesWorkspace.confirmCanClose` 处于同步的关闭与退出路径上，保持 `runModal` 不变。

**完成条件**：一个小窗显示恢复提示时，另一个小窗仍可输入；sheet 显示期间小窗不被边缘唤醒收起（`keepsWindowVisible` 已覆盖 `attachedSheet`）。

## 9. 验收总表

记入 `docs/verification/017-refactor.md`，每项写明证据或未完成状态。

| 编号 | 内容 | 对应任务 |
|---|---|---|
| V01 | P1–P7 基线与改造后数值对照 | R00 及全部性能任务 |
| V02 | 便签可靠性：新实例从磁盘读回相同文字；保存失败可见、可重试、阻止关闭 | R01、R02 |
| V03 | 输入法选词不被自动保存打断 | R01、R02 |
| V04 | 续读位置在换章、关闭页签、退出后正确 | R03 |
| V05 | 忙碌终端四个关闭入口各确认一次；空闲不询问 | R04 |
| V06 | 六处文本框的六个编辑快捷键 | R05 |
| V07 | `MiniPanel.swift` ≤ 450 行且不含按页面类型的分支 | R10–R12 |
| V08 | Spec 007–012、014–016 实机清单全部复测 | R10、R11、R14 |
| V09 | 5 个小窗的空闲唤醒次数 | R14 |
| V10 | 阅读器缩放流畅；书签、查找、续读位置偏差不超过一行 | R20 |
| V11 | 重启恢复的四个场景 | R30–R32 |
| V12 | 颜色检查脚本通过；截图无差异 | R40 |

## 10. 完成审计

1. 每个 R 任务在验证记录里有：测试数变化、构建结果、实机证据。
2. 性能结论必须有 R00 同一测试的前后数值，不接受“感觉更快”。
3. 阶段 2 的每一步都能单独回退到上一个通过全部测试的状态。
4. 任何涉及便签保存的改动，发布前必须用真实数据目录的副本验证，不直接在用户数据上试。
5. 未做的任务和未确认的决策明确列出，不缩小范围后宣布完成。

## 附录：暂不纳入

| 事项 | 原因 | 以后要做时的入口 |
|---|---|---|
| 深色模式 | DESIGN.md 明确固定 Aqua | R40 完成后，把 `OrielPalette` 改为按外观取值 |
| 后台浏览器页签挂起 | README 已声明“隐藏网页不等于暂停全部任务”；挂起会丢页面状态 | `BrowserPage.willDeactivate` 里超时后卸载并记网址 |
| 三种“让路”模式合并为一个选择器 | 属于产品形态变化，需单独的规格 | Spec 001、016 |
| K 线图的点击与键盘入口 | 小改动，但需要设计触发方式 | `StocksPage` |
| 回收站彻底删除 | Spec 012 首版明确不自动清理 | `NotesStore` 增加 `purge` |
| Hardened Runtime、Developer ID 签名、公证 | PRODUCT.md 写明没有发布要求 | 另需评估 `CGSSetConnectionProperty` 私有符号 |
| 下载进度与确认 | 浏览器是辅助功能，优先级低 | `BrowserView` 的下载代理 |
