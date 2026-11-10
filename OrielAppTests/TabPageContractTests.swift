import AppKit
import XCTest

/// R10: pages talk to their window only through `PageHost`.
@MainActor
final class TabPageContractTests: XCTestCase {
    private final class FakeHost: PageHost {
        let hostWindow = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 280, height: 320),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        var canManageTabs = true
        var isGeometryInteracting = false
        var presenting: TabPage?
        var openElsewhere: Set<UUID> = []
        var titleChanges = 0
        var finished: [TabPage] = []
        var opened: [UUID] = []
        func isPresenting(_ page: TabPage) -> Bool { presenting === page }
        func pageTitleChanged(_ page: TabPage) { titleChanges += 1 }
        func pageFinished(_ page: TabPage) { finished.append(page) }
        func openNote(_ document: NoteDocument, from page: NotesPage) { opened.append(document.id) }
        func noteIsOpenElsewhere(_ id: UUID) -> Bool { openElsewhere.contains(id) }
    }

    private func workspace() -> NotesWorkspace {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return NotesWorkspace(root: root, automaticSaving: false)
    }

    func testNotesPageOpensTheLatestNoteUnlessAnotherTabEditsIt() throws {
        let notes = workspace()
        let older = notes.create(); older.edit("较早")
        let latest = notes.create(); latest.edit("最新")
        try notes.saveAll()
        let host = FakeHost()

        let first = NotesPage(host: host, workspace: notes)
        XCTAssertEqual(first.kind, .notes)
        XCTAssertEqual(first.noteID, latest.id)
        XCTAssertEqual(first.title, "最新")

        host.openElsewhere = [latest.id]
        let second = NotesPage(host: host, workspace: notes)
        XCTAssertNotEqual(second.noteID, latest.id, "A note edited in another tab gets a blank draft here.")
        XCTAssertTrue(second.session.document.text.isEmpty)
        first.dispose(); second.dispose()
    }

    func testNotesPageShortcutsAndNewNoteGoThroughTheHost() throws {
        let host = FakeHost()
        let page = NotesPage(host: host, workspace: workspace())
        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0))
            return page.handleKeyEquivalent(characters, modifiers: modifiers, event: event)
        }
        XCTAssertTrue(try key("f", [.command, .option]))
        XCTAssertTrue(page.session.showingList)
        XCTAssertTrue(try key("n", .command))
        XCTAssertEqual(host.opened.count, 1, "⌘N asks the window, which may focus another tab.")
        XCTAssertFalse(try key("t", .command), "Tab shortcuts belong to the window.")
        page.dispose()
    }

    private func hostedNotesPage() async throws -> (NotesPage, FakeHost) {
        let notes = workspace()
        notes.create().edit("abcdef")
        try notes.saveAll()
        let host = FakeHost()
        let page = NotesPage(host: host, workspace: notes)
        host.presenting = page
        host.hostWindow.contentView = page.view
        page.view.layoutSubtreeIfNeeded()
        // Drain the editor's initial viewDidMoveToWindow focus request before switching.
        try await Task.sleep(for: .milliseconds(20))
        addTeardownBlock { @MainActor in
            host.presenting = nil
            host.hostWindow.contentView = nil
            page.dispose()
        }
        return (page, host)
    }

    func testNotesActivationRestoresBodyFocusSelectionAndUndo() async throws {
        let (page, host) = try await hostedNotesPage()
        let editor = try XCTUnwrap(page.session.document.editorView?.documentView as? NSTextView)
        let selection = NSRange(location: 2, length: 2)
        editor.setSelectedRange(selection)
        page.willDeactivate()
        page.view.isHidden = true
        host.hostWindow.makeFirstResponder(nil)
        page.view.isHidden = false

        page.didActivate()

        XCTAssertTrue(host.hostWindow.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertFalse(page.session.showingList)
        (host.hostWindow.firstResponder as? NSTextView)?.insertText("X", replacementRange: selection)
        XCTAssertEqual(page.session.document.text, "abXef", "Typing must reach the restored editor.")
        editor.breakUndoCoalescing()
        editor.undoManager?.undo()
        XCTAssertEqual(page.session.document.text, "abcdef")
    }

    func testNotesActivationKeepsListQueryAndTrashStateAndFocusesSearch() async throws {
        let (page, host) = try await hostedNotesPage()
        page.session.showingList = true
        page.session.showingTrash = true
        page.session.query = "needle"
        page.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        func search(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "搜索便签" { return field }
            return view.subviews.lazy.compactMap { search(in: $0) }.first
        }
        let field = try XCTUnwrap(search(in: page.view))
        host.hostWindow.makeFirstResponder(nil)

        page.didActivate()

        XCTAssertTrue(page.session.showingList, "Activation must not force a list back to the body.")
        XCTAssertTrue(page.session.showingTrash)
        XCTAssertEqual(page.session.query, "needle")
        let fieldEditor = try XCTUnwrap(field.currentEditor())
        XCTAssertTrue(host.hostWindow.firstResponder === fieldEditor)
    }

    private func hostedFindPage() async throws -> (NotesPage, FakeHost, NSScrollView, NSTextField) {
        let (page, host) = try await hostedNotesPage()
        page.session.find()
        page.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(page.session.document.editorView)
        XCTAssertTrue(scroll.isFindBarVisible)
        let bar = try XCTUnwrap(scroll.findBarView)
        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        let field = try XCTUnwrap(fields(in: bar).first { $0.isEditable })
        XCTAssertTrue(host.hostWindow.makeFirstResponder(field))
        let input = try XCTUnwrap(field.currentEditor() as? NSTextView)
        input.selectAll(nil)
        input.insertText("abc", replacementRange: input.selectedRange())
        input.setSelectedRange(NSRange(location: 2, length: 0))
        return (page, host, scroll, field)
    }

    func testFindInputRestoresItsOwnFieldAndCaretEvenAfterFieldEditorReuse() async throws {
        let (page, host, scroll, field) = try await hostedFindPage()
        let document = page.session.document
        let original = document.text
        page.willDeactivate()
        page.view.isHidden = true
        host.hostWindow.makeFirstResponder(nil)
        // AppKit shares one field editor between text fields in a window.
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        page.view.addSubview(other)
        host.hostWindow.makeFirstResponder(other)
        other.currentEditor()?.string = "another tab"
        host.hostWindow.makeFirstResponder(nil)
        other.removeFromSuperview()
        page.view.isHidden = false

        page.didActivate()

        XCTAssertTrue(scroll.isFindBarVisible)
        let input = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(host.hostWindow.firstResponder === input)
        XCTAssertEqual(field.stringValue, "abc")
        XCTAssertEqual(input.selectedRange(), NSRange(location: 2, length: 0))
        (host.hostWindow.firstResponder as? NSTextView)?.insertText("X", replacementRange: input.selectedRange())
        XCTAssertEqual(input.string, "abXc", "Further typing belongs to the find query.")
        XCTAssertEqual(document.text, original, "Find typing must never change the note body.")
    }

    func testFindFocusSurvivesDetachingAndReattachingThePage() async throws {
        let (page, host, _, field) = try await hostedFindPage()
        let original = page.session.document.text
        page.willDeactivate()
        host.hostWindow.makeFirstResponder(nil)
        host.hostWindow.contentView = nil
        host.hostWindow.contentView = page.view
        page.view.layoutSubtreeIfNeeded()

        page.didActivate()
        // Returning from a different content page also schedules the editor's mount callback.
        try await Task.sleep(for: .milliseconds(20))

        let input = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(host.hostWindow.firstResponder === input)
        input.insertText("X", replacementRange: input.selectedRange())
        XCTAssertEqual(page.session.document.text, original)
    }

    func testVisibleFindBarDoesNotOverrideBodyFocusWhenLeavingFromTheBody() async throws {
        let (page, host, _, _) = try await hostedFindPage()
        let editor = try XCTUnwrap(page.session.document.editorView?.documentView as? NSTextView)
        host.hostWindow.makeFirstResponder(editor)
        page.willDeactivate()
        host.hostWindow.makeFirstResponder(nil)

        page.didActivate()

        XCTAssertTrue(host.hostWindow.firstResponder === editor)
    }

    func testClosedFindBarFallsBackToBodyInsteadOfRestoringStaleField() async throws {
        let (page, host, scroll, _) = try await hostedFindPage()
        page.willDeactivate()
        host.hostWindow.makeFirstResponder(nil)
        scroll.isFindBarVisible = false
        page.view.layoutSubtreeIfNeeded()

        page.didActivate()

        XCTAssertTrue(host.hostWindow.firstResponder === scroll.documentView)
    }

    func testInactiveOrLockedNotesActivationDoesNotStealFocus() async throws {
        let (page, host) = try await hostedNotesPage()
        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 30, height: 20))
        page.view.addSubview(other)
        host.hostWindow.makeFirstResponder(other)
        host.presenting = nil
        page.didActivate()
        XCTAssertTrue(host.hostWindow.firstResponder === other)

        host.presenting = page
        host.canManageTabs = false
        page.didActivate()
        XCTAssertTrue(host.hostWindow.firstResponder === other)
    }

    func testNotesActivationDoesNotFocusADetachedEditor() async throws {
        let (page, host) = try await hostedNotesPage()
        let scroll = try XCTUnwrap(page.session.document.editorView)
        scroll.removeFromSuperview()
        host.hostWindow.makeFirstResponder(nil)
        let responder = host.hostWindow.firstResponder

        page.didActivate()

        XCTAssertTrue(host.hostWindow.firstResponder === responder)
    }

    func testDisposingAnUntouchedNotesPageDiscardsItsDraft() {
        let notes = workspace()
        let page = NotesPage(host: FakeHost(), workspace: notes)
        let draft = page.noteID
        page.dispose()
        XCTAssertNil(notes.documents[draft])
    }

    func testBrowserPageNavigatesWithinBeforeLeaving() {
        let host = FakeHost()
        let page = BrowserPage(host: host, frame: NSRect(x: 0, y: 0, width: 280, height: 300))
        XCTAssertEqual(page.kind, .browser)
        XCTAssertEqual(page.surface, .reading)
        XCTAssertFalse(page.canGoBackWithin, "With no history ⌘[ returns to the home page.")
        XCTAssertTrue(page.handlesForward)
        XCTAssertFalse(page.isFinished)
        XCTAssertFalse(page.title.isEmpty)
        page.dispose()
        XCTAssertNil(page.view.superview)
    }
}
