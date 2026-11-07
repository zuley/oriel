import AppKit
import SwiftUI
import Combine
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
        var renameWindow: () -> Void = {}
        var noteIsOpenElsewhere: (UUID) -> Bool = { _ in false }
        var focusNoteElsewhere: (UUID) -> Bool = { _ in false }
        var transparencyRecoveryChanged: (Bool) -> Void = { _ in }
    }

    private enum GeometryInteraction: Equatable {
        case dragging
        case resizing
    }

    private let actions: Actions
    private var chrome: MiniWindowChromeView!
    private let novelLibrary: NovelLibrary
    private let watchlist: StockWatchlist
    private let watchlistOwner = UUID().uuidString
    private let stockChart = StockChartHover()
    private var currentState: WindowSnapshot?
    private enum Page { case home, web, terminal, stocks, novel, notes }
    @MainActor
    private final class Tab {
        let number: Int
        var page = Page.home
        var forwardPage: Page?
        var terminal: ShellTerminalView?
        var web: WebContent?
        var notes: NotesSession?
        var notesView: NSHostingView<NotesView>?
        var novel: NovelSession?
        var novelView: NSHostingView<NovelView>?
        var stocksView: NSHostingView<StocksView>?

        init(number: Int) { self.number = number }

        var title: String {
            switch page {
            case .home: return "首页 \(number)"
            case .terminal: return "终端 \(number)"
            case .notes: return notes?.document.title ?? "便签"
            case .novel: return novel?.book.map { "\($0.title) · \(number)" } ?? "小说 \(number)"
            case .stocks: return "自选股 \(number)"
            case .web: return "网页 \(number)"
            }
        }

        func dispose() {
            notes?.dispose()
            notesView?.removeFromSuperview()
            notesView = nil
            notes = nil
            novel?.dispose()
            novelView?.removeFromSuperview()
            novelView = nil
            novel = nil
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
    private var noteChanges: AnyCancellable?
    private var noteRefreshPending = false
    private var geometryInteraction: GeometryInteraction?
    private var resizeStart: (frame: NSRect, pointer: NSPoint)?
    private var dragCompletionTimer: Timer?
    fileprivate weak var hoveredResizeHandle: PanelResizeHandle?
    private var lockRecoveryPanel: LockRecoveryPanel?
    private let settingsPanel = TransparencySettingsPanel()
    private var backgroundOpacity: Double = 0.75
    private var emphasis: WindowGroupController.Emphasis = .normal
    private var contentOpacity: Double = 0.75
    private var revealingToolbar = false
    private var trackingMenus = Set<ObjectIdentifier>()
    private var isDisposed = false

    var bodyFrame: NSRect { convertToScreen(chrome.convert(chrome.bounds, to: nil)) }

    var hasEditingFocus: Bool {
        guard isKeyWindow, let responder = firstResponder else { return false }
        switch selected.page {
        case .terminal: return responder === selected.terminal
        case .stocks: return responder is NSTextInputClient
        case .novel, .notes: return (responder as? NSTextView)?.isEditable == true
        default: return false
        }
    }

    var keepsWindowVisible: Bool {
        attachedSheet != nil || settingsPanel.isVisible || stockChart.containsPointer || selected.novel?.choosingFile == true || selected.notes?.exporting == true || selected.notes?.choosingNote == true || !trackingMenus.isEmpty
    }

    init(frame: CGRect, library: NovelLibrary, watchlist: StockWatchlist, preferences: AppPreferences, actions: Actions) {
        self.actions = actions
        self.novelLibrary = library
        self.watchlist = watchlist
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
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .aqua)
        animationBehavior = .none
        hasShadow = false

        chrome = MiniWindowChromeView(actions: .init(
            addTab: { [weak self] in self?.addTab() },
            selectTab: { [weak self] in self?.selectTab(number: $0) },
            closeTab: { [weak self] in self?.closeTab(number: $0) },
            openTerminal: { [weak self] in self?.showTerminal() },
            openNovel: { [weak self] in self?.showNovel() },
            dropNovel: { [weak self] urls in
                guard let self, canManageTabs else { return false }
                showNovel()
                selected.novel?.start()
                selected.novel?.openFiles(urls)
                return true
            },
            openStocks: { [weak self] in self?.showStocks() },
            openNotes: { [weak self] in self?.showNotes() },
            renameWindow: actions.renameWindow,
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
        shadowView.chrome = chrome
        shadowView.addSubview(chrome)
        shadowView.installResizeHandles()
        applyTransparency()
        refreshTabs()
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
        NotesWorkspace.shared.confirmCanClose(documentIDs: Set(tabs.compactMap { $0.notes?.document.id }))
    }

    func cancelGeometryInteraction() {
        finishGeometryInteraction(reportFinalFrame: false, notify: false)
    }

    func apply(_ state: WindowSnapshot) {
        guard !isDisposed else { return }
        currentState = state
        watchlist.setVisible(state.isVisible && selected.page == .stocks, owner: watchlistOwner)
        if !state.isVisible { chrome?.dismissTooltip() }
        if state.isLocked || !state.isVisible {
            if let sheet = attachedSheet { endSheet(sheet, returnCode: .cancel) }
            hoveredResizeHandle?.releaseCursor()
            stockChart.dismiss()
            if hasEditingFocus {
                selected.notes?.document.commitEditing?()
                try? NotesWorkspace.shared.saveAll()
                makeFirstResponder(nil)
            }
            settingsPanel.performClose(nil)
            if selected.notes?.choosingNote == true { selected.notes?.showingList = false }
            // The corresponding controller command already ends the interaction.
            // Applying a snapshot must not synchronously emit a new state transition.
            finishGeometryInteraction(reportFinalFrame: false, notify: false)
        }
        if state.isLocked && isKeyWindow { resignKey() }
        ignoresMouseEvents = state.isLocked
        alphaValue = state.opacity * (emphasis == .dimmed ? 0.22 : 1)
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
        noteChanges = nil
        if let sheet = attachedSheet { endSheet(sheet, returnCode: .cancel) }
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        trackingMenus.removeAll()
        hoveredResizeHandle?.releaseCursor()
        stockChart.dismiss()
        watchlist.setVisible(false, owner: watchlistOwner)
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

    fileprivate func startEdgeResize(_ event: NSEvent) {
        guard !isDisposed, isVisible, !ignoresMouseEvents, geometryInteraction == nil else { return }
        resizeStart = (frame, convertPoint(toScreen: event.locationInWindow))
        beginGeometryInteraction(.resizing)
    }

    fileprivate func dragEdge(_ edge: PanelResizeEdge, event: NSEvent) {
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

    fileprivate func endEdgeResize() {
        if resizeStart != nil { finishGeometryInteraction() }
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
        resizeStart = nil
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

    private func refreshTabs() {
        guard !isDisposed else { return }
        if !tabs.contains(where: { $0.notes != nil }) { noteChanges = nil }
        chrome.setTabs(tabs.map { ($0.number, $0.title) }, selected: selected.number)
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
            setFrame(NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                            y: min(max(frame.maxY - height, visible.minY), visible.maxY - height),
                            width: width, height: height), display: true)
            actions.frameChanged(bodyFrame)
        }
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
        let noteIDs = Set([tabs[index].notes?.document.id].compactMap { $0 })
        guard NotesWorkspace.shared.confirmCanClose(documentIDs: noteIDs) else { return }
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
        selected.notes?.document.commitEditing?()
        try? NotesWorkspace.shared.saveAll()
        stockChart.dismiss()
        makeFirstResponder(nil)
        selected = tab
        watchlist.setVisible(tab.page == .stocks && currentState?.isVisible == true, owner: watchlistOwner)
        switch tab.page {
        case .notes:
            if tab.notesView == nil {
                let workspace = NotesWorkspace.shared
                let recent = workspace.list().max(by: { $0.record.updated < $1.record.updated })
                let initial = recent.flatMap { note in (tabs.contains(where: { $0.notes?.document.id == note.id }) || actions.noteIsOpenElsewhere(note.id)) ? nil : note }
                let session = NotesSession(workspace: workspace, document: initial ?? workspace.create())
                let root = NotesView(session: session, workspace: session.workspace,
                    open: { [weak self, weak tab] document in
                        guard let self, let tab, self.canManageTabs, self.selected === tab else { return }
                        self.openNote(document, in: tab)
                    }, export: { [weak self, weak session] in
                        guard let self, self.canManageTabs else { return }
                        session?.export(in: self)
                    })
                let view = NSHostingView(rootView: root)
                view.sizingOptions = []
                tab.notes = session
                tab.notesView = view
                observeNoteTitles()
            }
            if let view = tab.notesView {
                chrome.showReadingSurface(view)
                makeKeyAndOrderFront(nil)
            }
        case .novel:
            if tab.novelView == nil {
                let library = novelLibrary
                let session = NovelSession(library: library)
                session.onBookChanged = { [weak self] in self?.refreshTabs() }
                let root = NovelView(session: session, library: library, chooseFile: { [weak self, weak session] in
                    guard let self, self.canManageTabs, self.selected.page == .novel, self.selected.novel === session else { return }
                    session?.importFile(in: self)
                })
                let view = NSHostingView(rootView: root)
                view.sizingOptions = []
                tab.novel = session
                tab.novelView = view
            }
            if let view = tab.novelView {
                chrome.showReadingSurface(view)
                makeKeyAndOrderFront(nil)
            }
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
                chrome.showReadingSurface(view)
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
        if modifiers == .command {
            switch key {
            case "n" where selected.page == .notes:
                openNote(NotesWorkspace.shared.create(), in: selected); return true
            case "f" where selected.page == .notes:
                selected.notes?.showList(); return true
            case "s" where selected.page == .notes:
                try? NotesWorkspace.shared.saveAll(); return true
            case "o" where selected.page == .novel:
                selected.novel?.importFile(in: self); return true
            case "f" where selected.page == .novel && selected.novel?.section == .reading:
                selected.novel?.section = .search; return true
            case "d" where selected.page == .novel && selected.novel?.section == .reading:
                selected.novel?.markHere(); return true
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
        case (.home, .novel): showNovel()
        case (.home, .notes): showNotes()
        case (.home, .stocks): showStocks()
        case (.home, .web): showFixture()
        case (.web, _): selected.web?.webView.goForward()
        default: break
        }
    }

    func containsNote(_ id: UUID) -> Bool { tabs.contains { $0.notes?.document.id == id } }

    func revealNote(_ id: UUID) {
        guard canManageTabs, let tab = tabs.first(where: { $0.notes?.document.id == id }) else { return }
        tab.page = .notes
        tab.notes?.showingList = false
        activate(tab)
        if let editor = tab.notes?.document.editorView?.documentView { makeFirstResponder(editor) }
    }

    func revealUnsavedNote() {
        guard canManageTabs,
              let document = NotesWorkspace.shared.list().first(where: { $0.isDirty && $0.errorMessage != nil }) else { return }
        if let existing = tabs.first(where: { $0.notes?.document.id == document.id }) {
            existing.page = .notes
            existing.notes?.showingList = false
            activate(existing)
        } else {
            addTab()
            selected.page = .notes
            activate(selected)
            openNote(document, in: selected)
        }
    }

    private func showNotes() {
        guard canManageTabs else { return }
        selected.page = .notes
        activate(selected)
    }

    private func openNote(_ document: NoteDocument, in tab: Tab) {
        if actions.focusNoteElsewhere(document.id) { return }
        if let existing = tabs.first(where: { $0 !== tab && $0.notes?.document.id == document.id }) {
            existing.page = .notes
            existing.notes?.showingList = false
            activate(existing)
        } else {
            tab.notes?.select(document)
            refreshTabs()
        }
    }

    private func showNovel() {
        guard canManageTabs else { return }
        selected.page = .novel
        activate(selected)
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
        if !settingsPanel.isVisible { showSettings(from: chrome.settingsButton) }
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
            self.actions.transparencyRecoveryChanged(max(background, content) <= 0.05)
        }
        settingsPanel.show(below: sender)
    }

}

private struct PanelResizeEdge: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let top = Self(rawValue: 4)
    static let bottom = Self(rawValue: 8)

    @MainActor var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            case .bottom: position = .bottom
            case [.left, .top]: position = .topLeft
            case [.right, .top]: position = .topRight
            case [.left, .bottom]: position = .bottomLeft
            default: position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        if isDisjoint(with: [.left, .right]) { return .resizeUpDown }
        if isDisjoint(with: [.top, .bottom]) { return .resizeLeftRight }
        let rising = self == [.bottom, .left] || self == [.top, .right]
        let source = NSCursor.resizeLeftRight.image
        let size = NSSize(width: 32, height: 32)
        let center = NSPoint(x: 16, y: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: rising ? 45 : -45)
            transform.concat()
            source.draw(in: NSRect(x: -source.size.width / 2, y: -source.size.height / 2,
                                   width: source.size.width, height: source.size.height))
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }
}

/// WindowServer otherwise ignores cursor changes from an inactive menu-bar app.
/// Resolve this optional connection property at runtime so normal AppKit cursor rects
/// still work on systems without it. Enable it only during a resize hover.
private enum BackgroundResizeCursor {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    static func allow(_ enabled: Bool) {
        let symbols = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connectionFunction = dlsym(symbols, "CGSMainConnectionID"),
              let propertyFunction = dlsym(symbols, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(connectionFunction, to: MainConnection.self)()
        let setProperty = unsafeBitCast(propertyFunction, to: SetProperty.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString,
                        enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

@MainActor
private final class PanelResizeHandle: NSView {
    let edge: PanelResizeEdge
    private let resizeCursor: NSCursor

    init(_ edge: PanelResizeEdge) {
        self.edge = edge
        resizeCursor = edge.cursor
        super.init(frame: .zero)
        setAccessibilityElement(false)
        // Cursor rects are only active in a key window. This panel usually isn't key.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect,
            .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self, userInfo: nil))
    }

    private func showCursor() {
        guard let panel = window as? MiniPanel, panel.isVisible, !panel.ignoresMouseEvents else { return }
        let point = superview?.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        if let point, (superview as? PanelShadowView)?.hasControl(at: point) == true {
            releaseCursor()
            return
        }
        if panel.hoveredResizeHandle == nil { BackgroundResizeCursor.allow(true) }
        panel.hoveredResizeHandle = self
        resizeCursor.set()
    }

    func releaseCursor() {
        guard let panel = window as? MiniPanel, panel.hoveredResizeHandle === self else { return }
        panel.hoveredResizeHandle = nil
        NSCursor.arrow.set()
        BackgroundResizeCursor.allow(false)
    }

    override func mouseEntered(with event: NSEvent) { showCursor() }
    override func mouseMoved(with event: NSEvent) { showCursor() }
    override func mouseExited(with event: NSEvent) { releaseCursor() }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .scrollWheel, .rightMouseDown, .rightMouseUp: return nil
        default:
            guard let hit = super.hitTest(point),
                  (superview as? PanelShadowView)?.hasControl(at: point) != true else { return nil }
            return hit
        }
    }
    override func cursorUpdate(with event: NSEvent) { showCursor() }
    override func mouseDown(with event: NSEvent) { (window as? MiniPanel)?.startEdgeResize(event) }
    override func mouseDragged(with event: NSEvent) { (window as? MiniPanel)?.dragEdge(edge, event: event) }
    override func mouseUp(with event: NSEvent) { (window as? MiniPanel)?.endEdgeResize() }
}

@MainActor
private final class PanelShadowView: NSView {
    weak var chrome: MiniWindowChromeView?
    var highlighted = false { didSet { needsDisplay = true } }

    func hasControl(at point: NSPoint) -> Bool {
        var view = chrome?.hitTest(point)
        while let candidate = view {
            if candidate is NSButton || candidate is NSScroller { return true }
            view = candidate.superview
        }
        return false
    }

    var bodyRect: NSRect { bounds.insetBy(dx: 4, dy: 4) }
    var shadowStrength: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    private var handles: [PanelResizeHandle] = []

    func installResizeHandles() {
        let edges: [PanelResizeEdge] = [.left, .right, .top, .bottom,
                                        [.top, .left], [.top, .right], [.bottom, .left], [.bottom, .right]]
        handles = edges.map(PanelResizeHandle.init)
        handles.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let corner: CGFloat = 20
        let band: CGFloat = 14
        let topBand: CGFloat = 12
        let toolbarBottom = bodyRect.maxY - 28
        for handle in handles {
            let edge = handle.edge
            let left = edge.contains(.left), right = edge.contains(.right)
            let top = edge.contains(.top), bottom = edge.contains(.bottom)
            let isCorner = (left || right) && (top || bottom)
            let width = isCorner ? corner : (left || right ? band : bounds.width - 2 * corner)
            let x = left ? bounds.minX : (right ? bounds.maxX - width : bounds.minX + corner)
            let y: CGFloat
            let height: CGFloat
            if top {
                height = topBand
                y = bounds.maxY - height
            } else if bottom {
                height = isCorner ? corner : band
                y = bounds.minY
            } else {
                // Keep the sides of the toolbar free for the traffic lights and lock.
                y = bounds.minY + corner
                height = toolbarBottom - y
            }
            handle.frame = NSRect(x: x, y: y, width: width, height: height)
        }
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
        if highlighted {
            let ring = NSBezierPath(roundedRect: bodyRect.insetBy(dx: -1, dy: -1), xRadius: 9, yRadius: 9)
            ring.lineWidth = 2
            NSColor(srgbRed: 0.19, green: 0.55, blue: 0.45, alpha: 1).setStroke()
            ring.stroke()
        }
    }
}

@MainActor
private final class LockRecoveryPanel: NSPanel {
    let button: ChromeButton

    init(unlock: @escaping () -> Void) {
        button = MiniWindowChromeView.makeLockRecoveryControl(unlock: unlock)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 28, height: 28),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "取消穿透"
        animationBehavior = .none
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
        contentView = button
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


/// A small anchored panel gives the compact settings a controlled corner radius.
@MainActor
private final class TransparencySettingsPanel: NSPanel {
    var onDismiss: (() -> Void)?
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
        onDismiss?()
        onDismiss = nil
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
