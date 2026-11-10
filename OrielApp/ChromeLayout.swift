import CoreGraphics

/// Where every part of the mini window's chrome sits for a given size. A pure value so the
/// narrow-window rules can be tested without building views. Coordinates are top-left based.
struct ChromeLayout: Equatable {
    /// How the open tabs are offered.
    enum TabMode: Equatable {
        case none      // one tab: nothing to switch
        case strip     // a row of tabs under the toolbar
        case switcher  // the toolbar title becomes a tab menu (short windows)
    }

    static let toolbarHeight: CGFloat = 28
    static let stripHeight: CGFloat = 22
    static let stripGap: CGFloat = 4
    /// Below this width the toolbar uses its smallest controls.
    static let narrowWidth: CGFloat = 168
    /// Under this height two tabs share the toolbar instead of costing a row.
    static let stripMinimumHeight: CGFloat = 200
    static let minimumSwitcherWidth: CGFloat = 40
    static let minimumTitleWidth: CGFloat = 24

    var narrow: Bool
    var close: CGRect
    var hide: CGRect
    var addTab: CGRect
    /// Roll the window into its toolbar until hovered.
    var fold: CGRect
    /// The eye that switches edge reveal on and off.
    var edgeReveal: CGRect
    /// The slider that opens the transparency panel.
    var window: CGRect
    var lock: CGRect
    /// Space between the left and right controls; nil when too small to read.
    var title: CGRect?
    var tabMode: TabMode
    var tabStrip: CGRect
    /// Top edge of the page content area.
    var contentTop: CGFloat

    static func lockFrame(forWidth width: CGFloat) -> CGRect {
        CGRect(x: width - 18 - 14, y: 0, width: 28, height: toolbarHeight)
    }

    static func make(width: CGFloat, height: CGFloat, tabCount: Int) -> ChromeLayout {
        let narrow = width < narrowWidth
        func control(center: CGFloat, width controlWidth: CGFloat) -> CGRect {
            CGRect(x: center - controlWidth / 2, y: 0, width: controlWidth, height: toolbarHeight)
        }
        let trafficWidth: CGFloat = narrow ? 16 : 18
        let close = control(center: narrow ? 8 : 16, width: trafficWidth)
        let hide = control(center: narrow ? 24 : 34, width: trafficWidth)
        let addTab = control(center: narrow ? 40 : 60, width: narrow ? 16 : 28)

        // The three right-hand icons sit in a fixed row whose right edge never moves.
        let lock = lockFrame(forWidth: width)
        let sideWidth: CGFloat = narrow ? 16 : 22
        let sideGap: CGFloat = narrow ? 2 : 0
        let window = CGRect(x: lock.minX - sideGap - sideWidth, y: 0, width: sideWidth, height: toolbarHeight)
        // At the smallest widths keep folding/settings/lock; edge reveal remains in the app menu.
        let edgeWidth: CGFloat = width >= 180 ? sideWidth : 0
        let edgeReveal = CGRect(x: window.minX - (edgeWidth > 0 ? sideGap + edgeWidth : 0), y: 0, width: edgeWidth,
                                height: toolbarHeight)
        let fold = CGRect(x: edgeReveal.minX - sideGap - sideWidth, y: 0, width: sideWidth, height: toolbarHeight)

        let titleStart = addTab.maxX + 4
        let titleWidth = max(0, fold.minX - 4 - titleStart)
        let title = titleWidth >= minimumTitleWidth
            ? CGRect(x: titleStart, y: 6, width: titleWidth, height: 16) : nil

        let mode: TabMode
        if tabCount <= 1 {
            mode = .none
        } else if height >= stripMinimumHeight || titleWidth < minimumSwitcherWidth {
            mode = .strip
        } else {
            mode = .switcher
        }
        let strip = mode == .strip
            ? CGRect(x: 6, y: toolbarHeight, width: max(0, width - 12), height: stripHeight)
            : CGRect(x: 6, y: toolbarHeight, width: max(0, width - 12), height: 0)
        return ChromeLayout(narrow: narrow, close: close, hide: hide, addTab: addTab, fold: fold,
                            edgeReveal: edgeReveal, window: window, lock: lock, title: title,
                            tabMode: mode, tabStrip: strip, contentTop: strip.maxY + stripGap)
    }
}
