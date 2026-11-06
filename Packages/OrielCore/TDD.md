# OrielCore：实际 TDD 执行记录

日期：2026-11-05。

测试边界为用户已经确认的 `WindowBehaviorController` 公开命令与 `snapshot`，不测试内部函数、计时器或 AppKit 属性。所有测试以 `@MainActor` 执行，调用者不能修改快照。

## 环境与命令

最初使用 Command Line Tools 的 `swift test` 无法导入 XCTest；这是环境失败，不算行为红灯。补充 `CoreGraphics` 导入解决 CGRect 的 Equatable overlay 后，模块本身可编译。

完整 Xcode 安装后，首次命令因许可未接受而返回 69。用户明确同意且在 Xcode 完成接受流程后，下面的命令运行了真正的 XCTest：

```sh
cd Packages/OrielCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

下列每轮都先增加一条行为测试，运行并观察断言失败，再只补足该行为的最小实现，随后运行完整现有测试集。没有通过修改测试预期消除失败。

## 红绿切片

| 次序 | 行为 | 实际红灯 | 最小实现后 |
| --- | --- | --- | --- |
| 01 | 锁定且隐藏的窗口命中边缘后显示，保留锁定和透明度 | 1 条测试，1 个失败；可见性为 false，预期 true | 1 条通过 |
| 02 | 恢复同时显示、解锁、关闭自动隐藏 | 2 条测试，3 个失败；恢复命令尚未改变三个状态 | 2 条通过 |
| 03 | 关闭后不能被鼠标或恢复命令复活 | 3 条测试，1 个失败；关闭后仍有快照 | 3 条通过 |
| 04 | 重建窗口忽略旧窗口的采样 | 4 条测试，1 个失败；旧 ID 意外唤醒新窗口 | 4 条通过 |
| 05 | 已存在窗口时创建操作不覆盖配置 | 5 条测试，2 个失败；返回新 ID 且覆盖快照 | 5 条通过 |
| 06 | 隐藏时直接跳入中央不唤醒 | 6 条测试，1 个失败；中央被错误视为热区 | 6 条通过 |
| 07 | 边缘唤醒后进入内容内部保持显示 | 7 条测试，1 个失败；仅检查热区导致进入内部又隐藏 | 7 条通过 |
| 08 | 指针位于保持区内时开启自动隐藏仍保持显示 | 8 条测试，1 个失败；开启开关总是隐藏 | 8 条通过 |
| 09 | 关闭自动隐藏立即显示，保留锁定 | 9 条测试，1 个失败；指针在外时关闭开关仍隐藏 | 9 条通过 |
| 10 | 恢复后，指针采样不能再次隐藏窗口 | 10 条测试，1 个失败；采样尚未检查自动隐藏开关 | 10 条通过 |

首条真实断言红灯出现在 `testLockedHiddenWindowRevealsAtEdgeWithoutLosingLockOrOpacity`；XCTest 总结为 `Executed 1 test, with 1 failure`。该条最小实现后的总结为 `Executed 1 test, with 0 failures`。

## 已实现规则的补充覆盖

以下测试逐条加入，第一次运行即通过，不将其误记为新增行为的红绿循环：

- `testAllOuterAndInnerBoundariesCanWakeHiddenWindow`：17 个固定位置，覆盖四边、内外边界、八个角点及内缘可达位置。
- `testLeavingAnySideHidesWindowAndRepeatedOutsideSamplesDoNotWakeIt`：5 个固定位置，覆盖离开四边及外部重复采样。
- `testLockChangesPreserveVisibilityAndAutomaticHiding`：常显、自动隐藏中、自动显示中三种状态下锁定与解锁的独立性。
- `testCreatedWindowStartsVisibleUnlockedWithoutAutomaticHiding`：审阅后补齐 AC01，验证创建时提供的 320 × 240 pt frame、默认透明度 1、可见、未锁定、未开启自动隐藏；既有实现首次即通过，没有修改实现。

初版完整 XCTest 结果：**14 条测试，0 个失败**。几何预期来自规格中的固定坐标与显式边界数值，未在断言中重复热区计算公式。

## 实机反馈后的漏唤醒修复

用户报告边缘唤醒卡顿、不灵敏且有时无效。以下复现确认其中一种漏触发：隐藏且锁定，先实际采样 `(80,150)`，再采样 `(150,150)`，跨过热区进入中央后仍不显示。它不证明用户全部卡顿都来自同一原因。依据反馈同步修订 Spec 001 的 AC03，保留 30 ms 与 12 pt，仅补充连续采样由外到内的唤醒判断。

复现命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/OrielCore --filter WindowBehaviorControllerTests.testFastPointerEntryAcrossEdgeWakesWindow
```

| 次序 | 行为 | 实际红灯 | 最小实现后 |
| --- | --- | --- | --- |
| 11 | 快速从区外跨过边缘进入中央仍唤醒，保留锁定 | 16:44、16:49 重现 `Optional(false)` 不等于预期 `Optional(true)`；与直接命中边缘的通过用例对照 | 记录有效的上次实际采样并判断外→内；16:50 全部 15 条通过，原首次中央负例仍通过 |
| 12 | 重新开启自动隐藏不能沿用上次开启期间的指针历史 | 16:50 新用例实际 `Optional(true)`，预期 `Optional(false)`；1 条、1 个失败 | 自动隐藏开关清空历史；全部 16 条通过 |

随后逐条补充的 `testFastPassAcrossEntireWindowDoesNotFlashIt` 和 `testOldWindowSamplesCannotArmNewWindowForCentralReveal` 首次即通过，没有制造红灯。快速跨入用例补充透明度 0.4 不变的断言；原中央负例更名为 `testHiddenWindowDoesNotWakeWhenFirstSampleIsAtCenter`，反映修订后的准确语义。关闭与恢复同时清理历史，避免留下已结束周期的记录。

16:51 完整 XCTest：**18 条，0 个失败**；16:52 在关闭/恢复清理后再次全量通过。随后用户实机复测确认慢速、快速唤醒均正常，本次报告的唤醒稳定性问题通过复测；焦点明确为“暂未测试”。该实机反馈独立于自动化结果，其余验收项见验收记录。

## 顶部减号：收起到菜单栏

用户要求按参考图复刻外观，顶部减号接入真实的收起操作。新增公开 `hide()`：保留窗口身份、位置、透明度与锁定，隐藏窗口并关闭自动显隐、清空采样历史；边缘采样不能重新显示收起的窗口，菜单栏恢复命令仍可恢复操作。这不是系统 Dock 最小化。

先添加 `testHidePreservesWindowConfigurationAndPreventsPointerReveal` 与空 `hide()` 方法，然后执行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/OrielCore --filter WindowBehaviorControllerTests.testHidePreservesWindowConfigurationAndPreventsPointerReveal
```

17:12:06 实际红灯：**1 条测试、2 个失败**；边缘采样后 `automaticHiding` 与 `isVisible` 仍为 true，预期均为 false。最小实现仅清空指针历史、设置隐藏与关闭自动显隐。17:12:26 执行完整 XCTest 后，**19 条测试、0 个失败**。

同时根据新的应用默认尺寸，将已有创建状态测试的输入和预期 frame 更新为 320 × 480 pt；其他几何 fixture 保持原值。这是既有行为的覆盖输入更新，不记为新增红绿循环。

## 顶部拖动与边角缩放：几何同步和手势期间显隐

本轮仅扩展公开窗口控制接口，不测试 NSWindow 私有状态或 AppKit 通知实现。新增 `updateFrame(_:for:)`、`beginGeometryChange(for:)`、`endGeometryChange(pointer:for:)`，快照 frame 对模块外仍只读。以下行为逐条先增加测试（需要新接口时先提供可编译空方法），运行真实断言红灯，再写最小实现并完整回归。

实际执行命令与此前相同：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/OrielCore
```

| 切片 | 行为 | 实际红灯 | 实现后完整回归 |
| --- | --- | --- | --- |
| G01 | 更新 frame 后新热区生效、旧热区失效，保留其余配置 | 20 条测试，3 个失败；frame 未更新，旧热区仍唤醒、新热区未唤醒 | 20 条通过 |
| G02 | 旧窗口的 frame 更新不能修改新窗口 | 21 条测试，1 个失败；新窗口 frame 被旧 ID 改写 | 21 条通过 |
| G03 | 几何变化清除旧采样轨迹 | 22 条测试，1 个失败；旧坐标历史导致新 frame 中央被唤醒 | 22 条通过 |
| G04 | 相同 frame 的重复通知保留采样轨迹 | 23 条测试，1 个失败；本应完成的快速跨入因历史被清空而失效 | 23 条通过 |
| G05 | 拒绝非有限坐标/尺寸、零或负尺寸，并保留现有状态和轨迹 | 24 条测试，16 个失败，来自 8 个无效 frame 的状态与唤醒断言 | 24 条通过 |
| G06 | 有效几何手势期间，指针离开也不能自动隐藏窗口 | 25 条测试，1 个失败；手势期间窗口隐藏 | 25 条通过 |
| G07 | 手势结束按最终 frame 和当前指针重新判定，随后恢复正常采样 | 26 条测试，1 个失败；指针在新 frame 外仍保持显示 | 26 条通过 |
| G08 | 已锁定或已隐藏的窗口不能开始几何手势 | 27 条测试，2 个失败；不合法的开始操作暂停了正常显隐 | 27 条通过 |
| G09 | 收起、恢复、关闭/重建结束几何手势 | 28 条测试，2 个失败；收起或恢复后仍残留显隐暂停 | 28 条通过 |
| G10 | 锁定中断正在进行的几何手势，后续区外采样可正常隐藏 | 29 条测试，1 个失败；锁定后仍因旧手势而暂停显隐 | 29 条通过 |

锁定中断只在存在活动几何手势时清空手势和指针历史，不改变普通锁定切换的连续采样行为。有效 frame 更新只改 frame；手势期间的窗口显示、透明度、锁定与自动隐藏配置分别保留。旧 ID 的几何命令在任何状态更新之前被拒绝。

随后逐条增加 3 条既有规则覆盖，均首次通过，未计作新增红绿循环：

- `testOldGeometryCommandsCannotInterruptCurrentWindowGesture`：旧 ID 的开始、结束不能取消当前窗口手势。
- `testEndingGeometryChangePreservesVisibilityInsideOrWhenAutomaticHidingIsOff`：结束时在新 frame 内保持显示；自动隐藏关闭时在外也保持显示，结束后正常响应采样。
- `testOrdinaryLockingPreservesPointerHistoryForFastEntry`：没有几何手势时，普通锁定不清除快速跨入所需的历史。

本轮最终完整 XCTest：**32 条测试，0 个失败**。真实顶部拖动、四边四角命中和 NSWindow frame 同步仍需由应用实机验证提供证据。

## 证据边界

这些结果证明窗口行为决策符合规格，不证明真实鼠标穿透、焦点分配、全屏层级或资源释放。后者由应用实机验收记录提供。
