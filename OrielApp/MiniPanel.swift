import AppKit
import SwiftUI
import Combine
import OrielCore
import OrielReading
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
        var toggleAutomaticFolding: () -> Void = {}
        var renameWindow: () -> Void = {}
        var noteIsOpenElsewhere: (UUID) -> Bool = { _ in false }
        var focusNoteElsewhere: (UUID) -> Bool = { _ in false }
        var transparencyRecoveryChanged: (Bool) -> Void = { _ in }
    }

    fileprivate enum GeometryInteraction: Equatable {
        case dragging
        case resizing
    }

    fileprivate let actions: Actions
    private var chrome: MiniWindowChromeView!
    private let pages: PageFactory
    private var currentState: WindowSnapshot?
    @MainActor
    fileprivate final class Tab {
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
        var notes: NotesPage? { pages[.notes] as? NotesPage }
        var terminal: TerminalPage? { pages[.terminal] as? TerminalPage }

        func dispose() {
            for page in pages.values { page.dispose() }
            pages.removeAll()
        }
    }

    fileprivate var tabs: [Tab]
    fileprivate var selected: Tab
    /// The page on screen; told when it leaves.
    fileprivate var presented: TabPage?
    private var nextTabNumber = 2
    private var noteChanges: AnyCancellable?
    private var noteRefreshPending = false
    fileprivate var geometryInteraction: GeometryInteraction?
    private var resizeStart: (frame: NSRect, pointer: NSPoint)?
    private var dragCompletionTimer: Timer?
    weak var hoveredResizeHandle: PanelResizeHandle?
    private var lockRecoveryPanel: LockRecoveryPanel?
    private let settingsPanel = WindowSettingsPanel()
    private var backgroundOpacity: Double = 0.75
    private var emphasis: WindowGroupController.Emphasis = .normal
    private var contentOpacity: Double = 0.75
    private var revealingToolbar = false
    private var trackingMenus = Set<ObjectIdentifier>()
    fileprivate var isDisposed = false
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
            toggleFolding: actions.toggleAutomaticFolding,
            toggleAutomaticHiding: actions.toggleAutomaticHiding,
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

    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }

    func setWindowName(_ name: String) {
        title = "Oriel · \(name)"
        chrome.setWindowName(name)
    }

    func confirmCanClose() -> Bool {
        NotesWorkspace.shared.confirmCanClose(documentIDs: Set(tabs.compactMap { $0.notes?.noteID }))
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

    fileprivate func updateToolbar() {
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

    fileprivate func refreshTabs() {
        guard !isDisposed else { return }
        if !tabs.contains(where: { $0.notes != nil }) { noteChanges = nil }
        chrome.setTabs(tabs.map { ChromeTab(number: $0.number, title: $0.title, kind: $0.page) },
                       selected: selected.number)
    }

    /// Every return to the launcher shows the page tiles.
    fileprivate func showHome() {
        chrome.showHome()
    }

    private func observeNoteTitles() {
        guard noteChanges == nil else { return }
        noteChanges = NotesWorkspace.shared.objectWillChange.sink { [weak self] in
            guard let self, !isDisposed, !noteRefreshPending else { return }
            noteRefreshPending = true
            // One refresh per window/run-loop turn, after published records are updated.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                noteRefreshPending = false
                refreshTabs()
            }
        }
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

    var canManageTabs: Bool {
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

    /// Titles of terminal tabs whose shell is running a command.
    var busyTerminalTitles: [String] {
        CloseGuard.busyTitles(tabs.compactMap { tab in
            tab.terminal.map { CloseGuard.Terminal(title: $0.title, busy: $0.isBusy) }
        })
    }

    /// Ask before ending running commands. `proceed` runs only after confirmation.
    func confirmEndingJobs(_ message: String, button: String, proceed: @escaping () -> Void) {
        guard !isDisposed, attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "终端中有任务正在运行"
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: self) { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
    }

    private func closeTab(number: Int) {
        guard canManageTabs, let tab = tabs.first(where: { $0.number == number }) else { return }
        if let terminal = tab.terminal, terminal.isBusy,
           let message = CloseGuard.message(busy: [terminal.title]) {
            confirmEndingJobs(message, button: "结束并关闭") { [weak self, weak tab] in
                guard let self, let tab, self.canManageTabs else { return }
                self.performCloseTab(number: tab.number)
            }
            return
        }
        performCloseTab(number: number)
    }

    private func performCloseTab(number: Int) {
        guard canManageTabs, let index = tabs.firstIndex(where: { $0.number == number }) else { return }
        let noteIDs = Set([tabs[index].notes?.noteID].compactMap { $0 })
        guard NotesWorkspace.shared.confirmCanClose(documentIDs: noteIDs) else { return }
        let closed = tabs.remove(at: index)
        let wasSelected = closed === selected
        if wasSelected {
            makeFirstResponder(nil)
            presented = nil
        }
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
        let page = tab.current
        presented?.commitEditing()
        if let presented, presented !== page { presented.willDeactivate() }
        try? NotesWorkspace.shared.saveAll()
        makeFirstResponder(nil)
        selected = tab
        presented = page
        if let page {
            switch page.surface {
            case .terminal: chrome.showTerminal(page.view)
            case .reading: chrome.showReadingSurface(page.view)
            }
            makeKeyAndOrderFront(nil)
            page.didActivate()
            page.windowVisibilityChanged(currentState?.isVisible == true)
        } else {
            showHome()
        }
        if tab.notes != nil { observeNoteTitles() }
        refreshTabs()
        updateToolbar()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard canManageTabs, isKeyWindow, attachedSheet == nil else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if tabs.count > 1, let index = tabs.firstIndex(where: { $0 === selected }) {
            if modifiers == .command, let key, let digit = Int(key), (1...9).contains(digit) {
                let target = digit == 9 ? tabs.count - 1 : digit - 1
                if tabs.indices.contains(target) { activate(tabs[target]); return true }
            }
            let step: Int
            switch (modifiers, key) {
            case (.control, _) where event.keyCode == 48: step = 1
            case ([.control, .shift], _) where event.keyCode == 48: step = -1
            case ([.command, .shift], "]"), ([.command, .shift], "}"): step = 1
            case ([.command, .shift], "["), ([.command, .shift], "{"): step = -1
            default: step = 0
            }
            if step != 0 { activate(tabs[(index + step + tabs.count) % tabs.count]); return true }
        }
        if let page = selected.current, page.handleKeyEquivalent(key, modifiers: modifiers, event: event) {
            return true
        }
        if modifiers == .command {
            switch key {
            case "t": addTab(); return true
            case "w": closeTab(number: selected.number); return true
            case "[" where selected.page != nil: goBack(); return true
            case "]" where selected.forwardPage != nil || selected.current?.handlesForward == true:
                goForward(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func goBack() {
        if let page = selected.current, page.canGoBackWithin {
            page.goBackWithin()
            return
        }
        selected.forwardPage = selected.page
        if let page = selected.current, page.isFinished {
            // An exited shell has nothing to resume; the next visit starts a new one.
            selected.pages[page.kind] = nil
            if presented === page { presented = nil }
            page.dispose()
            selected.forwardPage = nil
        }
        selected.page = nil
        activate(selected)
    }

    private func goForward() {
        if let page = selected.current, page.handlesForward {
            page.goForwardWithin()
            return
        }
        guard selected.page == nil, let target = selected.forwardPage else { return }
        openPage(target)
    }

    func containsNote(_ id: UUID) -> Bool { tabs.contains { $0.notes?.noteID == id } }

    func revealNote(_ id: UUID) {
        guard canManageTabs, let tab = tabs.first(where: { $0.notes?.noteID == id }) else { return }
        showNotes(in: tab)
    }

    func revealUnsavedNote() {
        guard canManageTabs,
              let document = NotesWorkspace.shared.list().first(where: { $0.isDirty && $0.errorMessage != nil }) else { return }
        if let existing = tabs.first(where: { $0.notes?.noteID == document.id }) {
            showNotes(in: existing)
        } else {
            addTab()
            openPage(.notes)
            if let page = selected.notes { openNote(document, from: page) }
        }
    }

    /// Bring a tab's notes page to the front with its editor focused.
    fileprivate func showNotes(in tab: Tab) {
        tab.notes?.session.showingList = false
        tab.page = .notes
        activate(tab)
        tab.notes?.reveal()
    }

    private func openPage(_ kind: PageKind) {
        guard canManageTabs else { return }
        let tab = selected
        let existing = tab.pages[kind]
        let page = existing ?? pages.make(kind, host: self, frame: chrome.bounds)
        tab.pages[kind] = page
        tab.page = kind
        activate(tab)
        if existing == nil { page.didOpen() }
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
        settingsPanel.onDismiss = { [weak self] in
            guard let self, !isDisposed else { return }
            revealingToolbar = false
            applyTransparency()
        }
        if !settingsPanel.isVisible { showSettings(from: chrome.windowButton) }
    }

    /// The slider button opens the two opacity sliders directly, with no menu in between.
    private func showSettings(from sender: NSView) {
        guard !isDisposed, currentState?.isLocked != true else { return }
        if settingsPanel.isVisible {
            settingsPanel.performClose(nil)
            return
        }
        chrome.dismissTooltip()
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
        settingsPanel.show(below: sender)
    }

}

extension MiniPanel: PageHost {
    var hostWindow: NSPanel { self }
    var isGeometryInteracting: Bool { geometryInteraction != nil }

    func isPresenting(_ page: TabPage) -> Bool { !isDisposed && presented === page }

    func pageTitleChanged(_ page: TabPage) {
        guard !isDisposed else { return }
        refreshTabs()
    }

    func pageFinished(_ page: TabPage) {
        guard !isDisposed, let tab = tabs.first(where: { $0.pages[page.kind] === page }) else { return }
        tab.pages[page.kind] = nil
        if tab.forwardPage == page.kind { tab.forwardPage = nil }
        if tab.page == page.kind {
            tab.page = nil
            if selected === tab {
                presented = nil
                makeFirstResponder(nil)
                showHome()
            }
        }
        if selected === tab { updateToolbar() }
        refreshTabs()
    }

    func openNote(_ document: NoteDocument, from page: NotesPage) {
        if actions.focusNoteElsewhere(document.id) { return }
        if let existing = tabs.first(where: { $0.notes !== page && $0.notes?.noteID == document.id }) {
            showNotes(in: existing)
        } else {
            page.show(document)
            refreshTabs()
        }
    }

    func noteIsOpenElsewhere(_ id: UUID) -> Bool {
        tabs.contains { $0.notes?.noteID == id } || actions.noteIsOpenElsewhere(id)
    }
}
