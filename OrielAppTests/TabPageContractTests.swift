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
