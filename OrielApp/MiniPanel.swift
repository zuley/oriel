import AppKit
import Combine
import OrielCore
import OrielReading

@MainActor
final class MiniPanel: NSPanel, NSWindowDelegate {
    struct Actions {
        let toggleLock: () -> Void
        let unlock: () -> Void
        let toggleAutomaticHiding: () -> Void
        var toggleAllSpaces: () -> Void = {}
        let recover: () -> Void
        let hide: () -> Void
        let close: () -> Void
        let frameChanged: (CGRect) -> Void
        let geometryInteractionChanged: (Bool) -> Void
        var toggleAutomaticFolding: () -> Void = {}
        var renameWindow: () -> Void = {}
        var noteIsOpenElsewhere: (UUID) -> Bool = { _ in false }
        var focusNoteElsewhere: (UUID) -> Bool = { _ in false }
        var transparencyRecoveryChanged: (Bool) -> Void = { _ in }
    }

    enum GeometryInteraction: Equatable {
        case dragging
        case resizing
    }

    let actions: Actions
    private(set) var chrome: MiniWindowChromeView!
    let pages: PageFactory
    private(set) var currentState: WindowSnapshot?
    let windowTabs = WindowTabs()
    var selected: WindowTab { windowTabs.selected }
    /// The page on screen; told when it leaves.
    var presented: TabPage?
    var noteChanges: AnyCancellable?
    var noteRefreshPending = false
    private(set) var geometryInteraction: GeometryInteraction?
    private var resizeStart: (frame: NSRect, pointer: NSPoint)?
    private var dragCompletionTimer: Timer?
    weak var hoveredResizeHandle: PanelResizeHandle?
    private var lockRecoveryPanel: LockRecoveryPanel?
    private let settingsPanel = WindowSettingsPanel()
    private var settingsCloseTimer: Timer?
    private var backgroundOpacity: Double = 0.75
    private var emphasis: WindowGroupController.Emphasis = .normal
    private var contentOpacity: Double = 0.75
    private var revealingToolbar = false
    private var trackingMenus = Set<ObjectIdentifier>()
    private(set) var isDisposed = false
    private var applyingPresentationFrame = false
    private var expandedMinimumHeight: CGFloat = 90

    var bodyFrame: NSRect {
        let body = convertToScreen(chrome.convert(chrome.bounds, to: nil))
        guard let state = currentState, state.isFolded else { return body }
        let y = state.foldingEdge == .bottom ? body.minY : body.maxY - state.frame.height
        return NSRect(x: body.minX, y: y,
                      width: body.width, height: state.frame.height)
    }

    var foldingVisibleFrame: NSRect? {
        let body = convertToScreen(chrome.convert(chrome.bounds, to: nil))
        let barY = currentState?.isFolded == true ? body.midY
            : (currentState?.foldingEdge == .bottom ? body.minY + 14 : body.maxY - 14)
        let anchor = NSPoint(x: body.midX, y: barY)
        let display = NSScreen.screens.first { $0.frame.contains(anchor) } ?? screen ?? NSScreen.main
        // Core stores the body; leave room for the native adapter's four-point shadow.
        return display?.visibleFrame.insetBy(dx: 4, dy: 4)
    }

    var hasEditingFocus: Bool {
        guard isKeyWindow, let responder = firstResponder, let page = selected.current else { return false }
        return page.hasEditingFocus(responder)
    }

    var keepsWindowVisible: Bool {
        attachedSheet != nil || settingsPanel.isVisible || selected.current?.keepsWindowVisible == true
            || !trackingMenus.isEmpty
    }

    init(frame: CGRect, library: NovelLibrary, watchlist: StockWatchlist, preferences: AppPreferences, actions: Actions) {
        self.actions = actions
        pages = PageFactory(library: library, watchlist: watchlist, notes: NotesWorkspace.shared)
        self.backgroundOpacity = preferences.backgroundOpacity
        self.contentOpacity = preferences.contentOpacity
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        title = "Oriel 迷你窗"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.stationary, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        contentMinSize = CGSize(width: min(frame.width, 120), height: min(frame.height, 90))
        expandedMinimumHeight = contentMinSize.height
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .aqua)
        animationBehavior = .none
        hasShadow = false

        chrome = MiniWindowChromeView(actions: .init(
            addTab: { [weak self] in self?.addTab() },
            selectTab: { [weak self] in self?.selectTab(number: $0) },
            closeTab: { [weak self] in self?.closeTab(number: $0) },
            openPage: { [weak self] kind in self?.openPage(kind) },
            dropNovel: { [weak self] urls in
                guard let self, canManageTabs else { return false }
                openPage(.novel)
                (selected.current as? NovelPage)?.openFiles(urls)
                return true
            },
            renameWindow: actions.renameWindow,
            windowSettings: { [weak self] sender in self?.showSettings(from: sender) },
            settingsHover: { [weak self] entered in self?.settingsHoverChanged(entered) },
            toggleFolding: actions.toggleAutomaticFolding,
            toggleAutomaticHiding: actions.toggleAutomaticHiding,
            toggleAllSpaces: actions.toggleAllSpaces,
            toggleLock: actions.toggleLock,
            hide: actions.hide,
            close: actions.close,
            drag: { [weak self] event in self?.beginDrag(with: event) }
        ))
        let shadowView = PanelShadowView(frame: NSRect(origin: .zero, size: frame.size))
        contentView = shadowView
        chrome.frame = shadowView.bodyRect
        shadowView.chrome = chrome
        shadowView.addSubview(chrome)
        shadowView.installResizeHandles()
        applyTransparency()
        refreshTabs()
        showHome()
        delegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEnded(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func menuBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, canManageTabs,
              !trackingMenus.isEmpty || frame.contains(NSEvent.mouseLocation) else { return }
        trackingMenus.insert(ObjectIdentifier(menu))
    }

    @objc private func menuEnded(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { trackingMenus.remove(ObjectIdentifier(menu)) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleTabKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }

    func setAppearsOnAllSpaces(_ enabled: Bool) {
        guard !isDisposed else { return }
        var behavior = collectionBehavior
        if enabled { behavior.insert(.canJoinAllSpaces) }
        else { behavior.remove(.canJoinAllSpaces) }
        collectionBehavior = behavior
        chrome.setAppearsOnAllSpaces(enabled)
        lockRecoveryPanel?.collectionBehavior = behavior
    }

    func setWindowName(_ name: String) {
        title = "Oriel · \(name)"
        chrome.setWindowName(name)
    }

    func cancelGeometryInteraction() {
        finishGeometryInteraction(reportFinalFrame: false, notify: false)
    }

    func prepareForFolding() {
        selected.current?.commitEditing()
        makeFirstResponder(nil)
    }

    func apply(_ state: WindowSnapshot) {
        guard !isDisposed else { return }
        currentState = state
        presented?.windowVisibilityChanged(state.isVisible)
        if !state.isVisible { chrome?.dismissTooltip() }
        if state.isLocked || !state.isVisible {
            pages.library.flushPlaces()
            if let sheet = attachedSheet { endSheet(sheet, returnCode: .cancel) }
            hoveredResizeHandle?.releaseCursor()
            presented?.windowWillConceal()
            if hasEditingFocus {
                presented?.commitEditing()
                try? NotesWorkspace.shared.saveAll()
                makeFirstResponder(nil)
            }
            settingsPanel.performClose(nil)
            // The corresponding controller command already ends the interaction.
            // Applying a snapshot must not synchronously emit a new state transition.
            finishGeometryInteraction(reportFinalFrame: false, notify: false)
        }
        if state.isLocked && isKeyWindow { resignKey() }
        ignoresMouseEvents = state.isLocked
        alphaValue = state.opacity * (emphasis == .dimmed ? 0.22 : 1)
        if !state.isVisible && isVisible { orderOut(nil) }
        applyPresentationFrame(state)
        updateToolbar()
        if state.isVisible && !isVisible {
            // Automatic revelation must not activate the app or acquire keyboard focus.
            orderFrontRegardless()
        } else if !state.isVisible && isVisible {
            orderOut(nil)
        }
        synchronizeLockRecovery()
    }

    private func applyPresentationFrame(_ state: WindowSnapshot) {
        applyingPresentationFrame = true
        defer { applyingPresentationFrame = false }
        if state.isFolded { chrome.setFolded(true) }
        contentMinSize.height = state.isFolded ? min(expandedMinimumHeight, 36) : expandedMinimumHeight
        let target = state.presentationFrame.insetBy(dx: -4, dy: -4)
        if frame != target {
            setFrame(target, display: state.isVisible)
        }
        if !state.isFolded { chrome.setFolded(false) }
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        cancelSettingsClose()
        noteChanges = nil
        if let sheet = attachedSheet { endSheet(sheet, returnCode: .cancel) }
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        trackingMenus.removeAll()
        hoveredResizeHandle?.releaseCursor()
        presented = nil
        settingsPanel.performClose(nil)
        settingsPanel.contentViewController = nil
        delegate = nil
        finishGeometryInteraction(reportFinalFrame: false, notify: false)
        hideLockRecovery()
        lockRecoveryPanel?.close()
        lockRecoveryPanel = nil
        windowTabs.dispose()
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

    func startEdgeResize(_ event: NSEvent) {
        guard !isDisposed, isVisible, !ignoresMouseEvents, geometryInteraction == nil,
              currentState?.isFolded != true else { return }
        resizeStart = (frame, convertPoint(toScreen: event.locationInWindow))
        beginGeometryInteraction(.resizing)
    }

    func dragEdge(_ edge: PanelResizeEdge, event: NSEvent) {
        guard let start = resizeStart else { return }
        let pointer = convertPoint(toScreen: event.locationInWindow)
        var rect = start.frame
        let dx = pointer.x - start.pointer.x
        let dy = pointer.y - start.pointer.y
        if edge.contains(.left) {
            rect.size.width = max(contentMinSize.width, start.frame.width - dx)
            rect.origin.x = start.frame.maxX - rect.width
        } else if edge.contains(.right) {
            rect.size.width = max(contentMinSize.width, start.frame.width + dx)
        }
        if edge.contains(.bottom) {
            rect.size.height = max(contentMinSize.height, start.frame.height - dy)
            rect.origin.y = start.frame.maxY - rect.height
        } else if edge.contains(.top) {
            rect.size.height = max(contentMinSize.height, start.frame.height + dy)
        }
        if rect != frame { setFrame(rect, display: true) }
    }

    func endEdgeResize() {
        if resizeStart != nil { finishGeometryInteraction() }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isDisposed else { return }
        positionLockRecovery()
        guard !applyingPresentationFrame else { return }
        actions.frameChanged(bodyFrame)
    }

    func windowDidResize(_ notification: Notification) {
        guard !isDisposed else { return }
        positionLockRecovery()
        guard !applyingPresentationFrame else { return }
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
        presented?.dismissPopovers()
        geometryInteraction = interaction
        actions.geometryInteractionChanged(true)
    }

    private func finishGeometryInteraction(reportFinalFrame: Bool = true, notify: Bool = true) {
        resizeStart = nil
        dragCompletionTimer?.invalidate()
        dragCompletionTimer = nil
        guard geometryInteraction != nil else { return }
        // Reset before callbacks, which can synchronously apply another snapshot.
        geometryInteraction = nil
        if reportFinalFrame && !isDisposed { actions.frameChanged(bodyFrame) }
        if notify { actions.geometryInteractionChanged(false) }
    }

    func updateToolbar() {
        chrome?.update(
            isLocked: currentState?.isLocked ?? false,
            automaticHiding: currentState?.automaticHiding ?? false,
            automaticFolding: currentState?.automaticFolding ?? false
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
        recovery.collectionBehavior = collectionBehavior
        positionLockRecovery()
        recovery.alphaValue = alphaValue
        recovery.button.restingOpacity = backgroundOpacity
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

    func applyDefaults(_ preferences: AppPreferences) {
        guard !isDisposed else { return }
        cancelGeometryInteraction()
        backgroundOpacity = preferences.backgroundOpacity
        contentOpacity = preferences.contentOpacity
        applyTransparency()
        actions.transparencyRecoveryChanged(max(backgroundOpacity, contentOpacity) <= 0.05)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            let width = min(preferences.width, visible.width)
            let height = min(preferences.height, visible.height)
            let expanded = currentState?.frame.insetBy(dx: -4, dy: -4) ?? frame
            let target = NSRect(x: min(max(expanded.minX, visible.minX), visible.maxX - width),
                                y: min(max(expanded.maxY - height, visible.minY), visible.maxY - height),
                                width: width, height: height)
            actions.frameChanged(target.insetBy(dx: 4, dy: 4))
        }
    }

    func setEmphasis(_ emphasis: WindowGroupController.Emphasis) {
        guard !isDisposed, self.emphasis != emphasis else { return }
        self.emphasis = emphasis
        alphaValue = (currentState?.opacity ?? 1) * (emphasis == .dimmed ? 0.22 : 1)
        (contentView as? PanelShadowView)?.highlighted = emphasis == .highlighted
        applyTransparency()
        if emphasis == .highlighted && isVisible { orderFrontRegardless() }
        synchronizeLockRecovery()
    }

    private func applyTransparency() {
        (contentView as? PanelShadowView)?.shadowStrength = backgroundOpacity
        let highlighted = emphasis == .highlighted
        chrome.setContentOpacity(background: highlighted ? max(0.9, backgroundOpacity) : backgroundOpacity,
                                 content: highlighted ? max(0.9, contentOpacity) : contentOpacity,
                                 revealToolbar: revealingToolbar)
    }

    func revealTransparencySettings() {
        revealingToolbar = true
        applyTransparency()
        if !settingsPanel.isVisible { showSettings(from: chrome.windowButton) }
    }

    private func settingsHoverChanged(_ entered: Bool) {
        if entered {
            cancelSettingsClose()
            showSettings(from: chrome.windowButton)
        } else {
            scheduleSettingsClose()
        }
    }

    private func cancelSettingsClose() {
        settingsCloseTimer?.invalidate()
        settingsCloseTimer = nil
    }

    private func scheduleSettingsClose() {
        guard settingsPanel.isVisible else { return }
        cancelSettingsClose()
        let timer = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settingsPanel.isVisible else { return }
                self.settingsCloseTimer = nil
                if NSEvent.pressedMouseButtons != 0 {
                    self.scheduleSettingsClose()
                    return
                }
                let pointer = NSEvent.mouseLocation
                let button = self.chrome.windowButton
                let buttonFrame = self.convertToScreen(button.convert(button.bounds, to: nil))
                if !buttonFrame.insetBy(dx: -4, dy: -6).contains(pointer)
                    && !self.settingsPanel.frame.insetBy(dx: -4, dy: -6).contains(pointer) {
                    self.settingsPanel.performClose(nil)
                }
            }
        }
        settingsCloseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Hovering the settings icon opens the two opacity sliders.
    private func showSettings(from sender: NSView) {
        guard !isDisposed, currentState?.isLocked != true else { return }
        cancelSettingsClose()
        guard !settingsPanel.isVisible else { return }
        chrome.dismissTooltip()
        settingsPanel.onPointerEntered = { [weak self] in self?.cancelSettingsClose() }
        settingsPanel.onPointerExited = { [weak self] in self?.scheduleSettingsClose() }
        settingsPanel.onDismiss = { [weak self] in
            guard let self else { return }
            self.cancelSettingsClose()
            self.chrome.setSettingsPanelOpen(false)
            guard !self.isDisposed else { return }
            self.revealingToolbar = false
            self.applyTransparency()
        }
        settingsPanel.contentViewController = WindowSettingsController(
            background: backgroundOpacity,
            content: contentOpacity,
            changed: { [weak self] background, content in
                guard let self, !self.isDisposed else { return }
                self.backgroundOpacity = background
                self.contentOpacity = content
                self.applyTransparency()
                self.actions.transparencyRecoveryChanged(max(background, content) <= 0.05)
            }
        )
        // Recovery may open settings while its toolbar button is still tucked away.
        // Lay out the expanded controls before using that button as the anchor.
        chrome.setSettingsPanelOpen(true)
        chrome.layoutSubtreeIfNeeded()
        settingsPanel.show(below: sender)
        if !settingsPanel.isVisible { chrome.setSettingsPanelOpen(false) }
    }

}
