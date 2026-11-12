import CoreGraphics

/// Where every part of the mini window's chrome sits for a given size. A pure value so the
/// narrow-window rules can be tested without building views. Coordinates are top-left based.
struct ChromeLayout: Equatable {
    /// How the open tabs are offered.
    enum TabMode: Equatable {
        case none      // the initial home tab has no visible tab strip
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
    /// Beside the compact tab switcher; the full strip owns its own add button.
    var addTab: CGRect
    /// Roll the window into its toolbar until hovered.
    var fold: CGRect
    /// The eye that switches edge reveal on and off.
    var edgeReveal: CGRect
    /// Show this window on the current desktop or on every desktop.
    var spaces: CGRect
    /// The slider that opens the transparency panel.
    var window: CGRect
    var lock: CGRect
    /// Right-edge entry for controls that are currently tucked away.
    var overflow: CGRect
    /// Space between the left and right controls; nil when too small to read.
    var title: CGRect?
    var tabMode: TabMode
    var tabStrip: CGRect
    /// Top edge of the page content area.
    var contentTop: CGFloat

    static func lockFrame(forWidth width: CGFloat) -> CGRect {
        CGRect(x: width - 18 - 14, y: 0, width: 28, height: toolbarHeight)
    }

    static func make(width: CGFloat, height: CGFloat, tabCount: Int,
                     showsSingleTab: Bool = false,
                     controlsExpanded: Bool = false, automaticFolding: Bool = false,
                     automaticHiding: Bool = false, allSpaces: Bool = false,
                     locked: Bool = false) -> ChromeLayout {
        let narrow = width < narrowWidth
        func control(center: CGFloat, width controlWidth: CGFloat) -> CGRect {
            CGRect(x: center - controlWidth / 2, y: 0, width: controlWidth, height: toolbarHeight)
        }
        let trafficWidth: CGFloat = narrow ? 16 : 18
        let close = control(center: narrow ? 8 : 16, width: trafficWidth)
        let hide = control(center: narrow ? 24 : 34, width: trafficWidth)

        let sideWidth: CGFloat = narrow ? 16 : 22
        let sideGap: CGFloat = narrow ? 2 : 0
        func rightControls(expanded: Bool) -> (fold: CGRect, edge: CGRect, spaces: CGRect,
                                               window: CGRect, lock: CGRect, overflow: CGRect,
                                               left: CGFloat) {
            var right = width - 4
            func place(_ controlWidth: CGFloat) -> CGRect {
                let frame = CGRect(x: right - controlWidth, y: 0,
                                   width: controlWidth, height: toolbarHeight)
                right = frame.minX - sideGap
                return frame
            }
            let overflow = locked || expanded ? CGRect.zero : place(28)
            let lock = locked || expanded ? place(28) : .zero
            let window = !locked && expanded ? place(sideWidth) : .zero
            // Active switches remain visible even below their usual width threshold.
            let spaces = allSpaces || !locked && expanded && width >= 260 ? place(sideWidth) : .zero
            let edge = automaticHiding || !locked && expanded && width >= 180 ? place(sideWidth) : .zero
            let fold = automaticFolding || !locked && expanded ? place(sideWidth) : .zero
            return (fold, edge, spaces, window, lock, overflow, right + sideGap)
        }
        let resting = rightControls(expanded: false)
        let controls = rightControls(expanded: controlsExpanded)
        let hidesLeftControls = controlsExpanded && !locked && controls.left < hide.maxX + 4

        let titleStart = hide.maxX + 4
        let restingTitleWidth = max(0, resting.left - 4 - titleStart)
        let titleWidth = max(0, controls.left - 4 - titleStart)

        let mode: TabMode
        if tabCount == 0 || tabCount == 1 && !showsSingleTab {
            mode = .none
        } else if height >= stripMinimumHeight || restingTitleWidth < minimumSwitcherWidth + 24 {
            mode = .strip
        } else {
            mode = .switcher
        }
        let switcherAddWidth: CGFloat = mode == .switcher && !locked ? 22 : 0
        let availableTitleWidth = titleWidth - (switcherAddWidth > 0 ? switcherAddWidth + 2 : 0)
        let title = !hidesLeftControls && availableTitleWidth >= minimumTitleWidth
            ? CGRect(x: titleStart, y: 6, width: availableTitleWidth, height: 16) : nil
        let addTab: CGRect
        if mode == .switcher, !locked, let title {
            addTab = CGRect(x: title.maxX + 2, y: 0,
                            width: switcherAddWidth, height: toolbarHeight)
        } else {
            addTab = .zero
        }
        let strip = mode == .strip
            ? CGRect(x: 6, y: toolbarHeight, width: max(0, width - 12), height: stripHeight)
            : CGRect(x: 6, y: toolbarHeight, width: max(0, width - 12), height: 0)
        return ChromeLayout(narrow: narrow,
                            close: hidesLeftControls ? .zero : close,
                            hide: hidesLeftControls ? .zero : hide,
                            addTab: hidesLeftControls ? .zero : addTab,
                            fold: controls.fold, edgeReveal: controls.edge, spaces: controls.spaces,
                            window: controls.window, lock: controls.lock, overflow: controls.overflow,
                            title: title,
                            tabMode: mode, tabStrip: strip, contentTop: strip.maxY + stripGap)
    }
}
