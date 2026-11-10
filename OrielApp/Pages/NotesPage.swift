import AppKit

/// A note editor with its list, search and trash. Each tab edits a different note;
/// choosing a note open elsewhere focuses that tab or window instead.
@MainActor
final class NotesPage: TabPage {
    let kind = PageKind.notes
    let view: NSView
    let session: NotesSession
    private weak var host: PageHost?
    // Remember the control, not AppKit's field editor, which other tabs can reuse.
    private weak var findInputToRestore: NSTextField?
    private var findInputSelection: NSRange?
    var title: String { session.document.title }
    var noteID: UUID { session.document.id }

    /// Opens the most recent note unless another tab already edits it; then a blank draft.
    init(host: PageHost, workspace: NotesWorkspace) {
        self.host = host
        let recent = workspace.list().max(by: { $0.record.updated < $1.record.updated })
        let initial = recent.flatMap { host.noteIsOpenElsewhere($0.id) ? nil : $0 }
        let session = NotesSession(workspace: workspace, document: initial ?? workspace.create())
        self.session = session
        weak var page: NotesPage?
        view = pageHostingView(NotesView(session: session, workspace: workspace,
            open: { [weak host] document in
                guard let host, let page, host.canManageTabs, host.isPresenting(page) else { return }
                host.openNote(document, from: page)
            }, export: { [weak host] in
                guard let host, let page, host.canManageTabs else { return }
                page.session.export(in: host.hostWindow)
            }))
        page = self
    }

    func didActivate() {
        guard let host, host.canManageTabs, host.isPresenting(self),
              host.hostWindow.attachedSheet == nil else { return }
        if session.showingList {
            session.focusSearch?()
        } else if let scroll = session.document.editorView, let editor = scroll.documentView,
                  editor.window === host.hostWindow, !editor.isHiddenOrHasHiddenAncestor {
            if scroll.isFindBarVisible, let bar = scroll.findBarView,
               let field = findInputToRestore, field.isDescendant(of: bar),
               field.window === host.hostWindow, !field.isHiddenOrHasHiddenAncestor,
               host.hostWindow.makeFirstResponder(field) {
                if let selection = findInputSelection, let input = field.currentEditor() as? NSTextView {
                    let length = (input.string as NSString).length
                    let start = min(selection.location, length)
                    input.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
                }
                return
            }
            // Cached editors do not move to a window again when returning from home.
            host.hostWindow.makeFirstResponder(editor)
        }
    }

    /// Show `document` in this tab.
    func show(_ document: NoteDocument) { session.select(document) }

    /// Bring the editor back from the list and focus it.
    func reveal() {
        session.showingList = false
        if let editor = session.document.editorView?.documentView { host?.hostWindow.makeFirstResponder(editor) }
    }

    func willDeactivate() { commitEditing() }
    func commitEditing() {
        // MiniPanel commits before clearing focus, including when reselecting this tab.
        findInputToRestore = nil
        findInputSelection = nil
        if let scroll = session.document.editorView, scroll.isFindBarVisible,
           let bar = scroll.findBarView,
           let input = host?.hostWindow.firstResponder as? NSTextView, input.isFieldEditor {
            func focusedField(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.currentEditor() === input { return field }
                return view.subviews.lazy.compactMap { focusedField(in: $0) }.first
            }
            findInputToRestore = focusedField(in: bar)
            if findInputToRestore != nil { findInputSelection = input.selectedRange() }
        }
        session.document.commitEditing?()
    }

    func windowWillConceal() {
        commitEditing()
        if session.choosingNote { session.showingList = false }
    }

    func hasEditingFocus(_ responder: NSResponder) -> Bool { (responder as? NSTextView)?.isEditable == true }
    var keepsWindowVisible: Bool { session.exporting || session.choosingNote }

    func handleKeyEquivalent(_ key: String?, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> Bool {
        switch (modifiers, key) {
        case ([.command, .option], "f"): session.showList(); return true
        case ([.command, .shift], "g"): session.findNext(backwards: true); return true
        case (.command, "n"):
            host?.openNote(session.workspace.create(), from: self); return true
        case (.command, "f"): session.find(); return true
        case (.command, "g"): session.findNext(backwards: false); return true
        case (.command, "s"): try? session.workspace.saveAll(); return true
        default: return false
        }
    }

    func dispose() {
        session.dispose()
        view.removeFromSuperview()
    }
}
