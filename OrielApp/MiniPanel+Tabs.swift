import AppKit
import Combine

/// Window-side tab presentation: focus, close protection and page lifecycle.
/// Ordering, selection and shortcut destinations belong to WindowTabs.
extension MiniPanel {
    private var tabs: [WindowTab] { windowTabs.tabs }

    func confirmCanClose() -> Bool {
        NotesWorkspace.shared.confirmCanClose(documentIDs: Set(tabs.compactMap { $0.notes?.noteID }))
    }

    func refreshTabs() {
        guard !isDisposed else { return }
        if !tabs.contains(where: { $0.notes != nil }) { noteChanges = nil }
        chrome.setTabs(tabs.map { ChromeTab(number: $0.number, title: $0.title, kind: $0.page) },
                       selected: selected.number)
    }

    /// Every return to the launcher shows the page tiles.
    func showHome() {
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

    var canManageTabs: Bool {
        !isDisposed && isVisible && currentState?.isLocked == false
    }

    func addTab() {
        guard canManageTabs else { return }
        activate(windowTabs.add())
    }

    func selectTab(number: Int) {
        guard canManageTabs, let tab = windowTabs.tab(number: number) else { return }
        activate(tab)
    }

    /// Processes and text this window owns, read by the workspace resource sampler.
    var resourceSources: WindowResourceSources {
        var sources = WindowResourceSources()
        var books = Set<String>()
        for tab in tabs {
            for page in tab.pages.values {
                if let terminal = page as? TerminalPage, terminal.shellPID > 0 {
                    sources.terminalPIDs.append(terminal.shellPID)
                } else if let browser = page as? BrowserPage, let pid = browser.webProcessID {
                    sources.webPIDs.append(pid)
                } else if let novel = page as? NovelPage, let bookID = novel.bookID,
                          books.insert(bookID).inserted {
                    sources.textBytes += novel.retainedTextBytes
                }
            }
        }
        return sources
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

    func closeTab(number: Int) {
        guard canManageTabs, let tab = windowTabs.tab(number: number) else { return }
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
        guard canManageTabs, let tab = windowTabs.tab(number: number) else { return }
        let noteIDs = Set([tab.notes?.noteID].compactMap { $0 })
        guard NotesWorkspace.shared.confirmCanClose(documentIDs: noteIDs),
              let removal = windowTabs.remove(number: number) else { return }
        switch removal.next {
        case .background:
            removal.removed.dispose()
            refreshTabs()
        case .selectNext(let next), .replacedWithHome(let next):
            makeFirstResponder(nil)
            presented = nil
            removal.removed.dispose()
            activate(next)
        }
    }

    private func activate(_ tab: WindowTab) {
        let page = tab.current
        presented?.commitEditing()
        if let presented, presented !== page { presented.willDeactivate() }
        try? NotesWorkspace.shared.saveAll()
        makeFirstResponder(nil)
        windowTabs.select(tab)
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

    func handleTabKeyEquivalent(_ event: NSEvent) -> Bool {
        guard canManageTabs, isKeyWindow, attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if tabs.count > 1 {
            if modifiers == .command, let key, let digit = Int(key),
               let target = windowTabs.tab(forShortcutDigit: digit) {
                activate(target)
                return true
            }
            let step: Int
            switch (modifiers, key) {
            case (.control, _) where event.keyCode == 48: step = 1
            case ([.control, .shift], _) where event.keyCode == 48: step = -1
            case ([.command, .shift], "]"), ([.command, .shift], "}"): step = 1
            case ([.command, .shift], "["), ([.command, .shift], "{"): step = -1
            default: step = 0
            }
            if step != 0, let target = windowTabs.neighbor(step: step) {
                activate(target)
                return true
            }
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
        return false
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
    func showNotes(in tab: WindowTab) {
        tab.notes?.session.showingList = false
        tab.page = .notes
        activate(tab)
        tab.notes?.reveal()
    }

    func openPage(_ kind: PageKind) {
        guard canManageTabs else { return }
        let tab = selected
        let existing = tab.pages[kind]
        let page = existing ?? pages.make(kind, host: self, frame: chrome.bounds)
        tab.pages[kind] = page
        tab.page = kind
        activate(tab)
        if existing == nil { page.didOpen() }
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

private extension WindowTab {
    var notes: NotesPage? { pages[.notes] as? NotesPage }
    var terminal: TerminalPage? { pages[.terminal] as? TerminalPage }
}
