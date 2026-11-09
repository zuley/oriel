import AppKit
import XCTest

@MainActor
final class WindowChromeLayoutTests: XCTestCase {
    private func makeChrome() -> MiniWindowChromeView {
        MiniWindowChromeView(actions: .init(
            addTab: {}, selectTab: { _ in }, closeTab: { _ in },
            windowSettings: { _ in }, toggleAutomaticHiding: {}, toggleLock: {}, hide: {}, close: {},
            drag: { _ in }))
    }

    func testToolbarAndTabSpaceRemainStableAcrossContentLockAndResize() {
        let chrome = makeChrome()
        chrome.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
        let reading = NSView()
        chrome.setTabs([ChromeTab(number: 1, title: "便签", kind: .notes)], selected: 1)
        chrome.showReadingSurface(reading)
        XCTAssertEqual(reading.frame.height, 328)
        XCTAssertEqual(reading.convert(reading.bounds, to: chrome).minY, 32)
        chrome.setTabs([ChromeTab(number: 1, title: "便签", kind: .notes),
                        ChromeTab(number: 2, title: "终端", kind: .terminal)], selected: 1)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(chrome.tabMode, .strip)
        XCTAssertEqual(reading.frame.height, 306)
        XCTAssertEqual(reading.convert(reading.bounds, to: chrome).minY, 54)

        let terminal = NSView()
        chrome.showTerminal(terminal)
        XCTAssertEqual(terminal.frame.height, 298)
        chrome.update(isLocked: true, automaticHiding: true)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame.height, 298)
        chrome.update(isLocked: false, automaticHiding: false)
        chrome.setFrameSize(NSSize(width: 120, height: 90))
        chrome.needsLayout = true
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame.height, 28)
        chrome.setTabs([ChromeTab(number: 1, title: "便签", kind: .notes)], selected: 1)
        chrome.showReadingSurface(reading)
        XCTAssertEqual(reading.frame.height, 58)
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

    func testEdgeRevealButtonReportsItsOwnState() {
        let chrome = makeChrome()
        chrome.update(isLocked: false, automaticHiding: true)
        XCTAssertEqual(chrome.edgeRevealButton.accessibilityValue() as? String, "边缘唤醒已开启")
        XCTAssertEqual(chrome.edgeRevealButton.accessibilityLabel(), "关闭边缘唤醒")
        chrome.update(isLocked: false, automaticHiding: false)
        XCTAssertEqual(chrome.edgeRevealButton.accessibilityValue() as? String, "边缘唤醒已关闭")
        XCTAssertEqual(chrome.edgeRevealButton.accessibilityLabel(), "开启边缘唤醒")
        let labels = chrome.subviews.compactMap { ($0 as? NSButton)?.accessibilityLabel() }
        XCTAssertTrue(labels.contains { $0.contains("边缘唤醒") })
        XCTAssertTrue(labels.contains("窗口设置"))
        XCTAssertTrue(labels.contains("新建页签"))
    }

    func testCompactTabMenuClosesTheSelectedTabEvenWithDuplicateTitles() throws {
        var closed: [Int] = []
        let chrome = MiniWindowChromeView(actions: .init(
            addTab: {}, selectTab: { _ in }, closeTab: { closed.append($0) },
            windowSettings: { _ in }, toggleAutomaticHiding: {}, toggleLock: {}, hide: {}, close: {},
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
            windowSettings: { _ in }, toggleAutomaticHiding: {}, toggleLock: {}, hide: {}, close: {},
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
}
