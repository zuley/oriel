import AppKit

/// A note editor with its list, search and trash. Each tab edits a different note;
/// choosing a note open elsewhere focuses that tab or window instead.
@MainActor
final class NotesPage: TabPage {
    let kind = PageKind.notes
    let view: NSView
    let session: NotesSession
    private weak var host: PageHost?
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

    /// Show `document` in this tab.
    func show(_ document: NoteDocument) { session.select(document) }

    /// Bring the editor back from the list and focus it.
    func reveal() {
        session.showingList = false
        if let editor = session.document.editorView?.documentView { host?.hostWindow.makeFirstResponder(editor) }
    }

    func willDeactivate() { commitEditing() }
    func commitEditing() { session.document.commitEditing?() }

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
