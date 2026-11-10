import AppKit
import XCTest

/// R11: tab bookkeeping without a window.
@MainActor
final class WindowTabsTests: XCTestCase {
    private func make(_ count: Int) -> WindowTabs {
        let tabs = WindowTabs()
        for _ in 1..<count { tabs.select(tabs.add()) }
        return tabs
    }

    func testStartsWithOneHomeTabAndNumbersAreNeverReused() {
        let tabs = WindowTabs()
        XCTAssertEqual(tabs.tabs.map(\.number), [1])
        XCTAssertNil(tabs.selected.page)
        XCTAssertEqual(tabs.selected.title, "首页")
        let second = tabs.add()
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(tabs.selected.number, 1, "Adding does not select.")
        _ = tabs.remove(number: 2)
        XCTAssertEqual(tabs.add().number, 3)
    }

    func testClosingTheSelectedTabSelectsTheRightNeighborThenTheLeft() throws {
        let tabs = make(3)                     // 1 2 [3]
        tabs.select(try XCTUnwrap(tabs.tab(number: 2)))
        guard case .selectNext(let next)? = tabs.remove(number: 2)?.next else { return XCTFail() }
        XCTAssertEqual(next.number, 3)
        tabs.select(next)
        guard case .selectNext(let left)? = tabs.remove(number: 3)?.next else { return XCTFail() }
        XCTAssertEqual(left.number, 1)
    }

    func testClosingABackgroundTabKeepsTheSelection() throws {
        let tabs = make(3)
        guard case .background? = tabs.remove(number: 1)?.next else { return XCTFail() }
        XCTAssertEqual(tabs.selected.number, 3)
        XCTAssertEqual(tabs.tabs.map(\.number), [2, 3])
        XCTAssertNil(tabs.remove(number: 99))
    }

    func testClosingTheLastTabLeavesAFreshHomeTab() {
        let tabs = WindowTabs()
        guard case .replacedWithHome(let home)? = tabs.remove(number: 1)?.next else { return XCTFail() }
        XCTAssertEqual(tabs.tabs.map(\.number), [home.number])
        XCTAssertEqual(home.number, 2)
        XCTAssertNil(home.page)
    }

    func testUnknownAndForeignTabsCannotChangeSelection() {
        let tabs = make(3)
        let selected = tabs.selected
        tabs.select(WindowTabs().selected)
        XCTAssertTrue(tabs.selected === selected, "Another window can have the same tab number.")
        XCTAssertNil(tabs.remove(number: 99))
        XCTAssertTrue(tabs.selected === selected)
        XCTAssertEqual(tabs.tabs.count, 3)
    }

    func testRemovalReturnsThePageForTheWindowToDisposeAfterSaving() throws {
        let tabs = make(2)
        let page = FakePage(kind: .notes)
        let closed = tabs.selected
        closed.page = .notes
        closed.pages[.notes] = page
        let removal = try XCTUnwrap(tabs.remove(number: closed.number))
        XCTAssertTrue(removal.removed === closed)
        XCTAssertTrue(removal.removed.current === page)
        XCTAssertEqual(page.disposals, 0, "The window clears focus before disposing the removed page.")
        removal.removed.dispose()
        XCTAssertEqual(page.disposals, 1)
        XCTAssertTrue(removal.removed.pages.isEmpty)
    }

    func testDisposeReleasesAllRetainedPagesExactlyOnce() {
        let tabs = make(2)
        let first = FakePage(kind: .notes)
        let second = FakePage(kind: .browser)
        tabs.tabs[0].pages[.notes] = first
        tabs.selected.pages[.browser] = second
        // Both tabs are on home; their cached pages still need cleanup.
        tabs.dispose()
        XCTAssertTrue(tabs.tabs.isEmpty)
        XCTAssertTrue(tabs.selected.pages.isEmpty, "The selected reference must not retain disposed pages.")
        XCTAssertEqual(first.disposals, 1)
        XCTAssertEqual(second.disposals, 1)
        tabs.dispose()
        XCTAssertEqual(first.disposals, 1)
        XCTAssertEqual(second.disposals, 1)
    }

    func testDigitMappingWithMoreThanNineTabsAndLeftWrap() {
        let tabs = make(10)
        for digit in 1...8 { XCTAssertEqual(tabs.tab(forShortcutDigit: digit)?.number, digit) }
        XCTAssertEqual(tabs.tab(forShortcutDigit: 9)?.number, 10)
        XCTAssertNil(tabs.tab(forShortcutDigit: 0))
        XCTAssertNil(tabs.tab(forShortcutDigit: 10))
        tabs.select(tabs.tabs[0])
        XCTAssertEqual(tabs.neighbor(step: -1)?.number, 10)
    }

    private final class FakePage: TabPage {
        let kind: PageKind
        let view = NSView()
        let title = "测试页"
        var disposals = 0
        init(kind: PageKind) { self.kind = kind }
        func dispose() { disposals += 1 }
    }

    func testDigitShortcutsAndCycling() {
        let tabs = make(4)                     // 1 2 3 [4]
        XCTAssertEqual(tabs.tab(forShortcutDigit: 1)?.number, 1)
        XCTAssertEqual(tabs.tab(forShortcutDigit: 3)?.number, 3)
        XCTAssertNil(tabs.tab(forShortcutDigit: 5), "⌘5 with four tabs does nothing.")
        XCTAssertEqual(tabs.tab(forShortcutDigit: 9)?.number, 4, "⌘9 is always the last tab.")
        XCTAssertEqual(tabs.neighbor(step: 1)?.number, 1, "Ctrl-Tab wraps from the last tab to the first.")
        XCTAssertEqual(tabs.neighbor(step: -1)?.number, 3)
        XCTAssertNil(WindowTabs().neighbor(step: 1), "One tab: nothing to cycle.")
    }
}
