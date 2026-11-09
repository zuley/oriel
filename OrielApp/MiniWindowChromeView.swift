import AppKit

/// What the tab strip, tab menu and toolbar switcher need to know about one tab.
struct ChromeTab: Equatable {
    let number: Int
    let title: String
    /// nil for a new-tab (home) page.
    let kind: PageKind?
}

@MainActor
final class MiniWindowChromeView: NSView {
    struct Actions {
        var addTab: () -> Void
        var selectTab: (Int) -> Void
        var closeTab: (Int) -> Void
        var openPage: (PageKind) -> Void = { _ in }
        var dropNovel: ([URL]) -> Bool = { _ in false }
        var renameWindow: () -> Void = {}
        var windowSettings: (NSView) -> Void
        var toggleAutomaticHiding: () -> Void
        var toggleLock: () -> Void
        var hide: () -> Void
        var close: () -> Void
        var drag: (NSEvent) -> Void
    }

    private let content = ChromeContentView()
    private let home = ChromeHomeView(frame: .zero)
    private let surfaceHost = NSView()
    private let tabStrip: WindowTabStrip
    private let tabSwitcher = TabSwitcherButton()
    private let dragAction: (NSEvent) -> Void
    private let closeTabAction: (Int) -> Void
    /// The eye switches edge reveal, the slider opens transparency, the lock freezes pass-through.
    let edgeRevealButton: ChromeButton
    let windowButton: ChromeButton
    private let lockButton: ChromeButton
    private var toolbarButtons: [ChromeButton] = []
    private var isLocked = false
    private var tabs: [ChromeTab] = []
    private var selectedTab = 0
    private var layoutState = ChromeLayout.make(width: 280, height: 360, tabCount: 0)
    private let hoverTip = ChromeTooltipView(frame: .zero)
    private let windowName = WindowNameLabel(labelWithString: "")
    private var hoverTimer: Timer?
    private weak var hoveredButton: ChromeButton?

    override var isFlipped: Bool { true }
    var tabMode: ChromeLayout.TabMode { layoutState.tabMode }
    var contentTop: CGFloat { layoutState.contentTop }

    init(actions: Actions) {
        tabStrip = WindowTabStrip(select: actions.selectTab, close: actions.closeTab)
        dragAction = actions.drag
        closeTabAction = actions.closeTab
        let addTab = ChromeButton(symbol: .add, label: "新建页签") { _ in actions.addTab() }
        lockButton = ChromeButton(symbol: .lock, label: "锁定穿透") { _ in actions.toggleLock() }
        edgeRevealButton = ChromeButton(symbol: .eye, label: "边缘唤醒") { _ in
            actions.toggleAutomaticHiding()
        }
        windowButton = ChromeButton(symbol: .settings, label: "窗口设置", action: actions.windowSettings)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 360))

        home.onOpenPage = actions.openPage
        home.onDropNovel = actions.dropNovel
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = ChromePalette.background.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]

        let hide = ChromeButton(symbol: .minus, label: "收起到菜单栏") { _ in actions.hide() }
        let close = ChromeButton(symbol: .close, label: "关闭小窗") { _ in actions.close() }
        // The order matches ChromeLayout: close, hide, add, edge reveal, window, lock.
        toolbarButtons = [close, hide, addTab, edgeRevealButton, windowButton, lockButton]
        for button in toolbarButtons {
            button.onHover = { [weak self, weak button] entered in
                guard let self, let button else { return }
                if entered { self.scheduleTooltip(for: button) }
                else if self.hoveredButton === button { self.dismissTooltip() }
            }
            addSubview(button)
        }
        windowName.font = .systemFont(ofSize: 11, weight: .medium)
        windowName.textColor = OrielPalette.secondary
        windowName.alignment = .center
        windowName.lineBreakMode = .byTruncatingTail
        windowName.maximumNumberOfLines = 1
        windowName.setAccessibilityLabel("窗口名称")
        windowName.onRename = { [weak self] in
            guard let self, !self.isLocked else { return }
            actions.renameWindow()
        }
        addSubview(windowName)
        tabSwitcher.isHidden = true
        tabSwitcher.target = self
        tabSwitcher.action = #selector(switcherPressed)
        addSubview(tabSwitcher)

        addSubview(content)
        content.addSubview(home)
        surfaceHost.wantsLayer = true
        addSubview(surfaceHost)
        tabStrip.isHidden = true
        tabStrip.onOverflow = { [weak self] anchor in self?.presentTabMenu(from: anchor) }
        addSubview(tabStrip)
        hoverTip.isHidden = true
        addSubview(hoverTip)
        showHome()
        update(isLocked: false, automaticHiding: false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        dismissTooltip()
        let layout = ChromeLayout.make(width: bounds.width, height: bounds.height, tabCount: tabs.count)
        layoutState = layout
        let frames = [layout.close, layout.hide, layout.addTab, layout.edgeReveal,
                      layout.window, layout.lock]
        for (button, frame) in zip(toolbarButtons, frames) {
            button.frame = frame
            button.isHidden = isLocked && button === lockButton
        }

        let showsSwitcher = layout.tabMode == .switcher && layout.title != nil
        tabSwitcher.isHidden = !showsSwitcher
        windowName.isHidden = layout.title == nil || showsSwitcher
        if let title = layout.title {
            windowName.frame = title
            tabSwitcher.frame = title.insetBy(dx: 0, dy: -2)
        }
        tabStrip.isHidden = layout.tabMode != .strip
        tabStrip.frame = layout.tabStrip

        let contentTop = layout.contentTop
        content.frame = NSRect(x: 6, y: contentTop, width: max(0, bounds.width - 12),
                               height: max(0, bounds.height - contentTop - 6))
        home.frame = content.bounds
        surfaceHost.frame = NSRect(x: 0, y: contentTop, width: bounds.width,
                                    height: max(0, bounds.height - contentTop))
        content.needsDisplay = true
        home.needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dismissTooltip()
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= 6, point.y < 28,
              point.x >= 6, point.x < bounds.width - 6 else {
            super.mouseDown(with: event)
            return
        }
        // Buttons handle their own clicks. Only the otherwise empty toolbar reaches here.
        dragAction(event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        var start: CGFloat = 6
        var occupied = toolbarButtons.filter { !$0.isHidden }.map(\.frame)
        if !tabSwitcher.isHidden { occupied.append(tabSwitcher.frame) }
        for frame in occupied.sorted(by: { $0.minX < $1.minX }) {
            if frame.minX > start {
                addCursorRect(NSRect(x: start, y: 6, width: frame.minX - start, height: 22), cursor: .openHand)
            }
            start = max(start, frame.maxX)
        }
    }

    func showHome() {
        surfaceHost.isHidden = true
        content.isHidden = false
        home.isHidden = false
    }

    func setWindowName(_ name: String) {
        windowName.stringValue = name
        windowName.toolTip = name
        needsLayout = true
    }

    func setTabs(_ tabs: [ChromeTab], selected: Int) {
        self.tabs = tabs
        selectedTab = selected
        tabStrip.setTabs(tabs, selected: selected)
        tabSwitcher.configure(tabs.first { $0.number == selected })
        needsLayout = true
    }

    func showTerminal(_ terminal: NSView) {
        showSurface(terminal, inset: 4, background: OrielPalette.terminal)
    }

    func showReadingSurface(_ view: NSView) {
        showSurface(view, inset: 0, background: .clear)
    }

    private func showSurface(_ view: NSView, inset: CGFloat, background: NSColor) {
        content.isHidden = true
        surfaceHost.layer?.backgroundColor = background.cgColor
        surfaceHost.isHidden = false
        layoutSubtreeIfNeeded()
        view.frame = surfaceHost.bounds.insetBy(dx: inset, dy: inset)
        view.autoresizingMask = [.width, .height]
        if view.superview !== surfaceHost { surfaceHost.subviews = [view] }
    }

    func setContentOpacity(background: CGFloat, content: CGFloat, revealToolbar: Bool = false) {
        tabStrip.alphaValue = background
        tabSwitcher.alphaValue = revealToolbar ? 1 : background
        windowName.alphaValue = revealToolbar ? 1 : background
        layer?.backgroundColor = ChromePalette.background.withAlphaComponent(background).cgColor
        for button in toolbarButtons {
            button.restingOpacity = revealToolbar ? 1 : background
        }
        self.content.alphaValue = content
        surfaceHost.alphaValue = content
        home.setBackgroundOpacity(background)
    }

    func update(isLocked: Bool, automaticHiding: Bool) {
        if self.isLocked != isLocked {
            dismissTooltip()
            self.isLocked = isLocked
            tabStrip.setEnabled(!isLocked)
            tabSwitcher.isEnabled = !isLocked
            home.setActionsEnabled(!isLocked)
            // The recovery child draws the lock while locked; never composite two copies.
            lockButton.isHidden = isLocked
            needsLayout = true
        }
        for button in toolbarButtons { button.isEnabled = !isLocked }
        edgeRevealButton.setActive(automaticHiding,
                                   label: automaticHiding ? "关闭边缘唤醒" : "开启边缘唤醒")
        edgeRevealButton.setAccessibilityValue(automaticHiding ? "边缘唤醒已开启" : "边缘唤醒已关闭")
        windowButton.setHint("透明度设置")
        lockButton.setActive(isLocked, label: isLocked ? "解除锁定穿透" : "锁定穿透")
    }

    // MARK: Tab menu

    @objc private func switcherPressed() { presentTabMenu(from: tabSwitcher) }

    private func presentTabMenu(from anchor: NSView) {
        guard !isLocked, !tabs.isEmpty else { return }
        let menu = makeTabMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY + 2), in: anchor)
    }

    func makeTabMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: windowName.stringValue.isEmpty ? "小窗" : windowName.stringValue,
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for tab in tabs {
            let item = NSMenuItem(title: tab.title, action: #selector(tabMenuSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tab.number
            item.state = tab.number == selectedTab ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭当前页签", action: #selector(tabMenuClosed(_:)), keyEquivalent: "")
        close.target = self
        close.tag = selectedTab
        close.isEnabled = !isLocked && tabs.contains { $0.number == selectedTab }
        menu.addItem(close)
        return menu
    }

    @objc private func tabMenuSelected(_ sender: NSMenuItem) { tabStrip.select(sender.tag) }

    @objc private func tabMenuClosed(_ sender: NSMenuItem) {
        guard !isLocked, tabs.contains(where: { $0.number == sender.tag }) else { return }
        closeTabAction(sender.tag)
    }

    static func lockControlFrame(for width: CGFloat) -> NSRect {
        ChromeLayout.lockFrame(forWidth: width)
    }

    static func makeLockRecoveryControl(unlock: @escaping () -> Void) -> ChromeButton {
        let button = ChromeButton(symbol: .lock, label: "取消穿透") { _ in unlock() }
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        button.setActive(true, label: "取消穿透")
        button.toolTip = "取消穿透"
        return button
    }

    func dismissTooltip() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoveredButton = nil
        hoverTip.isHidden = true
    }

    private func scheduleTooltip(for button: ChromeButton) {
        dismissTooltip()
        guard button.isEnabled else { return }
        hoveredButton = button
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                guard let self, let button, button.isEnabled, self.hoveredButton === button,
                      !button.isHidden, self.window?.isVisible == true else { return }
                self.hoverTimer = nil
                let size = self.hoverTip.configure(button.hintText)
                let inset = min(8, max(0, (self.bounds.width - size.width) / 2))
                let x = min(max(inset, button.frame.midX - size.width / 2), self.bounds.width - size.width - inset)
                self.hoverTip.frame = NSRect(x: x, y: 30, width: size.width, height: size.height)
                self.hoverTip.isHidden = false
            }
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

@MainActor
private final class WindowNameLabel: NSTextField {
    var onRename: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Keep the title part of the draggable toolbar, while retaining native tooltips.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRename?() }
        else { nextResponder?.mouseDown(with: event) }
    }
}

@MainActor
private final class ChromeTooltipView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = OrielPalette.ink.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: 11)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ text: String) -> NSSize {
        label.stringValue = text
        let width = ceil(label.intrinsicContentSize.width)
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 8, y: 5, width: width, height: height)
        return NSSize(width: width + 16, height: height + 10)
    }
}

typealias ChromePalette = OrielPalette

@MainActor
private final class ChromeContentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ChromeButton: NSButton {
    private let symbol: ChromeSymbol
    private let onPress: (NSView) -> Void
    private var tracking: NSTrackingArea?
    private var hovered = false
    var restingOpacity: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }
    var iconOpacity: CGFloat { hovered && isEnabled ? 1 : restingOpacity }

    private var active = false
    var onHover: ((Bool) -> Void)?
    private(set) var hintText = ""
    var isWindowControl: Bool { symbol == .minus || symbol == .close }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }

    fileprivate init(symbol: ChromeSymbol, label: String, action: @escaping (NSView) -> Void) {
        self.symbol = symbol
        onPress = action
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(pressed)
        setHint(label)
        setAccessibilityLabel(label)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    func setActive(_ value: Bool, label: String) {
        if active != value {
            active = value
            needsDisplay = true
        }
        setAccessibilityValue(value)
        setAccessibilityLabel(label)
        setHint(label)
    }

    func setHint(_ text: String) {
        hintText = text
        setAccessibilityHelp(text)
    }

    @objc private func pressed() {
        onHover?(false)
        onPress(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
        onHover?(false)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fade only the artwork so even an invisible icon keeps its tracking area.
        let opacity = iconOpacity
        guard opacity > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            context.endTransparencyLayer()
            context.restoreGState()
        }
        let highlighted = isEnabled && active && (symbol == .lock || symbol == .eye)
        if symbol == .minus || symbol == .close {
            drawTrafficLight()
        } else {
            if isEnabled && (hovered || isHighlighted || active) {
                (highlighted ? OrielPalette.selection
                    : (isHighlighted ? ChromePalette.pressed : ChromePalette.hover)).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 4, yRadius: 4).fill()
            }
            let tint = highlighted ? OrielPalette.accent : (isEnabled ? ChromePalette.ink : ChromePalette.disabled)
            symbol.draw(in: NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14),
                        color: tint)
        }
        if window?.firstResponder === self {
            OrielPalette.accent.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            focus.lineWidth = 1.5
            focus.stroke()
        }
    }

    private func drawTrafficLight() {
        let closing = symbol == .close
        let fill = isEnabled
            ? (closing ? NSColor(srgbRed: 1, green: 95 / 255, blue: 87 / 255, alpha: 1)
                       : NSColor(srgbRed: 254 / 255, green: 188 / 255, blue: 46 / 255, alpha: 1))
            : NSColor(white: 0.85, alpha: 1)
        let circle = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 5, y: bounds.midY - 5,
                                               width: 10, height: 10))
        (isEnabled && isHighlighted ? (fill.blended(withFraction: 0.15, of: .black) ?? fill) : fill).setFill()
        circle.fill()
        (fill.blended(withFraction: 0.18, of: .black) ?? fill).setStroke()
        circle.lineWidth = 0.7
        circle.stroke()
        if isEnabled && (hovered || isHighlighted) {
            let ink = closing ? NSColor(srgbRed: 0.48, green: 0.08, blue: 0.04, alpha: 1)
                              : NSColor(srgbRed: 0.55, green: 0.32, blue: 0.02, alpha: 1)
            symbol.draw(in: NSRect(x: bounds.midX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7),
                        color: ink)
        }
    }
}

@MainActor
enum ChromeSymbol: Equatable {
    case add, eye, settings, lock, minus, close, stocks

    func draw(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nativeTransform = NSAffineTransform()
        nativeTransform.translateX(by: rect.minX, yBy: rect.minY)
        nativeTransform.scaleX(by: rect.width / 20, yBy: rect.height / 20)
        nativeTransform.concat()
        color.setStroke()
        color.setFill()
        let path = NSBezierPath()
        path.lineWidth = 1.35
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        func line(_ points: [NSPoint]) {
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
        }

        switch self {
        case .add:
            line([NSPoint(x: 3, y: 10), NSPoint(x: 17, y: 10)])
            line([NSPoint(x: 10, y: 3), NSPoint(x: 10, y: 17)])
        case .eye:
            path.move(to: NSPoint(x: 1, y: 10))
            path.curve(to: NSPoint(x: 19, y: 10), controlPoint1: NSPoint(x: 5, y: 2),
                       controlPoint2: NSPoint(x: 15, y: 2))
            path.curve(to: NSPoint(x: 1, y: 10), controlPoint1: NSPoint(x: 15, y: 18),
                       controlPoint2: NSPoint(x: 5, y: 18))
            path.appendOval(in: NSRect(x: 7, y: 7, width: 6, height: 6))
            NSBezierPath(ovalIn: NSRect(x: 9, y: 9, width: 2, height: 2)).fill()
        case .settings:
            line([NSPoint(x: 2, y: 6), NSPoint(x: 10, y: 6)])
            line([NSPoint(x: 14, y: 6), NSPoint(x: 18, y: 6)])
            line([NSPoint(x: 2, y: 14), NSPoint(x: 5, y: 14)])
            line([NSPoint(x: 9, y: 14), NSPoint(x: 18, y: 14)])
            path.appendOval(in: NSRect(x: 10, y: 4, width: 4, height: 4))
            path.appendOval(in: NSRect(x: 5, y: 12, width: 4, height: 4))
        case .lock:
            path.appendRoundedRect(NSRect(x: 3.5, y: 8.5, width: 13, height: 10),
                                   xRadius: 2, yRadius: 2)
            path.move(to: NSPoint(x: 6, y: 8.5))
            path.line(to: NSPoint(x: 6, y: 6))
            path.curve(to: NSPoint(x: 14, y: 6), controlPoint1: NSPoint(x: 6, y: 0.5),
                       controlPoint2: NSPoint(x: 14, y: 0.5))
            path.line(to: NSPoint(x: 14, y: 8.5))
            line([NSPoint(x: 10, y: 12), NSPoint(x: 10, y: 15)])
        case .minus:
            line([NSPoint(x: 2, y: 10), NSPoint(x: 18, y: 10)])
        case .close:
            line([NSPoint(x: 4, y: 4), NSPoint(x: 16, y: 16)])
            line([NSPoint(x: 16, y: 4), NSPoint(x: 4, y: 16)])
        case .stocks:
            path.appendRoundedRect(NSRect(x: 2, y: 1.5, width: 16, height: 17), xRadius: 4, yRadius: 4)
            line([NSPoint(x: 2.5, y: 6), NSPoint(x: 17.5, y: 6)])
            line([NSPoint(x: 4, y: 14), NSPoint(x: 7, y: 11.5), NSPoint(x: 10, y: 13),
                  NSPoint(x: 15, y: 8.5)])
            line([NSPoint(x: 11.5, y: 8.5), NSPoint(x: 15, y: 8.5), NSPoint(x: 15, y: 12)])
        }
        path.stroke()
    }
}
