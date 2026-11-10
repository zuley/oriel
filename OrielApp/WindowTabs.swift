import Foundation

/// One tab of a mini window: the page on screen and every page it opened.
@MainActor
final class WindowTab {
    let number: Int
    /// nil means the new-tab (home) page.
    var page: PageKind?
    /// The page `goBack` came from, still offered by `goForward`.
    var forwardPage: PageKind?
    /// Every page this tab opened, kept so returning to one resumes it.
    var pages: [PageKind: TabPage] = [:]

    init(number: Int) { self.number = number }

    var current: TabPage? { page.flatMap { pages[$0] } }
    var title: String { current?.title ?? "首页" }

    func dispose() {
        for page in pages.values { page.dispose() }
        pages.removeAll()
    }
}

/// The tabs of one mini window, independent of AppKit: order, selection, numbering and
/// the tab shortcuts. The window decides what showing a tab means.
@MainActor
final class WindowTabs {
    private(set) var tabs: [WindowTab]
    private(set) var selected: WindowTab
    /// Tab numbers identify tabs in the strip and menus; they are never reused.
    private var nextNumber = 2

    enum AfterRemoval {
        /// A tab in the background closed; the selection is unchanged.
        case background
        /// The selected tab closed; show this neighbor.
        case selectNext(WindowTab)
        /// The last tab closed; a new home tab replaced it.
        case replacedWithHome(WindowTab)
    }

    init() {
        let first = WindowTab(number: 1)
        tabs = [first]
        selected = first
    }

    func tab(number: Int) -> WindowTab? { tabs.first { $0.number == number } }

    /// Append a home tab. Does not select it.
    func add() -> WindowTab {
        let tab = WindowTab(number: nextNumber)
        nextNumber += 1
        tabs.append(tab)
        return tab
    }

    func select(_ tab: WindowTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        selected = tab
    }

    /// Remove a tab (the caller disposes it). The right neighbor follows a closed
    /// selected tab, else the left one; closing the last tab leaves a new home tab.
    func remove(number: Int) -> (removed: WindowTab, next: AfterRemoval)? {
        guard let index = tabs.firstIndex(where: { $0.number == number }) else { return nil }
        let removed = tabs.remove(at: index)
        guard removed === selected else { return (removed, .background) }
        if tabs.isEmpty {
            let home = add()
            selected = home
            return (removed, .replacedWithHome(home))
        }
        let next = tabs[min(index, tabs.count - 1)]
        selected = next
        return (removed, .selectNext(next))
    }

    /// ⌘1–⌘8 pick by position; ⌘9 is the last tab. nil when there is no such tab.
    func tab(forShortcutDigit digit: Int) -> WindowTab? {
        guard (1...9).contains(digit) else { return nil }
        let index = digit == 9 ? tabs.count - 1 : digit - 1
        return tabs.indices.contains(index) ? tabs[index] : nil
    }

    /// Ctrl-Tab / Ctrl-Shift-Tab, wrapping around. nil with a single tab.
    func neighbor(step: Int) -> WindowTab? {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === selected }) else { return nil }
        return tabs[((index + step) % tabs.count + tabs.count) % tabs.count]
    }

    /// The owning window is closing. Also clear cached pages on the selected reference.
    func dispose() {
        for tab in tabs { tab.dispose() }
        tabs.removeAll()
    }
}
