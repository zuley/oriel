import AppKit

/// The one place that maps a page kind to its implementation.
@MainActor
struct PageFactory {
    let library: NovelLibrary
    let watchlist: StockWatchlist
    let notes: NotesWorkspace

    func make(_ kind: PageKind, host: PageHost, frame: NSRect) -> TabPage {
        switch kind {
        case .terminal: TerminalPage(host: host, frame: frame)
        case .novel: NovelPage(host: host, library: library)
        case .stocks: StocksPage(host: host, watchlist: watchlist)
        case .notes: NotesPage(host: host, workspace: notes)
        case .browser: BrowserPage(host: host, frame: frame)
        }
    }
}
