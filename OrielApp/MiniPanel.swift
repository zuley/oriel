import AppKit
import SwiftUI
import OrielCore
import OrielTerminal

@MainActor
final class MiniPanel: NSPanel, NSWindowDelegate {
    struct Actions {
        let toggleLock: () -> Void
        let unlock: () -> Void
        let toggleAutomaticHiding: () -> Void
        let recover: () -> Void
        let hide: () -> Void
        let close: () -> Void
        let frameChanged: (CGRect) -> Void
        let geometryInteractionChanged: (Bool) -> Void
    }

    private enum GeometryInteraction: Equatable {
        case dragging
        case resizing
    }

    private let actions: Actions
    private var chrome: MiniWindowChromeView!
    private let watchlist = StockWatchlist()
    private let stockChart = StockChartHover()
    private var currentState: WindowSnapshot?
    private enum Page { case home, web, terminal, stocks }
    @MainActor
    private final class Tab {
        let number: Int
        var page = Page.home
        var forwardPage: Page?
        var terminal: ShellTerminalView?
        var web: WebContent?
        var stocksView: NSHostingView<StocksView>?

        init(number: Int) { self.number = number }

        var title: String {
            switch page {
            case .home: return "首页 \(number)"
            case .terminal: return "终端 \(number)"
            case .stocks: return "自选股 \(number)"
            case .web: return "网页 \(number)"
            }
        }

        func dispose() {
            stocksView?.removeFromSuperview()
            stocksView = nil
            terminal?.endSession()
            terminal?.removeFromSuperview()
            terminal = nil
            web?.onNavigationChanged = nil
            web?.stop()
            web?.webView.removeFromSuperview()
            web = nil
        }
    }

    private var tabs: [Tab]
    private var selected: Tab
    private var nextTabNumber = 2
    private var geometryInteraction: GeometryInteraction?
    private var dragCompletionTimer: Timer?
    private var lockRecoveryPanel: LockRecoveryPanel?
    private let settingsPanel = TransparencySettingsPanel()
    private var backgroundOpacity: Double = 0.75
    private var contentOpacity: Double = 0.75
    private var isDisposed = false

    var bodyFrame: NSRect { convertToScreen(chrome.convert(chrome.bounds, to: nil)) }

    var keepsWindowVisible: Bool { settingsPanel.isVisible || stockChart.containsPointer }

    init(frame: CGRect, actions: Actions) {
        self.actions = actions
        let first = Tab(number: 1)
        selected = first
        tabs = [first]
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        title = "Oriel 迷你窗"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = false
        contentMinSize = CGSize(width: min(frame.width, 120), height: min(frame.height, 90))
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .aqua)
        hasShadow = false

        chrome = MiniWindowChromeView(actions: .init(
            addTab: { [weak self] in self?.addTab() },
            selectTab: { [weak self] in self?.selectTab(number: $0) },
            closeTab: { [weak self] in self?.closeTab(number: $0) },
            openTerminal: { [weak self] in self?.showTerminal() },
            openStocks: { [weak self] in self?.showStocks() },
            toggleAutomaticHiding: actions.toggleAutomaticHiding,
            settings: { [weak self] sender in self?.showSettings(from: sender) },
            toggleLock: actions.toggleLock,
            hide: actions.hide,
            close: actions.close,
            drag: { [weak self] event in self?.beginDrag(with: event) }
        ))
        let shadowView = PanelShadowView(frame: NSRect(origin: .zero, size: frame.size))
        contentView = shadowView
        chrome.frame = shadowView.bodyRect
        shadowView.addSubview(chrome)
        applyTransparency()
        refreshTabs()
        delegate = self
    }

    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }

    func cancelGeometryInteraction() {
        finishGeometryInteraction(reportFinalFrame: false, notify: false)
    }

    func apply(_ state: WindowSnapshot) {
        guard !isDisposed else { return }
        currentState = state
        watchlist.setVisible(state.isVisible && selected.page == .stocks)
        if !state.isVisible { chrome?.dismissTooltip() }
        if state.isLocked || !state.isVisible {
            stockChart.dismiss()
            if let terminal = selected.terminal, firstResponder === terminal { makeFirstResponder(nil) }
            settingsPanel.performClose(nil)
            // The corresponding controller command already ends the interaction.
            // Applying a snapshot must not synchronously emit a new state transition.
            finishGeometryInteraction(reportFinalFrame: false, notify: false)
        }
        if state.isLocked && isKeyWindow { resignKey() }
        ignoresMouseEvents = state.isLocked
        alphaValue = state.opacity
        updateToolbar()
        if state.isVisible && !isVisible {
            // Automatic revelation must not activate the app or acquire keyboard focus.
            orderFrontRegardless()
        } else if !state.isVisible && isVisible {
            orderOut(nil)
        }
        synchronizeLockRecovery()
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        stockChart.dismiss()
        watchlist.setVisible(false)
        settingsPanel.performClose(nil)
        settingsPanel.contentViewController = nil
        delegate = nil
        finishGeometryInteraction(reportFinalFrame: false, notify: false)
        hideLockRecovery()
        lockRecoveryPanel?.close()
        lockRecoveryPanel = nil
        for tab in tabs { tab.dispose() }
        tabs.removeAll()
        contentView = nil
        chrome = nil
        orderOut(nil)
        close()
    }

    func beginDrag(with event: NSEvent) {
        guard !isDisposed, !ignoresMouseEvents, isVisible,
              event.type == .leftMouseDown, geometryInteraction == nil else { return }
        beginGeometryInteraction(.dragging)
        guard !isDisposed, geometryInteraction == .dragging else { return }

        // Window Server dragging returns immediately and may not deliver mouseUp.
        // Keep this fallback only for the gesture, rather than ending on return.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.geometryInteraction == .dragging else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 || self.ignoresMouseEvents || !self.isVisible {
                    self.finishGeometryInteraction()
                }
            }
        }
        dragCompletionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        performDrag(with: event)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isDisposed else { return }
        positionLockRecovery()
        actions.frameChanged(bodyFrame)
    }

    func windowDidResize(_ notification: Notification) {
        guard !isDisposed else { return }
        positionLockRecovery()
        actions.frameChanged(bodyFrame)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard !isDisposed, !ignoresMouseEvents, isVisible else { return }
        beginGeometryInteraction(.resizing)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !isDisposed, geometryInteraction == .resizing else { return }
        finishGeometryInteraction()
    }

    private func beginGeometryInteraction(_ interaction: GeometryInteraction) {
        guard geometryInteraction == nil else { return }
        stockChart.dismiss()
        geometryInteraction = interaction
        actions.geometryInteractionChanged(true)
    }

    private func finishGeometryInteraction(reportFinalFrame: Bool = true, notify: Bool = true) {
        dragCompletionTimer?.invalidate()
        dragCompletionTimer = nil
        guard geometryInteraction != nil else { return }
        // Reset before callbacks, which can synchronously apply another snapshot.
        geometryInteraction = nil
        if reportFinalFrame && !isDisposed { actions.frameChanged(bodyFrame) }
        if notify { actions.geometryInteractionChanged(false) }
    }

    private func updateToolbar() {
        chrome?.update(
            isLocked: currentState?.isLocked ?? false,
            automaticHiding: currentState?.automaticHiding ?? false
        )
    }

    private func synchronizeLockRecovery() {
        guard currentState?.isLocked == true, currentState?.isVisible == true, isVisible else {
            hideLockRecovery()
            return
        }
        if lockRecoveryPanel == nil {
            lockRecoveryPanel = LockRecoveryPanel { [weak self] in
                guard let self, !self.isDisposed,
                      self.currentState?.isLocked == true,
                      self.currentState?.isVisible == true else { return }
                self.actions.unlock()
            }
        }
        guard let recovery = lockRecoveryPanel else { return }
        positionLockRecovery()
        recovery.alphaValue = alphaValue * backgroundOpacity
        if recovery.parent == nil { addChildWindow(recovery, ordered: .above) }
        if !recovery.isVisible { recovery.orderFrontRegardless() }
    }

    private func positionLockRecovery() {
        // The hit surface exactly overlays the existing lock icon; it adds no visible control.
        let icon = MiniWindowChromeView.lockControlFrame(for: chrome.bounds.width)
        lockRecoveryPanel?.setFrame(convertToScreen(chrome.convert(icon, to: nil)), display: true)
    }

    private func hideLockRecovery() {
        guard let recovery = lockRecoveryPanel else { return }
        recovery.orderOut(nil)
        if recovery.parent != nil { removeChildWindow(recovery) }
    }

    private func refreshTabs() {
        chrome.setTabs(tabs.map { ($0.number, $0.title) }, selected: selected.number)
    }

    private var canManageTabs: Bool {
        !isDisposed && isVisible && currentState?.isLocked == false
    }

    private func addTab() {
        guard canManageTabs else { return }
        let tab = Tab(number: nextTabNumber)
        nextTabNumber += 1
        tabs.append(tab)
        activate(tab)
    }

    private func selectTab(number: Int) {
        guard canManageTabs, let tab = tabs.first(where: { $0.number == number }) else { return }
        activate(tab)
    }

    private func closeTab(number: Int) {
        guard canManageTabs, let index = tabs.firstIndex(where: { $0.number == number }) else { return }
        let closed = tabs.remove(at: index)
        let wasSelected = closed === selected
        if wasSelected { makeFirstResponder(nil) }
        closed.dispose()
        guard wasSelected else {
            refreshTabs()
            return
        }
        if tabs.isEmpty {
            addTab()
        } else {
            activate(tabs[min(index, tabs.count - 1)])
        }
    }

    private func activate(_ tab: Tab) {
        stockChart.dismiss()
        makeFirstResponder(nil)
        selected = tab
        watchlist.setVisible(tab.page == .stocks && currentState?.isVisible == true)
        switch tab.page {
        case .stocks:
            if tab.stocksView == nil {
                let view = NSHostingView(rootView: StocksView(list: watchlist) { [weak self, weak tab] symbol, inside in
                    guard let self, selected === tab, selected.page == .stocks else { return }
                    if !inside { stockChart.exit(symbol.id) }
                    else if canManageTabs && geometryInteraction == nil {
                        stockChart.enter(symbol, quote: watchlist.quotes[symbol.id], parent: self)
                    }
                })
                view.sizingOptions = []
                tab.stocksView = view
            }
            if let view = tab.stocksView {
                chrome.showStocks(view)
                makeKeyAndOrderFront(nil)
            }
        case .terminal:
            if let view = tab.terminal {
                chrome.showTerminal(view)
                makeKeyAndOrderFront(nil)
                makeFirstResponder(view)
            }
        case .web:
            if let web = tab.web { chrome.showWebContent(web.webView) }
        case .home:
            chrome.showHome()
        }
        refreshTabs()
        updateToolbar()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if canManageTabs, isKeyWindow,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "t": addTab(); return true
            case "w": closeTab(number: selected.number); return true
            case "[" where selected.page != .home: goBack(); return true
            case "]" where selected.forwardPage != nil || selected.page == .web: goForward(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func goBack() {
        if selected.page == .web, let web = selected.web, web.webView.canGoBack {
            web.webView.goBack()
        } else {
            selected.forwardPage = selected.page
            if selected.page == .terminal, selected.terminal?.isRunning == false {
                selected.terminal?.removeFromSuperview()
                selected.terminal = nil
                selected.forwardPage = nil
            }
            selected.page = .home
            activate(selected)
        }
    }

    @objc private func goForward() {
        switch (selected.page, selected.forwardPage) {
        case (.home, .terminal): showTerminal()
        case (.home, .stocks): showStocks()
        case (.home, .web): showFixture()
        case (.web, _): selected.web?.webView.goForward()
        default: break
        }
    }

    private func showStocks() {
        guard canManageTabs else { return }
        selected.page = .stocks
        activate(selected)
    }

    private func showFixture() {
        let tab = selected
        if tab.web == nil {
            let web = WebContent()
            tab.web = web
            web.onNavigationChanged = { [weak self, weak tab] in
                guard let self, self.selected === tab else { return }
                self.updateToolbar()
            }
            web.loadFixture()
        }
        tab.page = .web
        activate(tab)
    }

    private func showTerminal() {
        guard canManageTabs else { return }
        let tab = selected
        let needsShell = tab.terminal == nil
        let view = tab.terminal ?? ShellTerminalView(frame: chrome.bounds)
        tab.terminal = view
        tab.page = .terminal
        activate(tab)
        guard needsShell else { return }
        view.onExit = { [weak self, weak tab, weak view] in
            guard let self, !self.isDisposed, let tab, let view, tab.terminal === view else { return }
            view.removeFromSuperview()
            tab.terminal = nil
            if tab.forwardPage == .terminal { tab.forwardPage = nil }
            if tab.page == .terminal {
                tab.page = .home
                if self.selected === tab {
                    self.makeFirstResponder(nil)
                    self.chrome.showHome()
                }
            }
            if self.selected === tab { self.updateToolbar() }
            self.refreshTabs()
        }
        if !view.launchShell() {
            view.feed(text: "无法启动 Shell。返回首页后可重试。")
        }
    }

    private func applyTransparency() {
        (contentView as? PanelShadowView)?.shadowStrength = backgroundOpacity
        chrome.setContentOpacity(background: backgroundOpacity, content: contentOpacity)
    }

    private func showSettings(from sender: NSView) {
        guard !isDisposed, currentState?.isLocked != true else { return }
        if settingsPanel.isVisible {
            settingsPanel.performClose(nil)
            return
        }
        chrome.dismissTooltip()
        settingsPanel.contentViewController = TransparencySettingsController(
            background: backgroundOpacity, content: contentOpacity
        ) { [weak self] background, content in
            guard let self, !self.isDisposed else { return }
            self.backgroundOpacity = background
            self.contentOpacity = content
            self.applyTransparency()
        }
        settingsPanel.show(below: sender)
    }

}

@MainActor
private final class PanelShadowView: NSView {
    var bodyRect: NSRect { bounds.insetBy(dx: 4, dy: 4) }
    var shadowStrength: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Sample the same four-point falloff along every edge and around each corner.
        let opacities: [CGFloat] = [0.125, 0.075, 0.03, 0.006]
        for (index, opacity) in opacities.enumerated() {
            let distance = CGFloat(index) + 0.5
            let rect = bodyRect.insetBy(dx: -distance, dy: -distance)
            let ring = NSBezierPath(roundedRect: rect, xRadius: 8 + distance, yRadius: 8 + distance)
            ring.lineWidth = 1
            NSColor.black.withAlphaComponent(opacity * shadowStrength).setStroke()
            ring.stroke()
        }
    }
}

@MainActor
private final class LockRecoveryPanel: NSPanel {
    init(unlock: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 28, height: 28),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "取消穿透"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        appearance = NSAppearance(named: .aqua)
        contentView = MiniWindowChromeView.makeLockRecoveryControl(unlock: unlock)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


/// A small anchored panel gives the compact settings a controlled corner radius.
@MainActor
private final class TransparencySettingsPanel: NSPanel {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 224, height: 72),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "透明度设置"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        appearance = NSAppearance(named: .aqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(below anchor: NSView) {
        guard let owner = anchor.window, let content = contentViewController?.view else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 1).cgColor
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true
        let anchorFrame = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let size = content.frame.size
        let screen = owner.screen?.visibleFrame ?? owner.frame
        let x = min(max(anchorFrame.maxX - size.width, screen.minX + 4), screen.maxX - size.width - 4)
        var y = anchorFrame.minY - size.height - 4
        if y < screen.minY + 4 { y = anchorFrame.maxY + 4 }
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)
        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
        owner.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)

        // Keep slider drags inside the panel; close on clicks elsewhere or Escape.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self, weak anchor] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.performClose(nil)
                    return nil
                }
            } else if event.window !== self {
                // Let the anchor button toggle this panel itself.
                if let anchor, event.window === anchor.window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                    return event
                }
                self.performClose(nil)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.performClose(nil)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.performClose(nil) }
        }
    }

    override func performClose(_ sender: Any?) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        localMonitor = nil
        globalMonitor = nil
        activationObserver = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

@MainActor
private final class OpacitySliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let y = rect.midY
        let knob = knobRect(flipped: flipped)
        let track = rect.insetBy(dx: knob.width / 2, dy: 0)
        let thumbX = min(max(knob.midX, track.minX), track.maxX)
        let blue = NSColor.systemBlue
        let gray = NSColor(white: 0.8, alpha: 1)
        gray.setFill()
        NSRect(x: track.minX, y: y - 1.5, width: track.width, height: 3).fill()
        blue.setFill()
        NSRect(x: track.minX, y: y - 1.5, width: thumbX - track.minX, height: 3).fill()
        for tick in 0...4 {
            let x = track.minX + CGFloat(tick) * track.width / 4
            (x <= thumbX ? blue : gray).setFill()
            NSRect(x: x - 0.5, y: y - 3, width: 1, height: 6).fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        let thumb = NSRect(x: knobRect.midX - 3.5, y: knobRect.midY - 8, width: 7, height: 16)
        let path = NSBezierPath(roundedRect: thumb, xRadius: 3.5, yRadius: 3.5)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.85, alpha: 1).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

@MainActor
private final class TransparencySettingsController: NSViewController {
    private let backgroundSlider: NSSlider
    private let contentSlider: NSSlider
    private let changed: (Double, Double) -> Void

    init(background: Double, content: Double, changed: @escaping (Double, Double) -> Void) {
        backgroundSlider = Self.makeSlider(value: background)
        contentSlider = Self.makeSlider(value: content)
        self.changed = changed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    private static func makeSlider(value: Double) -> NSSlider {
        let slider = NSSlider(frame: .zero)
        slider.cell = OpacitySliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.altIncrementValue = 0.1
        slider.doubleValue = value
        return slider
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 224, height: 72))
        view.appearance = NSAppearance(named: .aqua)
        let rows: [(String, NSSlider, CGFloat)] = [
            ("内容透明度", contentSlider, 44),
            ("背景透明度", backgroundSlider, 12)
        ]
        for (title, slider, y) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.frame = NSRect(x: 12, y: y, width: 66, height: 17)
            slider.frame = NSRect(x: 83, y: y - 3, width: 132, height: 23)
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderChanged)
            slider.setAccessibilityLabel(title)
            slider.setAccessibilityHelp("向左变透明，向右变清晰")
            view.addSubview(label)
            view.addSubview(slider)
        }
    }

    @objc private func sliderChanged() {
        changed(backgroundSlider.doubleValue, contentSlider.doubleValue)
    }
}
