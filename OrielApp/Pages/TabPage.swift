import AppKit
import SwiftUI

/// How the window chrome frames a page.
enum PageSurface {
    /// Edge to edge on a clear background (notes, novels, stocks, browser).
    case reading
    /// Inset on the terminal's black background.
    case terminal
}

/// What a mini window offers the pages inside its tabs.
@MainActor
protocol PageHost: AnyObject {
    /// The mini window, for sheets, panels and first-responder changes.
    var hostWindow: NSPanel { get }
    /// Visible, unlocked and not closing.
    var canManageTabs: Bool { get }
    /// The window is being dragged or resized.
    var isGeometryInteracting: Bool { get }
    /// The page is the one on screen in the selected tab.
    func isPresenting(_ page: TabPage) -> Bool
    /// A page's tab title changed.
    func pageTitleChanged(_ page: TabPage)
    /// The page ended by itself (a shell exited): drop it and return its tab home.
    func pageFinished(_ page: TabPage)
    /// A notes page asks to show `document`: focus it where it is already open, else here.
    func openNote(_ document: NoteDocument, from page: NotesPage)
    /// Another tab, in this or another window, already edits the note.
    func noteIsOpenElsewhere(_ id: UUID) -> Bool
}

/// One kind of content in a window tab. A tab keeps each page it opened, so returning to
/// the home page and back resumes the same session. Adding a kind means a case in
/// `PageKind`, one `TabPage` class, and one line in `PageFactory`.
@MainActor
protocol TabPage: AnyObject {
    var kind: PageKind { get }
    var view: NSView { get }
    var title: String { get }
    var surface: PageSurface { get }

    /// Runs once, after the page is first shown (start a shell, load the start page).
    func didOpen()
    /// The page is now on screen: take keyboard focus where it makes sense.
    func didActivate()
    /// The page is leaving the screen: commit typing, close popovers, pause media.
    func willDeactivate()
    /// The window was shown or hidden while this page is on screen.
    func windowVisibilityChanged(_ visible: Bool)
    /// The window is hiding or locking with this page on screen.
    func windowWillConceal()
    /// Write any text still in an editor to the model.
    func commitEditing()
    /// Close hover popovers (the window starts moving or resizing).
    func dismissPopovers()

    /// The user is typing here; automatic hiding and folding keep the window open.
    func hasEditingFocus(_ responder: NSResponder) -> Bool
    /// A file panel, export or menu belonging to the page is open.
    var keepsWindowVisible: Bool { get }
    /// ⌘-shortcuts for this page. Return true when handled.
    func handleKeyEquivalent(_ key: String?, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> Bool

    /// ⌘[ navigates inside the page (browser history) instead of returning home.
    var canGoBackWithin: Bool { get }
    func goBackWithin()
    /// ⌘] navigates inside the page.
    var handlesForward: Bool { get }
    func goForwardWithin()

    /// Nothing left to resume (the shell exited); returning home discards the page.
    var isFinished: Bool { get }
    func dispose()
}

extension TabPage {
    var surface: PageSurface { .reading }
    func didOpen() {}
    func didActivate() {}
    func willDeactivate() {}
    func windowVisibilityChanged(_ visible: Bool) {}
    func windowWillConceal() {}
    func commitEditing() {}
    func dismissPopovers() {}
    func hasEditingFocus(_ responder: NSResponder) -> Bool { false }
    var keepsWindowVisible: Bool { false }
    func handleKeyEquivalent(_ key: String?, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> Bool { false }
    var canGoBackWithin: Bool { false }
    func goBackWithin() {}
    var handlesForward: Bool { false }
    func goForwardWithin() {}
    var isFinished: Bool { false }
}

/// A SwiftUI page hosted without letting its ideal size resize the window.
@MainActor
func pageHostingView<Content: View>(_ root: Content) -> NSHostingView<Content> {
    let view = NSHostingView(rootView: root)
    view.sizingOptions = []
    return view
}
