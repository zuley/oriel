import AppKit

/// A small browser. ⌘[ / ⌘] walk its history before leaving the page.
@MainActor
final class BrowserPage: TabPage {
    let kind = PageKind.browser
    let browser: BrowserView
    private weak var host: PageHost?
    var view: NSView { browser }
    var title: String { browser.pageTitle }

    init(host: PageHost, frame: NSRect) {
        self.host = host
        browser = BrowserView(frame: frame)
        browser.onTitleChange = { [weak self] in
            guard let self else { return }
            self.host?.pageTitleChanged(self)
        }
    }

    func didOpen() {
        browser.showStartPage()
        browser.focusAddress()
    }

    func didActivate() { browser.focusContent() }
    /// A page that is no longer on screen must not keep playing sound.
    func willDeactivate() { browser.pauseMedia() }
    func hasEditingFocus(_ responder: NSResponder) -> Bool { browser.hasEditingFocus }

    func handleKeyEquivalent(_ key: String?, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> Bool {
        if modifiers == [.command, .shift], key == "+" || key == "=" {
            browser.zoomIn()
            return true
        }
        guard modifiers == .command else { return false }
        switch key {
        // Web content is not AppKit text editing; send the standard actions down the chain.
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: host?.hostWindow)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: host?.hostWindow)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: host?.hostWindow)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: host?.hostWindow)
        case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: host?.hostWindow)
        case "l": browser.focusAddress(); return true
        case "r": browser.reload(); return true
        case "d": browser.toggleBookmark(); return true
        case "=": browser.zoomIn(); return true
        case "-": browser.zoomOut(); return true
        case "0": browser.resetZoom(); return true
        default: return false
        }
    }

    var canGoBackWithin: Bool { browser.canGoBack }
    func goBackWithin() { browser.goBack() }
    var handlesForward: Bool { true }
    func goForwardWithin() { browser.goForward() }

    func dispose() { browser.dispose() }
}
