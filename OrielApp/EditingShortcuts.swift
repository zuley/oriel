import AppKit

/// Mini windows are non-activating panels: while another app is active, the Edit menu's
/// key equivalents never reach their text fields. The panel forwards these itself.
@MainActor
enum EditingShortcuts {
    static func action(for event: NSEvent, responder: NSResponder?) -> Selector? {
        // Only AppKit text editing (including SwiftUI and NSTextField field editors).
        // The notes editor handles these itself (plain-text paste, its own undo).
        guard let responder = responder as? NSText, !(responder is NotesTextView) else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "a"): return #selector(NSText.selectAll(_:))
        case (.command, "c"): return #selector(NSText.copy(_:))
        case (.command, "x"): return #selector(NSText.cut(_:))
        case (.command, "v"): return #selector(NSText.paste(_:))
        case (.command, "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }
}
