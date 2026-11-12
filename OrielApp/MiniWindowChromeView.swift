import AppKit
import QuartzCore

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
        var settingsHover: (Bool) -> Void = { _ in }
        var toggleFolding: () -> Void = {}
        var toggleAutomaticHiding: () -> Void = {}
        var toggleAllSpaces: () -> Void = {}
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
    private let addTabButton: ChromeButton
    private let dragAction: (NSEvent) -> Void
    private let closeTabAction: (Int) -> Void
    /// The eye switches edge reveal; settings opens transparency; lock freezes pass-through.
    let edgeRevealButton: ChromeButton
    let spacesButton: ChromeButton
    let foldButton: ChromeButton
    let windowButton: ChromeButton
    private let lockButton: ChromeButton
    private var overflowButton: ChromeButton!
    private var toolbarButtons: [ChromeButton] = []
    private var isLocked = false
    private var automaticHiding = false
    private var automaticFolding = false
    private var appearsOnAllSpaces = false
    private var controlsExpanded = false
    private var controlsCollapsing = false
    private var controlsAnimationGeneration = 0
    private weak var transitioningTitle: NSView?
    private var transitioningTitleWidth: CGFloat = 0
    private static let controlsAnimationDuration: TimeInterval = 0.16
    private var settingsPanelOpen = false
    private var controlsCloseTimer: Timer?
    private(set) var isFolded = false
    private var showingHome = true
    private var expandedHeight: CGFloat = 360
    private var tabs: [ChromeTab] = []
    private var selectedTab = 0
    private weak var presentedContent: NSView?
    private var presentedTab: Int?
    private static let contentTransitionKey = "oriel.contentSwitch"
    private var layoutState = ChromeLayout.make(width: 280, height: 360, tabCount: 0)
    private let hoverTip = ChromeTooltipView(frame: .zero)
    private let windowName = WindowNameLabel(labelWithString: "")
    private var hoverTimer: Timer?
    private weak var hoveredButton: ChromeButton?

    override var isFlipped: Bool { true }
    var tabMode: ChromeLayout.TabMode { layoutState.tabMode }
    var contentTop: CGFloat { layoutState.contentTop }

    init(actions: Actions) {
        tabStrip = WindowTabStrip(select: actions.selectTab, close: actions.closeTab, add: actions.addTab)
        dragAction = actions.drag
        closeTabAction = actions.closeTab
        addTabButton = ChromeButton(symbol: .add, label: "新建页签") { _ in actions.addTab() }
        lockButton = ChromeButton(symbol: .lock, label: "锁定穿透") { _ in actions.toggleLock() }
        edgeRevealButton = ChromeButton(symbol: .eye, label: "边缘唤醒") { _ in actions.toggleAutomaticHiding() }
        spacesButton = ChromeButton(symbol: .spaces, label: "在所有桌面显示") { _ in actions.toggleAllSpaces() }
        foldButton = ChromeButton(symbol: .fold, label: "收起为横条") { _ in actions.toggleFolding() }
        windowButton = ChromeButton(symbol: .settings, label: "窗口设置", action: actions.windowSettings)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 360))
        overflowButton = ChromeButton(symbol: .more, label: "更多窗口操作") { [weak self] _ in
            guard let self else { return }
            self.setControlsExpanded(!self.controlsExpanded)
        }

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
        toolbarButtons = [close, hide, addTabButton, foldButton, edgeRevealButton,
                          spacesButton, windowButton, lockButton, overflowButton]
        for button in toolbarButtons {
            button.wantsLayer = true
            button.onHover = { [weak self, weak button] entered in
                guard let self, let button else { return }
                if self.isRightControl(button) {
                    if entered {
                        self.cancelControlsClose()
                        if button === self.overflowButton { self.setControlsExpanded(true) }
                    } else {
                        self.scheduleControlsClose()
                    }
                }
                if button === self.windowButton {
                    self.dismissTooltip()
                    actions.settingsHover(entered)
                    return
                }
                if button === self.overflowButton { self.dismissTooltip(); return }
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
        windowName.wantsLayer = true
        windowName.onRename = { [weak self] in
            guard let self, !self.isLocked else { return }
            actions.renameWindow()
        }
        addSubview(windowName)
        tabSwitcher.isHidden = true
        tabSwitcher.wantsLayer = true
        tabSwitcher.target = self
        tabSwitcher.action = #selector(switcherPressed)
        addSubview(tabSwitcher)

        addSubview(content)
        content.wantsLayer = true
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
        setAppearsOnAllSpaces(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        dismissTooltip()
        if transitioningTitle != nil, abs(bounds.width - transitioningTitleWidth) > 0.5 {
            interruptTitleTransition()
        }
        if !isFolded { expandedHeight = bounds.height }
        let pageHeight = isFolded ? expandedHeight : bounds.height
        let layout = makeLayout(height: pageHeight, expanded: controlsExpanded || controlsCollapsing)
        layoutState = layout
        let frames = [layout.close, layout.hide, layout.addTab, layout.fold, layout.edgeReveal,
                      layout.spaces, layout.window, layout.lock, layout.overflow]
        for (button, frame) in zip(toolbarButtons, frames) {
            if button === addTabButton && transitioningTitle === tabSwitcher { continue }
            if button === overflowButton && transitioningTitle != nil && !isLocked {
                button.frame = ChromeLayout.lockFrame(forWidth: bounds.width)
                button.isHidden = false
                continue
            }
            button.frame = frame
            button.isHidden = frame.isEmpty || (isLocked && button === lockButton)
                || (isFolded && button === addTabButton)
        }

        let showsSwitcher = !isFolded && layout.tabMode == .switcher && layout.title != nil
        if transitioningTitle !== tabSwitcher { tabSwitcher.isHidden = !showsSwitcher }
        if transitioningTitle !== windowName { windowName.isHidden = layout.title == nil || showsSwitcher }
        if let title = layout.title {
            if transitioningTitle !== windowName { windowName.frame = title }
            if transitioningTitle !== tabSwitcher { tabSwitcher.frame = title.insetBy(dx: 0, dy: -2) }
        }
        tabStrip.isHidden = isFolded || layout.tabMode != .strip
        tabStrip.frame = layout.tabStrip

        let contentTop = layout.contentTop
        content.frame = NSRect(x: 6, y: contentTop, width: max(0, bounds.width - 12),
                               height: max(0, pageHeight - contentTop - 6))
        home.frame = content.bounds
        surfaceHost.frame = NSRect(x: 0, y: contentTop, width: bounds.width,
                                    height: max(0, pageHeight - contentTop))
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
        showingHome = true
        surfaceHost.isHidden = true
        content.isHidden = isFolded
        home.isHidden = false
    }

    func setFolded(_ folded: Bool) {
        guard isFolded != folded else { return }
        interruptTitleTransition()
        if folded { layoutSubtreeIfNeeded() }
        isFolded = folded
        content.isHidden = folded || !showingHome
        surfaceHost.isHidden = folded || showingHome
        if folded { cancelContentTransition(); dismissTooltip() }
        needsLayout = true
        if !folded { animateContentSwitchIfNeeded(force: true) }
    }

    func setWindowName(_ name: String) {
        windowName.stringValue = name
        windowName.toolTip = name
        needsLayout = true
    }

    func setTabs(_ tabs: [ChromeTab], selected: Int) {
        if self.tabs != tabs { interruptControlsCollapse(); interruptTitleTransition() }
        self.tabs = tabs
        selectedTab = selected
        tabStrip.setTabs(tabs, selected: selected)
        tabSwitcher.configure(tabs.first { $0.number == selected })
        needsLayout = true
        animateContentSwitchIfNeeded()
    }

    /// Activation presents the new page before refreshing its tabs. Animate only that
    /// change; title updates keep the current page and its animation untouched.
    private func animateContentSwitchIfNeeded(force: Bool = false) {
        let container = showingHome ? content : surfaceHost
        let page = showingHome ? home : surfaceHost.subviews.first
        let changed = force || presentedTab != selectedTab || presentedContent !== page
        let hadContent = presentedTab != nil
        presentedTab = selectedTab
        presentedContent = page
        guard changed else { return }

        let layer = container.layer
        let interruptedOpacity = layer?.animation(forKey: Self.contentTransitionKey) != nil
            ? layer?.presentation()?.opacity : nil
        cancelContentTransition()
        guard hadContent, !isFolded, window?.isVisible == true, !container.isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer, layer.opacity > 0 else { return }

        // Animate presentation only: user opacity, layout, hit testing and focus stay current.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = interruptedOpacity ?? layer.opacity * 0.6
        fade.toValue = layer.opacity
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: Self.contentTransitionKey)
    }

    private func cancelContentTransition() {
        content.layer?.removeAnimation(forKey: Self.contentTransitionKey)
        surfaceHost.layer?.removeAnimation(forKey: Self.contentTransitionKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelContentTransition() }
    }

    func showTerminal(_ terminal: NSView) {
        showSurface(terminal, inset: 4, background: OrielPalette.terminal)
    }

    func showReadingSurface(_ view: NSView) {
        showSurface(view, inset: 0, background: .clear)
    }

    private func showSurface(_ view: NSView, inset: CGFloat, background: NSColor) {
        showingHome = false
        content.isHidden = true
        surfaceHost.layer?.backgroundColor = background.cgColor
        surfaceHost.isHidden = isFolded
        layoutSubtreeIfNeeded()
        view.frame = surfaceHost.bounds.insetBy(dx: inset, dy: inset)
        view.autoresizingMask = [.width, .height]
        if view.superview !== surfaceHost { surfaceHost.subviews = [view] }
    }

    func setContentOpacity(background: CGFloat, content: CGFloat, revealToolbar: Bool = false) {
        if self.content.alphaValue != content || surfaceHost.alphaValue != content {
            cancelContentTransition()
        }
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

    func update(isLocked: Bool, automaticHiding: Bool, automaticFolding: Bool = false) {
        let layoutChanged = self.isLocked != isLocked || self.automaticHiding != automaticHiding
            || self.automaticFolding != automaticFolding
        if layoutChanged { interruptControlsCollapse(); interruptTitleTransition() }
        self.automaticHiding = automaticHiding
        self.automaticFolding = automaticFolding
        if self.isLocked != isLocked {
            dismissTooltip()
            if isLocked { cancelContentTransition() }
            self.isLocked = isLocked
            if isLocked {
                cancelControlsClose()
                controlsExpanded = false
                overflowButton.layer?.removeAnimation(forKey: "oriel.overflowFade")
                overflowButton.setActive(false, label: "更多窗口操作")
            }
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
        foldButton.setActive(automaticFolding, label: automaticFolding ? "保持展开" : "收起为横条")
        windowButton.setHint("透明度设置")
        lockButton.setActive(isLocked, label: isLocked ? "解除锁定穿透" : "锁定穿透")
        if layoutChanged { needsLayout = true }
    }

    func setAppearsOnAllSpaces(_ enabled: Bool) {
        if appearsOnAllSpaces != enabled {
            interruptControlsCollapse()
            interruptTitleTransition()
            appearsOnAllSpaces = enabled
            needsLayout = true
        }
        spacesButton.setActive(enabled, label: enabled ? "仅在当前桌面显示" : "在所有桌面显示")
        spacesButton.setAccessibilityValue(enabled ? "所有桌面" : "当前桌面")
    }

    func setSettingsPanelOpen(_ open: Bool) {
        settingsPanelOpen = open
        if open { setControlsExpanded(true) }
        else { scheduleControlsClose() }
    }

    private func isRightControl(_ button: ChromeButton) -> Bool {
        button === foldButton || button === edgeRevealButton || button === spacesButton
            || button === windowButton || button === lockButton || button === overflowButton
    }

    private func makeLayout(height: CGFloat, expanded: Bool) -> ChromeLayout {
        ChromeLayout.make(width: bounds.width, height: height, tabCount: tabs.count,
                          showsSingleTab: tabs.count == 1 && tabs[0].kind != nil,
                          controlsExpanded: expanded, automaticFolding: automaticFolding,
                          automaticHiding: automaticHiding, allSpaces: appearsOnAllSpaces,
                          locked: isLocked)
    }

    private var currentTitleView: NSView {
        layoutState.tabMode == .switcher ? tabSwitcher : windowName
    }

    private func interruptTitleTransition() {
        guard let title = transitioningTitle else { return }
        title.layer?.removeAllAnimations()
        title.alphaValue = 1
        if title === tabSwitcher {
            addTabButton.layer?.removeAllAnimations()
            addTabButton.alphaValue = 1
        }
        overflowButton.layer?.removeAnimation(forKey: "oriel.overflowFade")
        transitioningTitle = nil
        needsLayout = true
    }

    private func animateOverflow(from start: Float, to end: Float) {
        guard let layer = overflowButton.layer else { return }
        layer.removeAnimation(forKey: "oriel.overflowFade")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start
        fade.toValue = end
        fade.duration = Self.controlsAnimationDuration
        fade.timingFunction = CAMediaTimingFunction(name: end == 0 ? .easeOut : .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "oriel.overflowFade")
    }

    private func animateTitleView(_ view: NSView, to frame: CGRect?) {
        guard let frame else {
            if !view.isHidden { view.animator().alphaValue = 0 }
            return
        }
        if view.isHidden {
            view.frame = frame
            view.alphaValue = 0
            view.isHidden = false
        }
        view.animator().frame = frame
        if view.alphaValue < 1 { view.animator().alphaValue = 1 }
    }

    private func animateTitle(to target: ChromeLayout, view title: NSView) {
        let frame = target.title.map { target.tabMode == .switcher
            ? $0.insetBy(dx: 0, dy: -2) : $0 }
        animateTitleView(title, to: frame)
        if title === tabSwitcher {
            animateTitleView(addTabButton, to: target.addTab.isEmpty ? nil : target.addTab)
        }
    }

    private func finishTitleTransition(generation: Int) {
        guard controlsAnimationGeneration == generation else { return }
        let title = transitioningTitle
        transitioningTitle = nil
        title?.alphaValue = 1
        if title === tabSwitcher { addTabButton.alphaValue = 1 }
        needsLayout = true
        layoutSubtreeIfNeeded()
        overflowButton.layer?.removeAnimation(forKey: "oriel.overflowFade")
    }

    private func interruptControlsCollapse() {
        guard controlsCollapsing else { return }
        controlsAnimationGeneration += 1
        controlsCollapsing = false
        interruptTitleTransition()
        for button in [foldButton, edgeRevealButton, spacesButton, windowButton, lockButton] {
            button.layer?.removeAllAnimations()
            button.alphaValue = 1
        }
    }

    private func setControlsExpanded(_ expanded: Bool) {
        guard !isLocked, (expanded || !settingsPanelOpen), controlsExpanded != expanded else { return }
        cancelControlsClose()
        if expanded { interruptControlsCollapse() }
        interruptTitleTransition()
        layoutSubtreeIfNeeded()
        let animate = window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let title = currentTitleView
        if animate {
            transitioningTitle = title
            transitioningTitleWidth = bounds.width
        }
        let previousControlFrames = Dictionary(uniqueKeysWithValues: toolbarButtons
            .filter { !$0.isHidden && isRightControl($0) && $0 !== overflowButton }
            .map { (ObjectIdentifier($0), $0.frame) })
        let overflowOrigin = layoutState.overflow.midX
        let newlyVisible = expanded ? toolbarButtons.filter(\.isHidden) : []
        controlsExpanded = expanded
        controlsAnimationGeneration += 1
        let generation = controlsAnimationGeneration
        overflowButton.setActive(expanded, label: expanded ? "收起窗口操作" : "更多窗口操作")
        if !expanded, animate {
            animateControlsClosed(title: title, generation: generation)
            return
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard expanded, animate else { return }
        animateOverflow(from: 1, to: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.controlsAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animateTitle(to: layoutState, view: title)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishTitleTransition(generation: generation) }
        }
        for button in toolbarButtons where !button.isHidden && isRightControl(button) && button !== overflowButton {
            guard let layer = button.layer else { continue }
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = (previousControlFrames[ObjectIdentifier(button)]?.midX ?? overflowOrigin)
                - button.frame.midX
            slide.toValue = 0
            slide.duration = Self.controlsAnimationDuration
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(slide, forKey: "oriel.controlReveal")
            guard newlyVisible.contains(where: { $0 === button }) else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Self.controlsAnimationDuration
            layer.add(fade, forKey: "oriel.controlFade")
        }
    }

    private func animateControlsClosed(title: NSView, generation: Int) {
        let pageHeight = isFolded ? expandedHeight : bounds.height
        let target = makeLayout(height: pageHeight, expanded: false)
        let destinations: [(ChromeButton, CGRect)] = [
            (foldButton, target.fold), (edgeRevealButton, target.edgeReveal),
            (spacesButton, target.spaces), (windowButton, target.window),
            (lockButton, target.lock)
        ]
        controlsCollapsing = true
        overflowButton.frame = target.overflow
        overflowButton.isHidden = false
        animateOverflow(from: 0, to: 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.controlsAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animateTitle(to: target, view: title)
            for (button, destination) in destinations where !button.isHidden {
                let frame = destination.isEmpty
                    ? CGRect(x: target.overflow.midX - button.frame.width / 2, y: 0,
                             width: button.frame.width, height: button.frame.height)
                    : destination
                button.animator().frame = frame
                if destination.isEmpty { button.animator().alphaValue = 0 }
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.controlsAnimationGeneration == generation,
                      !self.controlsExpanded else { return }
                self.controlsCollapsing = false
                self.finishTitleTransition(generation: generation)
                for (button, _) in destinations { button.alphaValue = 1 }
            }
        }
    }

    private func cancelControlsClose() {
        controlsCloseTimer?.invalidate()
        controlsCloseTimer = nil
    }

    private func scheduleControlsClose() {
        guard controlsExpanded, !settingsPanelOpen else { return }
        cancelControlsClose()
        let timer = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.controlsCloseTimer = nil
                guard !self.settingsPanelOpen, let window = self.window else { return }
                let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                let frames = [self.layoutState.fold, self.layoutState.edgeReveal,
                              self.layoutState.spaces, self.layoutState.window,
                              self.layoutState.lock, self.layoutState.overflow].filter { !$0.isEmpty }
                let region = frames.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -4, dy: -5)
                if !region.contains(point) { self.setControlsExpanded(false) }
            }
        }
        controlsCloseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
        // Fade only the artwork so the button retains its tracking area.
        let opacity = iconOpacity
        guard opacity > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            context.endTransparencyLayer()
            context.restoreGState()
        }
        if symbol == .minus || symbol == .close {
            drawTrafficLight()
        } else {
            if isEnabled && !active && (hovered || isHighlighted) {
                (isHighlighted ? ChromePalette.pressed : ChromePalette.hover).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 4, yRadius: 4).fill()
            }
            let tint = isEnabled && active ? OrielPalette.accent
                : (isEnabled ? ChromePalette.ink : ChromePalette.disabled)
            let icon = symbol == .fold && active ? ChromeSymbol.unfold : symbol
            icon.draw(in: NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14),
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
    case add, fold, unfold, eye, spaces, settings, lock, more, minus, close, stocks

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
        case .fold:
            path.appendRoundedRect(NSRect(x: 3.5, y: 8.5, width: 13, height: 3), xRadius: 1.5, yRadius: 1.5)
            line([NSPoint(x: 10, y: 1), NSPoint(x: 10, y: 6.5)])
            line([NSPoint(x: 6.5, y: 3), NSPoint(x: 10, y: 6.5), NSPoint(x: 13.5, y: 3)])
            line([NSPoint(x: 10, y: 19), NSPoint(x: 10, y: 13.5)])
            line([NSPoint(x: 6.5, y: 17), NSPoint(x: 10, y: 13.5), NSPoint(x: 13.5, y: 17)])
        case .unfold:
            line([NSPoint(x: 6, y: 6), NSPoint(x: 3, y: 6), NSPoint(x: 3, y: 14), NSPoint(x: 6, y: 14)])
            line([NSPoint(x: 14, y: 6), NSPoint(x: 17, y: 6), NSPoint(x: 17, y: 14), NSPoint(x: 14, y: 14)])
            line([NSPoint(x: 10, y: 7), NSPoint(x: 10, y: 1)])
            line([NSPoint(x: 6.5, y: 4.5), NSPoint(x: 10, y: 1), NSPoint(x: 13.5, y: 4.5)])
            line([NSPoint(x: 10, y: 13), NSPoint(x: 10, y: 19)])
            line([NSPoint(x: 6.5, y: 15.5), NSPoint(x: 10, y: 19), NSPoint(x: 13.5, y: 15.5)])
        case .eye:
            path.move(to: NSPoint(x: 1, y: 10))
            path.curve(to: NSPoint(x: 19, y: 10), controlPoint1: NSPoint(x: 5, y: 2),
                       controlPoint2: NSPoint(x: 15, y: 2))
            path.curve(to: NSPoint(x: 1, y: 10), controlPoint1: NSPoint(x: 15, y: 18),
                       controlPoint2: NSPoint(x: 5, y: 18))
            path.appendOval(in: NSRect(x: 7, y: 7, width: 6, height: 6))
            NSBezierPath(ovalIn: NSRect(x: 9, y: 9, width: 2, height: 2)).fill()
        case .spaces:
            path.appendRoundedRect(NSRect(x: 2, y: 4, width: 11, height: 11), xRadius: 1.5, yRadius: 1.5)
            path.appendRoundedRect(NSRect(x: 7, y: 7, width: 11, height: 11), xRadius: 1.5, yRadius: 1.5)
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
        case .more:
            for x in [4.5, 10.0, 15.5] as [CGFloat] {
                NSBezierPath(ovalIn: NSRect(x: x - 1.25, y: 8.75, width: 2.5, height: 2.5)).fill()
            }
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
