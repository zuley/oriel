import AppKit

/// The local bookshelf and reader.
@MainActor
final class NovelPage: TabPage {
    let kind = PageKind.novel
    let view: NSView
    let session: NovelSession
    private weak var host: PageHost?
    var title: String { session.book?.title ?? "小说" }

    init(host: PageHost, library: NovelLibrary) {
        self.host = host
        let session = NovelSession(library: library)
        self.session = session
        weak var page: NovelPage?
        view = pageHostingView(NovelView(session: session, library: library, chooseFile: { [weak host] book in
            guard let host, let page, host.canManageTabs, host.isPresenting(page) else { return }
            page.session.importFile(in: host.hostWindow, replacing: book)
        }))
        page = self
        session.onBookChanged = { [weak self, weak host] in
            guard let self else { return }
            host?.pageTitleChanged(self)
        }
    }

    /// Books dropped on the home page's novel tile.
    func openFiles(_ urls: [URL]) {
        session.start()
        session.openFiles(urls)
    }

    func hasEditingFocus(_ responder: NSResponder) -> Bool { (responder as? NSTextView)?.isEditable == true }
    var keepsWindowVisible: Bool { session.choosingFile }

    func handleKeyEquivalent(_ key: String?, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> Bool {
        guard modifiers == .command, let host else { return false }
        switch key {
        case "o": session.importFile(in: host.hostWindow); return true
        case "f" where session.section == .reading: session.section = .search; return true
        case "d" where session.section == .reading: session.markHere(); return true
        default: return false
        }
    }

    func dispose() {
        session.dispose()
        view.removeFromSuperview()
    }
}
