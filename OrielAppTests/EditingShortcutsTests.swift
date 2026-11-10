import AppKit
import XCTest

/// R05: mini windows are non-activating panels, so the app's Edit menu does not see
/// ⌘A/C/X/V/Z while another app is active. Text fields get them from the panel.
@MainActor
final class EditingShortcutsTests: XCTestCase {
    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    func testTextFieldEditorsReceiveStandardEditingActions() throws {
        let fieldEditor = NSTextView()
        XCTAssertEqual(EditingShortcuts.action(for: try key("a"), responder: fieldEditor), #selector(NSText.selectAll(_:)))
        XCTAssertEqual(EditingShortcuts.action(for: try key("c"), responder: fieldEditor), #selector(NSText.copy(_:)))
        XCTAssertEqual(EditingShortcuts.action(for: try key("x"), responder: fieldEditor), #selector(NSText.cut(_:)))
        XCTAssertEqual(EditingShortcuts.action(for: try key("v"), responder: fieldEditor), #selector(NSText.paste(_:)))
        XCTAssertEqual(EditingShortcuts.action(for: try key("z"), responder: fieldEditor), Selector(("undo:")))
        XCTAssertEqual(EditingShortcuts.action(for: try key("z", [.command, .shift]), responder: fieldEditor), Selector(("redo:")))
        XCTAssertEqual(EditingShortcuts.action(for: try key("Z", [.command, .shift]), responder: fieldEditor), Selector(("redo:")))
    }

    func testOtherKeysAndRespondersAreLeftAlone() throws {
        let fieldEditor = NSTextView()
        XCTAssertNil(EditingShortcuts.action(for: try key("t"), responder: fieldEditor))
        XCTAssertNil(EditingShortcuts.action(for: try key("v", [.command, .option]), responder: fieldEditor))
        XCTAssertNil(EditingShortcuts.action(for: try key("v"), responder: NSView()), "Terminals and web views handle their own keys.")
        XCTAssertNil(EditingShortcuts.action(for: try key("v"), responder: nil))
        // The notes editor pastes plain text and manages its own undo.
        XCTAssertNil(EditingShortcuts.action(for: try key("v"), responder: NotesTextView()))
    }
}
