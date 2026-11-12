import AppKit
import XCTest

@MainActor
final class WindowChromeLayoutTests: XCTestCase {
    private func makeChrome() -> MiniWindowChromeView {
        MiniWindowChromeView(actions: .init(
            addTab: {}, selectTab: { _ in }, closeTab: { _ in },
            windowSettings: { _ in }, toggleLock: {}, hide: {}, close: {},
            drag: { _ in }))
    }

    func testToolbarAndTabSpaceRemainStableAcrossContentLockAndResize() {
        let chrome = makeChrome()
        chrome.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
        let reading = NSView()
        chrome.setTabs([ChromeTab(number: 1, title: "便签", kind: .notes)], selected: 1)
        chrome.showReadingSurface(reading)
        XCTAssertEqual(reading.frame.height, 306)
        XCTAssertEqual(reading.convert(reading.bounds, to: chrome).minY, 54)
        chrome.setTabs([ChromeTab(number: 1, title: "便签", kind: .notes),
                        ChromeTab(number: 2, title: "终端", kind: .terminal)], selected: 1)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(chrome.tabMode, .strip)
        XCTAssertEqual(reading.frame.height, 306)
        XCTAssertEqual(reading.convert(reading.bounds, to: chrome).minY, 54)

        let terminal = NSView()
        chrome.showTerminal(terminal)
        XCTAssertEqual(terminal.frame.height, 298)
        chrome.update(isLocked: true, automaticHiding: false)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame.height, 298)
        chrome.update(isLocked: false, automaticHiding: false)
        chrome.setFrameSize(NSSize(width: 120, height: 90))
        chrome.needsLayout = true
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame.height, 28)
        chrome.setTabs([ChromeTab(number: 1, title: "便签", kind: .notes)], selected: 1)
        chrome.showReadingSurface(reading)
        XCTAssertEqual(reading.frame.height, 36)
        let labels = chrome.subviews.compactMap { ($0 as? NSButton)?.accessibilityLabel() }
        XCTAssertTrue(labels.contains("新建页签"))
        XCTAssertTrue(labels.contains("窗口设置"))
        XCTAssertFalse(labels.contains { $0.contains("沉浸") })
    }

    func testShortWindowsShareTheToolbarWithTheTabSwitcher() {
        let chrome = makeChrome()
        chrome.frame = NSRect(x: 0, y: 0, width: 240, height: 150)
        let reading = NSView()
        chrome.setTabs([ChromeTab(number: 1, title: "便签", kind: .notes),
                        ChromeTab(number: 2, title: "终端", kind: .terminal)], selected: 2)
        chrome.showReadingSurface(reading)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(chrome.tabMode, .switcher)
        XCTAssertEqual(reading.convert(reading.bounds, to: chrome).minY, 32)
        XCTAssertTrue(chrome.subviews.contains { $0 is TabSwitcherButton && !$0.isHidden })
    }

    func testAddButtonAppearsAfterFirstContentTabAndAfterCompactSwitcher() throws {
        var added = 0
        let chrome = MiniWindowChromeView(actions: .init(
            addTab: { added += 1 }, selectTab: { _ in }, closeTab: { _ in },
            windowSettings: { _ in }, toggleLock: {}, hide: {}, close: {}, drag: { _ in }))
        chrome.layoutSubtreeIfNeeded()
        let toolbarAdd = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChromeButton }
            .first { $0.accessibilityLabel() == "新建页签" })
        XCTAssertTrue(toolbarAdd.isHidden)

        chrome.setTabs([ChromeTab(number: 1, title: "便签", kind: .notes)], selected: 1)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(chrome.tabMode, .strip)
        let strip = try XCTUnwrap(chrome.subviews.compactMap { $0 as? WindowTabStrip }.first)
        let stripAdd = try XCTUnwrap(strip.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "新建页签" })
        let chip = try XCTUnwrap(strip.subviews.first { !($0 is NSButton) })
        XCTAssertFalse(stripAdd.isHidden)
        XCTAssertEqual(stripAdd.frame.minX, chip.frame.maxX + 2)
        stripAdd.performClick(nil)
        XCTAssertEqual(added, 1)

        chrome.setFrameSize(NSSize(width: 240, height: 150))
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(chrome.tabMode, .switcher)
        let switcher = try XCTUnwrap(chrome.subviews.compactMap { $0 as? TabSwitcherButton }.first)
        XCTAssertFalse(toolbarAdd.isHidden)
        XCTAssertEqual(toolbarAdd.frame.minX, switcher.frame.maxX + 2)
        toolbarAdd.performClick(nil)
        XCTAssertEqual(added, 2)
    }

    func testNarrowTabStripKeepsAddBeforeOverflow() throws {
        let chrome = makeChrome()
        chrome.setFrameSize(NSSize(width: 120, height: 90))
        chrome.setTabs((1...4).map { ChromeTab(number: $0, title: "页签\($0)", kind: .notes) }, selected: 2)
        chrome.layoutSubtreeIfNeeded()
        let strip = try XCTUnwrap(chrome.subviews.compactMap { $0 as? WindowTabStrip }.first)
        let buttons = strip.subviews.compactMap { $0 as? NSButton }
        let add = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "新建页签" })
        let overflow = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "全部页签" })
        XCTAssertFalse(overflow.isHidden)
        XCTAssertLessThanOrEqual(add.frame.maxX + 2, overflow.frame.minX)
        XCTAssertGreaterThanOrEqual(add.frame.minX, 0)
    }

    func testDesktopButtonReportsItsOwnState() {
        let chrome = makeChrome()
        chrome.layoutSubtreeIfNeeded()
        XCTAssertTrue(chrome.spacesButton.isHidden)
        XCTAssertEqual(chrome.spacesButton.accessibilityValue() as? String, "当前桌面")
        XCTAssertEqual(chrome.spacesButton.accessibilityLabel(), "在所有桌面显示")
        chrome.setAppearsOnAllSpaces(true)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertFalse(chrome.spacesButton.isHidden)
        XCTAssertEqual(chrome.spacesButton.accessibilityValue() as? String, "所有桌面")
        XCTAssertEqual(chrome.spacesButton.accessibilityLabel(), "仅在当前桌面显示")
        let labels = chrome.subviews.compactMap { ($0 as? NSButton)?.accessibilityLabel() }
        XCTAssertTrue(labels.contains("窗口设置"))
        XCTAssertTrue(labels.contains("新建页签"))
    }

    func testEdgeRevealButtonReportsItsOwnState() {
        let chrome = makeChrome()
        chrome.update(isLocked: false, automaticHiding: true)
        XCTAssertEqual(chrome.edgeRevealButton.accessibilityValue() as? String, "边缘唤醒已开启")
        XCTAssertEqual(chrome.edgeRevealButton.accessibilityLabel(), "关闭边缘唤醒")
        chrome.update(isLocked: false, automaticHiding: false)
        XCTAssertEqual(chrome.edgeRevealButton.accessibilityValue() as? String, "边缘唤醒已关闭")
        XCTAssertEqual(chrome.edgeRevealButton.accessibilityLabel(), "开启边缘唤醒")
    }

    func testSettingsIconReportsHoverWithoutWaitingForClick() {
        var hoverChanges: [Bool] = []
        let chrome = MiniWindowChromeView(actions: .init(
            addTab: {}, selectTab: { _ in }, closeTab: { _ in },
            windowSettings: { _ in }, settingsHover: { hoverChanges.append($0) },
            toggleLock: {}, hide: {}, close: {}, drag: { _ in }))
        chrome.windowButton.onHover?(true)
        chrome.windowButton.onHover?(false)
        XCTAssertEqual(hoverChanges, [true, false])
    }

    func testCompactTabMenuClosesTheSelectedTabEvenWithDuplicateTitles() throws {
        var closed: [Int] = []
        let chrome = MiniWindowChromeView(actions: .init(
            addTab: {}, selectTab: { _ in }, closeTab: { closed.append($0) },
            windowSettings: { _ in }, toggleLock: {}, hide: {}, close: {},
            drag: { _ in }))
        chrome.frame = NSRect(x: 0, y: 0, width: 240, height: 150)
        let tabs = [ChromeTab(number: 7, title: "首页", kind: nil),
                    ChromeTab(number: 19, title: "首页", kind: nil)]
        for number in [19, 7] {
            chrome.setTabs(tabs, selected: number)
            chrome.layoutSubtreeIfNeeded()
            XCTAssertEqual(chrome.tabMode, .switcher)
            let item = try XCTUnwrap(chrome.makeTabMenu().items.first { $0.title == "关闭当前页签" })
            XCTAssertTrue(item.isEnabled)
            let action = try XCTUnwrap(item.action)
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        }
        XCTAssertEqual(closed, [19, 7])
    }

    func testTabMenuCannotCloseLockedOrRemovedTabs() throws {
        var closed: [Int] = []
        let chrome = MiniWindowChromeView(actions: .init(
            addTab: {}, selectTab: { _ in }, closeTab: { closed.append($0) },
            windowSettings: { _ in }, toggleLock: {}, hide: {}, close: {},
            drag: { _ in }))
        chrome.setTabs([ChromeTab(number: 7, title: "首页", kind: nil),
                        ChromeTab(number: 19, title: "首页", kind: nil)], selected: 19)
        let item = try XCTUnwrap(chrome.makeTabMenu().items.first { $0.title == "关闭当前页签" })
        let action = try XCTUnwrap(item.action)
        chrome.update(isLocked: true, automaticHiding: false)
        XCTAssertFalse(try XCTUnwrap(chrome.makeTabMenu().items.first { $0.title == item.title }).isEnabled)
        NSApplication.shared.sendAction(action, to: item.target, from: item)
        XCTAssertTrue(closed.isEmpty)
        chrome.update(isLocked: false, automaticHiding: false)
        chrome.setTabs([ChromeTab(number: 7, title: "首页", kind: nil)], selected: 7)
        NSApplication.shared.sendAction(action, to: item.target, from: item)
        XCTAssertTrue(closed.isEmpty)
    }

    func testRapidContentSwitchesKeepTheLatestPageFocusAndOpacity() throws {
        _ = NSApplication.shared
        let chrome = makeChrome()
        let tabs = [ChromeTab(number: 1, title: "首页", kind: nil),
                    ChromeTab(number: 2, title: "浏览器", kind: .browser)]
        chrome.setTabs(tabs, selected: 1)
        let panel = NSPanel(contentRect: chrome.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = chrome
        panel.orderBack(nil)
        defer { panel.close() }
        chrome.setContentOpacity(background: 0.6, content: 0.35)

        let field = NSTextField()
        chrome.showReadingSurface(field)
        panel.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor())
        chrome.setTabs(tabs, selected: 2)
        let surface = try XCTUnwrap(field.superview)
        let opacity = try XCTUnwrap(surface.layer).opacity
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertEqual(surface.alphaValue, 0.35)
        let fade = surface.layer?.animation(forKey: "oriel.contentSwitch") as? CABasicAnimation
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNil(fade)
        } else {
            XCTAssertNotNil(fade)
            XCTAssertEqual(try XCTUnwrap(fade?.toValue as? Float), opacity)
        }

        chrome.showHome()
        chrome.setTabs(tabs, selected: 1)
        chrome.showReadingSurface(field)
        panel.makeFirstResponder(field)
        chrome.setTabs(tabs, selected: 2)
        XCTAssertTrue(field.superview === surface)
        XCTAssertFalse(surface.isHidden)
        XCTAssertTrue(panel.firstResponder === field.currentEditor())
        XCTAssertEqual(surface.alphaValue, 0.35)
        XCTAssertEqual(surface.layer?.opacity, opacity)

        chrome.setContentOpacity(background: 0.6, content: 0.2)
        XCTAssertNil(surface.layer?.animation(forKey: "oriel.contentSwitch"))
        XCTAssertEqual(surface.alphaValue, 0.2)
        chrome.showHome()
        chrome.setTabs(tabs, selected: 1)
        chrome.update(isLocked: true, automaticHiding: false)
        let homeContainer = try XCTUnwrap(chrome.subviews.first { $0.subviews.contains { $0 is ChromeHomeView } })
        XCTAssertNil(homeContainer.layer?.animation(forKey: "oriel.contentSwitch"))
        XCTAssertTrue(surface.isHidden)
        XCTAssertEqual(homeContainer.alphaValue, 0.2)
    }

    func testFoldedChromeKeepsThePageSizeAndRestoresTheSameView() throws {
        let chrome = makeChrome()
        chrome.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
        chrome.setTabs([ChromeTab(number: 1, title: "首页", kind: nil),
                        ChromeTab(number: 2, title: "浏览器", kind: .browser)], selected: 2)
        let page = NSView()
        chrome.showReadingSurface(page)
        chrome.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(page.superview)
        let originalSize = page.frame.size
        chrome.setFolded(true)
        chrome.update(isLocked: false, automaticHiding: false, automaticFolding: true)
        chrome.setFrameSize(NSSize(width: 280, height: 28))
        chrome.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.isHidden)
        XCTAssertEqual(page.frame.size, originalSize)
        XCTAssertTrue(chrome.subviews.filter { $0 is WindowTabStrip || $0 is TabSwitcherButton }.allSatisfy(\.isHidden))
        XCTAssertFalse(chrome.foldButton.isHidden)
        XCTAssertTrue(chrome.foldButton.isEnabled)
        chrome.setFrameSize(NSSize(width: 280, height: 360))
        chrome.setFolded(false)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.isHidden)
        XCTAssertTrue(page.superview === host)
        XCTAssertEqual(page.frame.size, originalSize)
    }

    func testOverflowRevealsInactiveControlsAndKeepsEnabledFoldVisible() throws {
        var toggles = 0
        let chrome = MiniWindowChromeView(actions: .init(
            addTab: {}, selectTab: { _ in }, closeTab: { _ in },
            windowSettings: { _ in }, toggleFolding: { toggles += 1 },
            toggleLock: {}, hide: {}, close: {}, drag: { _ in }))
        chrome.setFrameSize(NSSize(width: 120, height: 90))
        chrome.layoutSubtreeIfNeeded()
        XCTAssertTrue(chrome.foldButton.isHidden)
        XCTAssertTrue(chrome.edgeRevealButton.isHidden)
        XCTAssertTrue(chrome.windowButton.isHidden)
        XCTAssertTrue(chrome.spacesButton.isHidden)
        let overflow = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChromeButton }
            .first { $0.accessibilityLabel() == "更多窗口操作" })
        let collapsedOverflowFrame = overflow.frame
        overflow.onHover?(true)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertTrue(overflow.isHidden)
        let lock = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChromeButton }
            .first { $0.accessibilityLabel() == "锁定穿透" })
        XCTAssertEqual(lock.frame, collapsedOverflowFrame)
        XCTAssertFalse(chrome.foldButton.isHidden)
        XCTAssertFalse(chrome.windowButton.isHidden)
        chrome.foldButton.performClick(nil)
        XCTAssertEqual(toggles, 1)
        chrome.update(isLocked: false, automaticHiding: false, automaticFolding: true)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(chrome.foldButton.accessibilityLabel(), "保持展开")
        overflow.performClick(nil)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertFalse(overflow.isHidden)
        XCTAssertFalse(chrome.foldButton.isHidden)
        XCTAssertTrue(chrome.windowButton.isHidden)
        overflow.onHover?(true)
        XCTAssertTrue(overflow.isHidden)
        chrome.update(isLocked: true, automaticHiding: false, automaticFolding: true)
        XCTAssertFalse(chrome.foldButton.isEnabled)
        chrome.update(isLocked: false, automaticHiding: false, automaticFolding: true)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertFalse(overflow.isHidden)
        XCTAssertEqual(overflow.accessibilityLabel(), "更多窗口操作")
    }

    func testCollapsingControlsStayVisibleUntilAnimationEndsAndCanReopen() throws {
        _ = NSApplication.shared
        let chrome = makeChrome()
        let panel = NSPanel(contentRect: chrome.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = chrome
        panel.orderBack(nil)
        defer { panel.close() }
        chrome.layoutSubtreeIfNeeded()
        let overflow = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChromeButton }
            .first { $0.accessibilityLabel() == "更多窗口操作" })
        let title = try XCTUnwrap(chrome.subviews.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "窗口名称" })
        let restingTitleWidth = title.frame.width

        overflow.performClick(nil)
        XCTAssertFalse(chrome.windowButton.isHidden)
        XCTAssertFalse(overflow.isHidden)
        overflow.performClick(nil)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(chrome.windowButton.isHidden)
            XCTAssertFalse(overflow.isHidden)
            return
        }
        XCTAssertFalse(chrome.windowButton.isHidden)
        overflow.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        XCTAssertTrue(overflow.isHidden)
        XCTAssertFalse(chrome.windowButton.isHidden)
        XCTAssertEqual(chrome.windowButton.alphaValue, 1)
        XCTAssertLessThan(title.frame.width, restingTitleWidth)
        XCTAssertFalse(title.isHidden)

        overflow.performClick(nil)
        XCTAssertFalse(chrome.windowButton.isHidden)
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        XCTAssertFalse(overflow.isHidden)
        XCTAssertTrue(chrome.windowButton.isHidden)
        XCTAssertEqual(chrome.windowButton.alphaValue, 1)
        XCTAssertEqual(title.frame.width, restingTitleWidth)
    }

    func testWindowTitleMovesWithOverflowAndReturnsAfterCollapse() throws {
        _ = NSApplication.shared
        let chrome = makeChrome()
        let panel = NSPanel(contentRect: chrome.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = chrome
        panel.orderBack(nil)
        defer { panel.close() }
        chrome.layoutSubtreeIfNeeded()
        let title = try XCTUnwrap(chrome.subviews.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "窗口名称" })
        let overflow = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChromeButton }
            .first { $0.accessibilityLabel() == "更多窗口操作" })
        let restingWidth = title.frame.width

        overflow.performClick(nil)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let presentedWidth = title.layer?.presentation()?.bounds.width ?? title.frame.width
            XCTAssertGreaterThan(presentedWidth, 80)
            XCTAssertLessThan(presentedWidth, restingWidth)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.18))
        let expandedWidth = title.frame.width
        XCTAssertLessThan(expandedWidth, restingWidth)

        overflow.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        XCTAssertEqual(title.frame.width, restingWidth)
        XCTAssertFalse(title.isHidden)
        XCTAssertEqual(title.alphaValue, 1)
    }

    func testNarrowTitleFadesOutAndBackWithoutStayingHidden() throws {
        _ = NSApplication.shared
        let chrome = makeChrome()
        chrome.setFrameSize(NSSize(width: 120, height: 90))
        let panel = NSPanel(contentRect: chrome.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = chrome
        panel.orderBack(nil)
        defer { panel.close() }
        chrome.layoutSubtreeIfNeeded()
        let title = try XCTUnwrap(chrome.subviews.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "窗口名称" })
        let overflow = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChromeButton }
            .first { $0.accessibilityLabel() == "更多窗口操作" })
        XCTAssertFalse(title.isHidden)

        overflow.performClick(nil)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(title.isHidden)
        } else {
            XCTAssertFalse(title.isHidden)
            RunLoop.current.run(until: Date().addingTimeInterval(0.22))
            XCTAssertTrue(title.isHidden)
        }
        overflow.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        XCTAssertFalse(title.isHidden)
        XCTAssertEqual(title.alphaValue, 1)
    }

    func testCompactTabSwitcherAndAddButtonMoveTogether() throws {
        _ = NSApplication.shared
        let chrome = makeChrome()
        chrome.setFrameSize(NSSize(width: 240, height: 150))
        chrome.setTabs([ChromeTab(number: 1, title: "便签", kind: .notes),
                        ChromeTab(number: 2, title: "终端", kind: .terminal)], selected: 1)
        let panel = NSPanel(contentRect: chrome.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = chrome
        panel.orderBack(nil)
        defer { panel.close() }
        chrome.layoutSubtreeIfNeeded()
        let switcher = try XCTUnwrap(chrome.subviews.compactMap { $0 as? TabSwitcherButton }.first)
        let add = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChromeButton }
            .first { $0.accessibilityLabel() == "新建页签" })
        let overflow = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChromeButton }
            .first { $0.accessibilityLabel() == "更多窗口操作" })
        let restingWidth = switcher.frame.width
        let restingAddX = add.frame.minX

        overflow.performClick(nil)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let switcherWidth = switcher.layer?.presentation()?.bounds.width ?? switcher.frame.width
            let addX = add.layer?.presentation()?.frame.minX ?? add.frame.minX
            XCTAssertLessThan(switcherWidth, restingWidth)
            XCTAssertLessThan(addX, restingAddX)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.18))
        XCTAssertEqual(add.frame.minX, switcher.frame.maxX + 2)
        overflow.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        XCTAssertEqual(add.frame.minX, restingAddX)
        XCTAssertEqual(switcher.frame.width, restingWidth)
    }
}
